#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

#ifndef STAYAWAKE_DEBUG_LOG
#define STAYAWAKE_DEBUG_LOG 1
#endif

#define STAYAWAKE_TARGET_BUNDLE_ID @"com.example.piliplus"
#define STAYAWAKE_TARGET_NAME @"piliplus"
#define STAYAWAKE_TARGET_ALIAS @"pili"

static const CGFloat MinimumWindowSide = 80;
static const NSTimeInterval WindowPollInterval = 1.5;

typedef NS_ENUM(NSUInteger, RuntimeMode) {
    RuntimeModeHost,
    RuntimeModeGuest,
    RuntimeModeExtension,
};

typedef void (*IdleTimerSetter)(UIApplication *, SEL, BOOL);
static IdleTimerSetter orig_setIdleTimerDisabled;
static atomic_bool gShouldKeepAwake;
static RuntimeMode runtimeMode;
static BOOL isPiliPlusGuest;
static Class decoratedWindowClass;
static Class appSceneClass;
static NSTimer *windowPollTimer;

#if STAYAWAKE_DEBUG_LOG
static const off_t LogSizeLimit = 200 * 1024;
static NSUInteger snapshotsThisForeground;
static NSTimeInterval lastSnapshotTime;

static BOOL AppendLog(NSString *directory, NSData *line) {
    NSString *path = [directory stringByAppendingPathComponent:@"StayAwake_debug.log"];
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        return NO;
    }

    struct stat info;
    BOOL success = flock(descriptor, LOCK_EX) == 0 && fstat(descriptor, &info) == 0;
    if (success && info.st_size + (off_t)line.length > LogSizeLimit) {
        success = ftruncate(descriptor, 0) == 0;
    }
    if (success) {
        success = write(descriptor, line.bytes, line.length) == (ssize_t)line.length;
    }
    close(descriptor);
    return success;
}

static void Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void Log(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSProcessInfo *process = NSProcessInfo.processInfo;
    NSString *entry = [NSString stringWithFormat:@"[StayAwake] %@ pid=%d %@",
                       NSDate.date, process.processIdentifier, message];
    NSLog(@"%@", entry);

    NSData *line = [[entry stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    // LiveContainer redirects Documents for guests. Prefer the host's Files-visible folder.
    const char *hostHome = getenv("LC_HOME_PATH");
    NSString *documents = hostHome ? [@(hostHome) stringByAppendingPathComponent:@"Documents"] : nil;
    BOOL written = documents && AppendLog(documents, line);
    if (!written) {
        documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                         inDomains:NSUserDomainMask].firstObject.path;
        written = documents && AppendLog(documents, line);
    }
    if (!written && !AppendLog(NSTemporaryDirectory(), line)) {
        NSLog(@"[StayAwake] Unable to write StayAwake_debug.log");
    }
}
#else
#define Log(...) ((void)0)
#endif

static BOOL GetterHasType(id receiver, SEL selector, char type) {
    Method method = class_getInstanceMethod(object_getClass(receiver), selector);
    if (!method || ![receiver respondsToSelector:selector]) {
        return NO;
    }
    char returnType[8];
    method_getReturnType(method, returnType, sizeof(returnType));
    return method_getNumberOfArguments(method) == 2 && returnType[0] == type;
}

static id ReadObject(id receiver, SEL selector) {
    @try {
        if (GetterHasType(receiver, selector, '@')) {
            return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    } @catch (NSException *exception) {
        Log(@"runtime getter %@ failed (%@)", NSStringFromSelector(selector), exception.name);
    }
    return nil;
}

static BOOL ReadBool(id receiver, SEL selector) {
    @try {
        if (GetterHasType(receiver, selector, 'B') || GetterHasType(receiver, selector, 'c')) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    } @catch (NSException *exception) {
        Log(@"runtime getter %@ failed (%@)", NSStringFromSelector(selector), exception.name);
    }
    return NO;
}

static BOOL MatchesPiliPlus(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return NO;
    }
    NSString *identifier = [value lowercaseString];
    if ([identifier isEqualToString:STAYAWAKE_TARGET_BUNDLE_ID] ||
        [identifier containsString:STAYAWAKE_TARGET_NAME]) {
        return YES;
    }
    // Treat the short alias as a complete token to avoid matching unrelated apps.
    NSArray *tokens = [identifier componentsSeparatedByCharactersInSet:
                       NSCharacterSet.alphanumericCharacterSet.invertedSet];
    return [tokens containsObject:STAYAWAKE_TARGET_ALIAS];
}

static RuntimeMode IdentifyRuntime(NSString *processName, NSBundle *bundle, NSString *guestIdentifier) {
    if ([processName rangeOfString:@"LiveProcess" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundle.bundlePath.pathExtension isEqualToString:@"appex"] ||
        ReadBool(NSUserDefaults.class, NSSelectorFromString(@"isLiveProcess"))) {
        return RuntimeModeExtension;
    }
    if (guestIdentifier.length ||
        ReadObject(NSUserDefaults.class, NSSelectorFromString(@"guestAppInfo"))) {
        return RuntimeModeGuest;
    }
    NSBundle *hostBundle = ReadObject(NSUserDefaults.class, NSSelectorFromString(@"lcMainBundle"));
    if ((hostBundle && [bundle.bundlePath isEqualToString:hostBundle.bundlePath]) ||
        [bundle.bundleIdentifier.lowercaseString hasPrefix:@"com.kdt.livecontainer"]) {
        return RuntimeModeHost;
    }
    return RuntimeModeGuest;
}

static BOOL IsViewVisible(UIView *view) {
    UIWindow *window = view.window;
    if (!window.windowScene || window.windowScene.activationState != UISceneActivationStateForegroundActive) {
        return NO;
    }
    CGRect visibleFrame = CGRectIntersection([view convertRect:view.bounds toView:window], window.bounds);
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) {
            return NO;
        }
        if (ancestor.clipsToBounds) {
            visibleFrame = CGRectIntersection(visibleFrame, [ancestor convertRect:ancestor.bounds toView:window]);
        }
    }
    return CGRectGetWidth(visibleFrame) >= MinimumWindowSide &&
           CGRectGetHeight(visibleFrame) >= MinimumWindowSide;
}

static NSString *SceneBundleID(UIViewController *controller) {
    id scene = ReadObject(controller, NSSelectorFromString(@"appSceneVC"));
    id identifier = ReadObject(scene ?: controller, NSSelectorFromString(@"bundleId"));
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

// Via the documented UIViewController containment API. LiveContainer adds each
// decorated virtual window directly as a child of the host root controller.
static BOOL FindVisiblePiliPlus(UIViewController *controller, BOOL *sawFloatingWindow) {
    if ([controller isKindOfClass:decoratedWindowClass]) {
        *sawFloatingWindow = YES;
        id scene = ReadObject(controller, NSSelectorFromString(@"appSceneVC"));
        return (MatchesPiliPlus(SceneBundleID(controller)) || MatchesPiliPlus(controller.title)) &&
               IsViewVisible(controller.viewIfLoaded) &&
               ReadBool(scene, NSSelectorFromString(@"isAppRunning"));
    }
    if ([controller isKindOfClass:appSceneClass]) {
        *sawFloatingWindow = YES;
    }
    for (UIViewController *child in controller.childViewControllers) {
        if (FindVisiblePiliPlus(child, sawFloatingWindow)) {
            return YES;
        }
    }
    return controller.presentedViewController &&
           FindVisiblePiliPlus(controller.presentedViewController, sawFloatingWindow);
}

#if STAYAWAKE_DEBUG_LOG
static void AppendControllerSnapshot(NSMutableString *snapshot, UIViewController *controller,
                                     NSUInteger depth, NSUInteger *remaining) {
    if (!controller || !*remaining || depth > 5) {
        return;
    }
    --*remaining;
    UIView *view = controller.viewIfLoaded;
    NSString *identifier = SceneBundleID(controller);
    id appScene = ReadObject(controller, NSSelectorFromString(@"appSceneVC")) ?: controller;
    [snapshot appendFormat:@"\n  VC depth=%lu %@ mounted=%d hidden=%d alpha=%.2f visible=%d frame=%@ id=%@ targetTitle=%d running=%d",
     (unsigned long)depth, NSStringFromClass(controller.class), view.window != nil,
     view.hidden, view.alpha, IsViewVisible(view), NSStringFromCGRect(view ? view.frame : CGRectZero),
     identifier ?: @"-", [controller isKindOfClass:decoratedWindowClass] && MatchesPiliPlus(controller.title),
     [appScene isKindOfClass:appSceneClass] && ReadBool(appScene, NSSelectorFromString(@"isAppRunning"))];
    for (UIViewController *child in controller.childViewControllers) {
        AppendControllerSnapshot(snapshot, child, depth + 1, remaining);
    }
    AppendControllerSnapshot(snapshot, controller.presentedViewController, depth + 1, remaining);
}

static void Snapshot(UIApplication *application, NSString *reason) {
    snapshotsThisForeground++;
    lastSnapshotTime = NSProcessInfo.processInfo.systemUptime;
    NSMutableString *snapshot = [NSMutableString stringWithFormat:@"snapshot %@ decoratedClass=%@ sceneClass=%@",
                                 reason, decoratedWindowClass ? NSStringFromClass(decoratedWindowClass) : @"missing",
                                 appSceneClass ? NSStringFromClass(appSceneClass) : @"missing"];
    NSUInteger remaining = 22;
    NSUInteger windowCount = 0;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (windowCount++ == 5) {
                Log(@"%@", snapshot);
                return;
            }
            [snapshot appendFormat:@"\n window %@ scene=%@ state=%ld hidden=%d alpha=%.2f frame=%@",
             NSStringFromClass(window.class), NSStringFromClass(scene.class), (long)scene.activationState,
             window.hidden, window.alpha, NSStringFromCGRect(window.frame)];
            AppendControllerSnapshot(snapshot, window.rootViewController, 0, &remaining);
        }
    }
    Log(@"%@", snapshot);
}
#endif

static void SetOriginalIdleTimer(UIApplication *application, BOOL disabled, NSString *reason) {
    orig_setIdleTimerDisabled(application, @selector(setIdleTimerDisabled:), disabled);
    Log(@"orig idleTimerDisabled=%@ reason=%@", disabled ? @"YES" : @"NO", reason);
}

static void UpdateKeepAwake(UIApplication *application, BOOL desired, BOOL refresh, NSString *reason) {
    BOOL previous = atomic_exchange(&gShouldKeepAwake, desired);
    if (previous != desired) {
        Log(@"gShouldKeepAwake %@ -> %@ reason=%@", previous ? @"YES" : @"NO", desired ? @"YES" : @"NO", reason);
    }
    if (desired && (!previous || refresh)) {
        // UIKit can suppress writes of a value it already holds. Force a fresh transition.
        SetOriginalIdleTimer(application, NO, reason);
        SetOriginalIdleTimer(application, YES, reason);
    } else if (previous && !desired) {
        SetOriginalIdleTimer(application, NO, reason);
    }
}

static void RefreshHostWindows(UIApplication *application, BOOL refresh, NSString *reason) {
    BOOL visible = NO;
    BOOL sawFloatingWindow = NO;
    if (application.applicationState == UIApplicationStateActive) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (FindVisiblePiliPlus(window.rootViewController, &sawFloatingWindow)) {
                    visible = YES;
                    break;
                }
            }
            if (visible) {
                break;
            }
        }
    }
    UpdateKeepAwake(application, visible, refresh, reason);
#if STAYAWAKE_DEBUG_LOG
    if (application.applicationState == UIApplicationStateActive &&
        (snapshotsThisForeground == 0 ||
         (sawFloatingWindow && !visible && snapshotsThisForeground < 2 &&
          NSProcessInfo.processInfo.systemUptime - lastSnapshotTime >= 8))) {
        Snapshot(application, snapshotsThisForeground == 0 ? @"foreground" : @"no-visible-match");
    }
#endif
}

static void ScheduleWindowRefresh(SEL event) {
    dispatch_async(dispatch_get_main_queue(), ^{
        RefreshHostWindows(UIApplication.sharedApplication, NO, NSStringFromSelector(event));
    });
}

static void HookWindowEvents(void) {
    @try {
        for (NSString *name in @[@"closeWindow", @"minimizeWindow", @"minimizeWindowPiP", @"unminimizeWindowPiP",
                                 @"appSceneVCAppDidExit:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(decoratedWindowClass, selector);
            if (!method || ![decoratedWindowClass instancesRespondToSelector:selector]) {
                continue;
            }
            char type[8];
            method_getReturnType(method, type, sizeof(type));
            if (type[0] != 'v') {
                continue;
            }
            IMP original = method_getImplementation(method);
            IMP replacement;
            if (method_getNumberOfArguments(method) == 2) {
                replacement = imp_implementationWithBlock(^(id controller) {
                    ((void (*)(id, SEL))original)(controller, selector);
                    ScheduleWindowRefresh(selector);
                });
            } else if (method_getNumberOfArguments(method) == 3) {
                method_getArgumentType(method, 2, type, sizeof(type));
                if (type[0] != '@') {
                    continue;
                }
                replacement = imp_implementationWithBlock(^(id controller, id scene) {
                    ((void (*)(id, SEL, id))original)(controller, selector, scene);
                    ScheduleWindowRefresh(selector);
                });
            } else {
                continue;
            }
            if (!class_addMethod(decoratedWindowClass, selector, replacement, method_getTypeEncoding(method))) {
                method_setImplementation(method, replacement);
            }
            Log(@"hook %@", name);
        }
    } @catch (NSException *exception) {
        Log(@"window hook failed (%@)", exception.name);
    }
}

static void Refresh(NSString *reason, BOOL forceRefresh) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!application) {
        return;
    }
    if (!orig_setIdleTimerDisabled) {
        SEL selector = @selector(setIdleTimerDisabled:);
        Method method = class_getInstanceMethod(UIApplication.class, selector);
        orig_setIdleTimerDisabled = (IdleTimerSetter)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(UIApplication *receiver, BOOL disabled) {
            BOOL requested = disabled || atomic_load(&gShouldKeepAwake);
            SetOriginalIdleTimer(receiver, requested, disabled != requested ? @"external NO held" : @"external");
        }));
        Log(@"idle timer hook installed");
        if (runtimeMode == RuntimeModeHost && decoratedWindowClass) {
            HookWindowEvents();
        }
    }
    if (runtimeMode == RuntimeModeHost) {
        if (application.applicationState != UIApplicationStateActive) {
            return;
        }
        RefreshHostWindows(application, forceRefresh, reason);
        if (!windowPollTimer) {
            windowPollTimer = [NSTimer timerWithTimeInterval:WindowPollInterval repeats:YES block:^(NSTimer *timer) {
                RefreshHostWindows(UIApplication.sharedApplication, NO, @"window poll");
            }];
            windowPollTimer.tolerance = 0.2;
            [[NSRunLoop mainRunLoop] addTimer:windowPollTimer forMode:NSRunLoopCommonModes];
        }
    } else if (isPiliPlusGuest && application.applicationState == UIApplicationStateActive) {
        UpdateKeepAwake(application, YES, forceRefresh, reason);
    }
}

__attribute__((constructor))
static void initStayAwake(void) {
    @autoreleasepool {
#if STAYAWAKE_DEBUG_LOG
        NSDate *loadedAt = NSDate.date;
#endif
        dispatch_async(dispatch_get_main_queue(), ^{
            NSBundle *bundle = NSBundle.mainBundle;
            NSString *processName = NSProcessInfo.processInfo.processName;
            NSString *guestIdentifier = ReadObject(NSUserDefaults.class, NSSelectorFromString(@"lcGuestAppId"));
            runtimeMode = IdentifyRuntime(processName, bundle, guestIdentifier);
            isPiliPlusGuest = MatchesPiliPlus(guestIdentifier) || MatchesPiliPlus(bundle.bundleIdentifier) ||
                             MatchesPiliPlus([bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]) ||
                             MatchesPiliPlus([bundle objectForInfoDictionaryKey:@"CFBundleName"]);
            Log(@"constructor=%@ process=%@ bundle=%@ guest=%@ UIApplication(main)=%@ mode=%@",
                loadedAt, processName, bundle.bundleIdentifier ?: @"-", guestIdentifier ?: @"-",
                UIApplication.sharedApplication ? @"ready" : @"nil",
                @[@"A/host", @"B/ordinary", @"C/LiveProcess"][runtimeMode]);
            if (runtimeMode == RuntimeModeExtension || (runtimeMode == RuntimeModeGuest && !isPiliPlusGuest)) {
                return;
            }

            if (runtimeMode == RuntimeModeHost) {
                decoratedWindowClass = NSClassFromString(@"DecoratedAppSceneViewController");
                appSceneClass = NSClassFromString(@"AppSceneViewController");
            }

            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            NSArray<NSString *> *events = @[UIApplicationDidFinishLaunchingNotification,
                                            UIApplicationDidBecomeActiveNotification,
                                            UISceneDidActivateNotification, UISceneWillDeactivateNotification];
            for (NSString *event in events) {
                [center addObserverForName:event object:nil queue:NSOperationQueue.mainQueue
                                usingBlock:^(NSNotification *note) {
                    BOOL becameActive = [note.name isEqualToString:UIApplicationDidBecomeActiveNotification] ||
                                        [note.name isEqualToString:UISceneDidActivateNotification];
                    Log(@"event %@", note.name);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        Refresh(note.name, becameActive);
                    });
                }];
            }

            [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
                Log(@"event %@", note.name);
                [windowPollTimer invalidate];
                windowPollTimer = nil;
#if STAYAWAKE_DEBUG_LOG
                snapshotsThisForeground = 0;
#endif
                if (orig_setIdleTimerDisabled) {
                    UpdateKeepAwake(UIApplication.sharedApplication, NO, NO, note.name);
                }
            }];

            Refresh(@"initial main queue", YES);
            if (!UIApplication.sharedApplication) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    Refresh(@"UIKit startup retry", YES);
                });
            }
        });
    }
}
