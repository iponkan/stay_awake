# StayAwake

适用于 LiveContainer 的防自动锁屏模块，支持 **PiliPlus、Infuse、YouTube 和 Aloha Browser**。构建目标为 iOS 15+ 真机 arm64。

普通启动时，受支持的 App 在前台保持常亮。使用 LiveContainer 多任务浮窗时，只要有一个受支持的浮窗可见且未最小化，就会保持常亮。最后一个目标浮窗关闭或最小化后恢复正常自动锁定。模块依据窗口是否可见判断，暂停播放或浏览页面时同样有效。

## 安装与更新

1. 从 [GitHub Releases](https://github.com/iponkan/stay_awake/releases/latest) 下载 `StayAwake.dylib`。
2. 在 LiveContainer 的「模块」页移除旧版 StayAwake，再把新版导入**全局模块根目录**并启用。
3. 点「模块」页右上角 **「＋」左边的手写签名图标**，让 LiveContainer 用设备上的侧载证书给模块重签。
4. 如果使用多任务浮窗，在 LiveContainer「设置」滑到底部，连续点版本号五次，在开发者设置里开启 **「向 LiveContainer 加载模块」**。
5. **从 iPhone 的 App 切换器划掉 LiveContainer 本身，再重新打开。** 每次替换 dylib 都需要重签并重启宿主。只关浮窗会继续使用宿主已加载的旧版本。

## 验证与排查

- 把 iPhone 的自动锁定设为有限时长，打开一个受支持的 App 并等待超过该时长。多任务模式下，再最小化最后一个目标浮窗，确认自动锁定恢复。亮度变暗时可以观察是否真的进入锁屏。
- 如果出现 `Failed to load tweaks`，回到「模块」页给插件重签。签名按钮不可用或重签报错时，在 LiveContainer 的「JIT-Less 模式诊断」检查证书。 [LiveContainer 模块指南](https://livecontainer.github.io/zh-CN/docs/guides/tweaks)
- 在 iPhone「文件」→「我的 iPhone」→「LiveContainer」查看 `StayAwake_debug.log`。排查时提供这次重开后新出现的 `constructor=`、`snapshot`、`gShouldKeepAwake` 和 `orig idleTimerDisabled` 几行。多任务模式下应能看到宿主的 `mode=A/host`。

## 构建

GitHub Actions 使用 iPhoneOS SDK 构建并验证 ad-hoc 签名，每次推送会上传 Actions 产物。推送以 `v` 开头的版本标签时，工作流会将 `StayAwake.dylib` 上传到对应的 GitHub Release。
