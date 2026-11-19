#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void initStayAwake(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL setter = @selector(setIdleTimerDisabled:);
        Method method = class_getInstanceMethod(UIApplication.class, setter);
        void (*originalSetter)(UIApplication *, SEL, BOOL) =
            (void (*)(UIApplication *, SEL, BOOL))method_getImplementation(method);

        // Keep the idle timer disabled when the app or its player asks to enable it.
        method_setImplementation(method, imp_implementationWithBlock(
            ^(UIApplication *application, BOOL disabled) {
                originalSetter(application, setter, YES);
            }));

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *notification) {
                UIApplication.sharedApplication.idleTimerDisabled = YES;
            }];

        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            UIApplication.sharedApplication.idleTimerDisabled = YES;
        }
    });
}
