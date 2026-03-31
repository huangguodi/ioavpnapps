# 项目记忆

## iOS 签名

- Bundle ID: `com.xiangyu.clash`；扩展 `com.xiangyu.clash.packettunnel`；App Group: `group.com.xiangyu.clash`
- 证书: `ios_cert/dev.p12`、`ios_cert/Clash_Main_Profile.mobileprovision`、`ios_cert/Clash_Extension_Profile.mobileprovision`；p12 密码: `112233`
- CI: `.github/workflows/ios-ipa.yml`
- 当前证书 / 描述文件是开发签名，绑定单设备；Team ID `2CS2A54XG8`
- `ios/Runner.xcodeproj/project.pbxproj` 已改为手动签名：`Runner -> Clash_Main_Profile`，`PacketTunnel -> Clash_Extension_Profile`
- `ios/Podfile` 已补齐；iOS 最低版本 `15.0`；`permission_handler` 仅开启 `CAMERA`、`NOTIFICATIONS`，其余权限宏默认关闭
- `ios/PacketTunnel/PacketTunnelProvider.swift` 已修 `NSString -> String -> Data` 编译问题；`ios/Runner/AppDelegate.swift` 已修 2 处尾逗号 Swift 语法错误
- IPA 上传不再使用 GitHub artifact；当前 CI 改为上传到 `tmpfiles.org`，链接直接输出在 Actions 日志和 Step Summary
- 若 GitHub Actions 再报免费存储额度满，先检查账号下其他仓库工件；本次已清空 `huangguodi/testios` 的 18 个旧 `ios-ipa` 工件，约释放 603 MB
- 本轮 iOS 启动修复:
  - `ios/Runner/Info.plist` 已移除 `UISceneStoryboardFile`、`UIMainStoryboardFile`，避免和自定义 `SceneDelegate` 重复接管启动
  - `ios/Runner/SceneDelegate.swift` 已改为继承 `FlutterSceneDelegate`；`scene(...)` 必须带 `override`
  - `ios/Runner/AppDelegate.swift` 不再在 `didFinishLaunchingWithOptions` 里抢先解析 `FlutterViewController`；MethodChannel 改为在 `SceneDelegate` 创建 controller 后绑定
  - 之前 CI 报错 `overriding declaration requires an 'override' keyword`，已修；当前触发构建的最新提交 `f65b981`
- 本轮 iOS 稳定性补强:
  - `ios/Runner/AppDelegate.swift` 的 `NETunnelProviderProtocol` 已设置 `disconnectOnSleep = false`
  - `lib/services/mihomo_service.dart` 在 iOS `start()` 前会先显式 `requestVpnPermission()`
  - `ios/PacketTunnel/PacketTunnelProvider.swift` 已补 IPv6 地址 / 默认路由 / IPv6 DNS
  - `ios/PacketTunnel/PacketTunnelProvider.swift` 的 `wake()` 在 `MobileWake()` 失败时会触发一次 `MobileRestartTunnelForNetworkChange()`
  - `ios/PacketTunnel/PacketTunnelProvider.swift` 的 `NWPathMonitor` 已增加首次回调忽略与重启节流，降低网络切换抖动

## 热更新

- 启动页: `lib/views/splash_page.dart`，单一 4 步进度区；成功后提示关闭 App，不自动重启；失败可重试
- 版本键: `hot_update_applied_version`
- 更新接口: `/app/v2/update/check`；同版本返回加密 JSON，不同版本直接返回 ZIP
- `lib/services/api_service.dart` 已兼容加密 JSON / 明文 JSON / ZIP，并用响应头或文件头 `PK` 判断 ZIP
- 包结构: Android `libapp.so + flutter_assets/`；Windows `app.so + flutter_assets/`；iOS `App + flutter_assets/`
- 打包脚本: `build_hot_update_release.ps1`
- 写入策略:
  - Android: 先导出内置 `flutter_assets` 到可写目录，再覆盖更新包
  - iOS / Windows: 基于 `current` 增量覆盖
- 完整性校验: 三端都要求二进制存在，且 `flutter_assets` 至少含资源清单 marker 和 1 个非 marker 资源文件
- Android:
  - Debug 不接管热更新 AOT，`flutter run` 不加载 `hot_update/current`
  - Release 仅通过 `--aot-shared-library-name` 接管 `libapp.so`
  - 资源读取走“APK 内置资源 + 可写目录覆盖”；`main.dart` 使用 `HotUpdateService.resolveRuntimeAssetBundle()`
- 直接 `rootBundle.load(...)` 的场景要改走 `HotUpdateService().loadRuntimeAsset(...)`；已处理 `lib/services/mihomo_service.dart` 的 `assets/Country.mmdb`

## 平台差异

- Android: `filesDir/hot_update/runtime_bundle/current`
- iOS: `App.framework/App + flutter_assets` 组成 pending/current，重启生效
- Windows: 热更新目录为可执行文件同级 `hot_update/current`；Debug 强制走内置 `data`

## 校验

- `flutter test` 通过
- `flutter analyze` 仍有仓库既有 warning / info
- Windows 调试若偶发 `INSTALL.vcxproj` 失败，先结束残留 `app.exe`

## 首页与扫码

- 首页右上角入口: 客服、Logo、扫码绑定 `qrcode.svg`、邀请 `yaoqing.svg`
- 邀请弹窗在 `lib/views/home_page.dart`；接口 `/app/v2/user/invite/info`；仅展示邀请人数、奖励流量、礼品码/下载地址/推广文案复制按钮
- 邀请复制按钮显示“已复制”2 秒；奖励固定 1 人 = 10GB
- 邀请弹窗改为可滚动，隐藏纵向滚动条；每次打开弹窗都会重新拉取一次邀请数据
- 邀请接口下载地址优先取 `android_download_url / ios_download_url / windows_download_url`；若为空则隐藏对应整张卡片
- 扫码绑定接口: `/app/v2/user/device-bind/apply`、`/app/v2/user/device-bind/scan`
- 首页弹窗含“出示二维码”和“扫一扫”；出示二维码用 `bind_url`；扫一扫用 `mobile_scanner`
- 权限: Android 已加 `CAMERA`；iOS 已加 `NSCameraUsageDescription`
- 成功后提示“绑定成功，请重新打开APP生效”，确认后退出 App
- Windows 仅显示入口；扫一扫提示当前平台不支持
- 小窗口适配已做紧凑化与滚动；出示二维码页顶部为左关闭、中 Logo、右占位
- 登录 / 用户信息新增 `is_device_bound`；为 `true` 时隐藏首页右上角绑定二维码图标，为 `false` 时显示

## 安全

- 已移除全局禁止截图逻辑；`lib/main.dart` 不再调用 `enableSecureMode`
- Android 原生已删除 `FLAG_SECURE`；项目当前全局允许截图

## 登录态失效

- `/app/v2/user/info` 返回 `code != 200` 时清理 `auth_token`、`user_info`
- 随后弹不可取消提示“登录环境发生变化，请退出APP后重新打开”，确认后退出
- 全局导航 key: `lib/core/constants.dart` 中的 `appNavigatorKey`

## 性能优化进度

- 优化清单文件: `优化清单.md`
- 已完成:
  - 用户信息缓存按变化写盘；Windows 轮询路径延迟批量落盘，并在切后台、窗口隐藏前、显式退出前补刷
  - Android 高频 native log 收敛；流量采样迁移到后台 `HandlerThread`
  - Splash 启动拆为“首屏必需 + 后台补充”；Android 权限申请改为首页后后台触发；登录重试改为有限次数短延迟
  - 用户信息轮询、安全检查、Mihomo 守护检查改为单次调度续期并错峰
  - 工单弹窗轮询在应用不可见时暂停；扫码弹窗切后台停相机；广告轮播支持交互冷却、悬停暂停、应用非活跃暂停
  - 节点面板优先使用缓存秒开；节点测速改为小批量并发分批回填；节点切换后优先用已知节点信息更新 UI
  - iOS `PacketTunnelProvider.swift` / `AppDelegate.swift` 新增轻量字符串消息链路；`mihomo_service.dart` 为 `isRunning`、`mode`、`selectedProxy` 增加 2 秒 TTL 轻量缓存；`proxies` 缓存 TTL 为 12 秒并在关键动作后失效
  - 首页初始化优先拿基础状态，当前节点详情延后补充
  - Windows 新增 `getSelectedProxyInfoSync` 轻量当前节点详情，流量事件仅在数值变化时回传
  - iOS Tunnel 启动后状态查询节流；iOS 流量动态频率；Windows 守护检查与状态查询错峰；Android 当前节点详情轻量接口 `getSelectedProxyInfo`
  - 轮询任务统一登记；用户信息缓存分级；`config.yaml` 仅在内容变化时写盘
  - `优化清单.md` 已补“本轮验证记录”和人工 / 真机验证检查表
- 当前校验结论: `flutter test` 持续通过；`flutter analyze` 仍有仓库既有 15 条 warning / info，无本轮新增错误
- 当前阶段结论: 低风险性能优化项已基本落地；后续优先补人工 / 真机验收记录或清理历史 analyze warning
