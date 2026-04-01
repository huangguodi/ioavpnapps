# 项目记忆

## iOS 关键信息

- Bundle ID: `com.xiangyu.clash`；扩展: `com.xiangyu.clash.packettunnel`；App Group: `group.com.xiangyu.clash`
- 证书: `ios_cert/dev.p12`、`ios_cert/Clash_Main_Profile.mobileprovision`、`ios_cert/Clash_Extension_Profile.mobileprovision`；p12 密码: `112233`
- Team ID: `2CS2A54XG8`
- 手动签名已配置：`Runner -> Clash_Main_Profile`，`PacketTunnel -> Clash_Extension_Profile`
- iOS 最低版本 `15.0`
- CI: `.github/workflows/ios-ipa.yml`
- IPA 通过 CI 上传到 `tmpfiles.org`

## iOS FD 重构与避坑指南 (已完成)
- **FD 获取方案**：必须使用 WireGuard 标准的 `getsockopt` 遍历法 (0~1024 描述符，匹配 `utun`) 获取真实 TUN fd，绝对禁止使用 KVC `socket.fileDescriptor`。
- **配置注入对齐 Android**：
  在 `config.yaml` 注入 `tun` 块，必须包含：
  ```yaml
  tun:
    enable: true
    stack: gvisor
    file-descriptor: <fd>
    auto-route: false
    auto-detect-interface: false
    auto-redirect: false
    mtu: 1500
    dns-hijack:
      - 0.0.0.0:53
      - "[::]:53"
  ```
- **内存防杀与性能**：绝对禁止在扩展进程中调用原生的 `packetFlow.readPackets` 和 `writePackets`，一切读写交由 `gvisor` 内核直连，避免 CPU 飙升与超过 20MB 内存限制被系统强杀。
- **网络切换与防断流**：当 `NWPathMonitor` 监听到网络变化（如 Wi-Fi/蜂窝切换）时，调用新版 API `MobileForceUpdateConfig("config.yaml")` 重载配置并刷新网络套接字，防止 VPN 彻底断开。
- **内核库路径**：静态库和头文件已更新至 `Runner/ThirdParty/libmihomo.a` 和 `Runner/ThirdParty/include/Mihomo.h`。

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
