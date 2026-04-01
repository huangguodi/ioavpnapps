# 项目记忆

## iOS 关键信息

- Bundle ID: `com.xiangyu.clash`；扩展: `com.xiangyu.clash.packettunnel`；App Group: `group.com.xiangyu.clash`
- 证书: `ios_cert/dev.p12`、`ios_cert/Clash_Main_Profile.mobileprovision`、`ios_cert/Clash_Extension_Profile.mobileprovision`；p12 密码: `112233`
- Team ID: `2CS2A54XG8`
- 手动签名已配置：`Runner -> Clash_Main_Profile`，`PacketTunnel -> Clash_Extension_Profile`
- iOS 最低版本 `15.0`
- CI: `.github/workflows/ios-ipa.yml`
- IPA 通过 CI 上传到 `tmpfiles.org`

## iOS 当前排查结论

- `ios/PacketTunnel/PacketTunnel-Bridging-Header.h` 与 `ios/Runner/Runner-Bridging-Header.h` 已直接引入 `ios/Runner/ThirdParty/mihomo/libmihomo.h`
- `PacketTunnelProvider.swift` 已使用强类型 `Mobile*` 接口，`writePacket` 不再走 `perform(...).takeUnretainedValue()`
- 当前 iOS 正确链路是：
  - `PacketFlowBridge + packetFlow.readPackets/writePackets + MobileFeedPacketBytes + MobileMobileStartWithMemory(...)`
- `mihomo-clash/ios/mihomo/listener/sing_tun/server_ios.go` 已确认 **不支持** `tun.file-descriptor`
- 当前排查原则：**不要再回到 fd 路线**
- 网络切换时，`sleep()` / `wake()` / `NWPathMonitor` 当前优先走 `MobileResetNetwork()`
- `PacketTunnel.entitlements` 已补 `com.apple.security.network.client` 与 `com.apple.security.network.server`

## iOS 已做修复

- 启动接管修复：
  - `Info.plist` 已移除 `UISceneStoryboardFile`、`UIMainStoryboardFile`
  - `SceneDelegate.swift` 已继承 `FlutterSceneDelegate`
  - `AppDelegate.swift` 改为在 `SceneDelegate` 创建 controller 后绑定 MethodChannel
- 稳定性修复：
  - `NETunnelProviderProtocol.disconnectOnSleep = false`
  - iOS `start()` 前会显式 `requestVpnPermission()`
  - `wake()` 在 `MobileWake()` 失败时会触发一次 `MobileRestartTunnelForNetworkChange()`
  - `NWPathMonitor` 已增加首次回调忽略与重启节流
- 参数收敛：
  - TUN IPv4: `172.19.0.1/30`
  - TUN IPv6: `fdfe:dcba:9876::1`
  - MTU: `1400`
  - 禁用 IPv6 默认路由
  - iOS 系统 DNS 改到 TUN 内部地址 `172.19.0.2`
  - 注入 `inet4-address: 172.19.0.1/30`
- 运行时定位：
  - `PacketTunnelProvider.swift` 已记录 `start / read / feed / write / path reset` 到 App Group 下 `packet_tunnel_debug.log`
  - App 内已新增日志入口：右下角 debug overlay -> `Tunnel`
  - Flutter 页面：`lib/views/ios_tunnel_debug_page.dart`
- 当前真机结论：iOS 仍有“VPN 已连接但整机无网”；重点改为基于 Tunnel 日志判断卡在 `readPackets`、`MobileFeedPacketBytes` 还是 `writePackets`
- 详细长记录见根目录 `修复进度记录.md`

## iOS / mihomo 源码

- 内核源码目录：`mihomo-clash/ios/mihomo`
- iOS 静态库构建脚本：`mihomo-clash/ios/mihomo/.github/scripts/build-ios-static.sh`
- `mobile.go` / `mobile_c_api.go` 已补 iOS 内存启动状态保持：`lastConfigBytes`
- `applyIOSActiveConfig()` / `loadIOSConfigLocked()` 已抽出，复用 iOS 稳定化逻辑
- Windows 环境已完成源码级修复与 `go test ./mobile`，但 **尚未** 真正重编新的 `libmihomo.a`
- 若要替换静态库，需要在 macOS 执行构建脚本后覆盖到 `ios/Runner/ThirdParty/mihomo/`

## 热更新

- 启动页：`lib/views/splash_page.dart`，单一 4 步进度区；成功后提示关闭 App，不自动重启
- 版本键：`hot_update_applied_version`
- 更新接口：`/app/v2/update/check`
- 返回兼容：加密 JSON / 明文 JSON / ZIP
- 打包脚本：`build_hot_update_release.ps1`
- 平台路径：
  - Android: `filesDir/hot_update/runtime_bundle/current`
  - iOS: `App.framework/App + flutter_assets`
  - Windows: 可执行文件同级 `hot_update/current`
- `rootBundle.load(...)` 场景需改走 `HotUpdateService().loadRuntimeAsset(...)`

## 首页 / 扫码 / 邀请

- 首页右上角入口：客服、Logo、扫码绑定、邀请
- 邀请弹窗：`lib/views/home_page.dart`
- 邀请接口：`/app/v2/user/invite/info`
- 扫码绑定接口：`/app/v2/user/device-bind/apply`、`/app/v2/user/device-bind/scan`
- 扫一扫使用 `mobile_scanner`
- iOS 已加 `NSCameraUsageDescription`
- `is_device_bound = true` 时隐藏首页右上角绑定二维码图标

## 安全 / 登录态

- 已移除全局禁止截图；当前允许截图
- `/app/v2/user/info` 返回 `code != 200` 时清理 `auth_token`、`user_info`
- 随后弹不可取消提示并退出 App
- 全局导航 key：`lib/core/constants.dart` 中的 `appNavigatorKey`

## 校验与已知情况

- `flutter test` 通过
- `flutter analyze` 仍会被仓库内 `clashmi-main` 子目录历史错误拖红
- Windows 若偶发 `INSTALL.vcxproj` 失败，先结束残留 `app.exe`
- 若 GitHub Actions 报免费存储额度满，先清理账号下旧 artifacts

## 其他

- 性能优化总记录在 `优化清单.md`
