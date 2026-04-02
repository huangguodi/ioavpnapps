import Foundation
import NetworkExtension
import Network
import Darwin

final class SocketProtectorAdapter: NSObject, MobileSocketProtectorProtocol {
  private weak var provider: NEPacketTunnelProvider?

  init(provider: NEPacketTunnelProvider) {
    self.provider = provider
    super.init()
  }

  @objc(markSocket:network:address:)
  func markSocket(_ fd: Int64, network: String?, address: String?) -> Bool {
    guard let packetTunnelProvider = provider as? PacketTunnelProvider else { return true }
    return packetTunnelProvider.protectSocket(fd: Int32(fd), network: network, address: address)
  }

  @objc(protectSocket:network:address:)
  func protectSocket(_ fd: Int64, network: String?, address: String?) -> Bool {
    guard let packetTunnelProvider = provider as? PacketTunnelProvider else { return true }
    return packetTunnelProvider.protectSocket(fd: Int32(fd), network: network, address: address)
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let defaultAppGroup = "group.com.xiangyu.clash"
  private let tunnelRemoteAddress = "127.0.0.1"
  private let ipv4Address = "198.18.0.1"
  private let ipv4PrefixLength = 16
  private let ipv4SubnetMask = "255.255.0.0"
  private let tunnelDNSServers = ["223.5.5.5", "119.29.29.29"]
  private let enableIPv6Route = false
  private let ipv6Address = "fdfe:dcba:9876::1"
  private let ipv6PrefixLength = 126
  private let tunnelMTU = 1500
  private let pathRestartThrottle: TimeInterval = 2.0
  private let minCoreUptimeBeforePathRefresh: TimeInterval = 2.0
  private var socketProtector: SocketProtectorAdapter?
  private var pathMonitor: NWPathMonitor?
  private var hasObservedInitialPathUpdate = false
  private var lastPathFingerprint: String?
  private var lastPathRestartAt = Date.distantPast
  private var lastObservedInterfaceName: String?
  private let mihomoQueue = DispatchQueue(label: "com.accelerator.tg.mihomo.core", qos: .userInitiated)
  private let stateQueue = DispatchQueue(label: "com.accelerator.tg.packettunnel.state")
  private let stateQueueKey = DispatchSpecificKey<Void>()
  private let debugLogQueue = DispatchQueue(label: "com.accelerator.tg.packettunnel.debug")
  private let debugLogQueueKey = DispatchSpecificKey<Void>()
  private var diagnosticsTimer: DispatchSourceTimer?
  private var lifecycleID: UInt64 = 0
  private var tunnelActive = false
  private var coreRunning = false
  private var coreStartedAt = Date.distantPast
  private var coreRecoveryAttempted = false
  private var debugLogURL: URL?
  private var currentAppGroup: String
  private let lastContextKey = "packet_tunnel_last_context"
  private let lastContextTimeKey = "packet_tunnel_last_context_time"

  override init() {
    currentAppGroup = defaultAppGroup
    super.init()
    stateQueue.setSpecific(key: stateQueueKey, value: ())
    debugLogQueue.setSpecific(key: debugLogQueueKey, value: ())
    let _ = NWPathMonitor()
  }

  func getTunnelFd() -> Int32? {
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    for fd: Int32 in 0 ... 1024 {
      var len = socklen_t(buf.count)
      if getsockopt(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, &buf, &len) == 0 && String(cString: buf).hasPrefix("utun") {
        return fd
      }
    }
    return nil
  }

  override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    mihomoQueue.async { [weak self] in
      guard let self = self else { return }
      self.runWithMihomoAutoreleasePool {
        self.performStartTunnel(completionHandler: completionHandler)
      }
    }
  }

  private func performStartTunnel(completionHandler: @escaping (Error?) -> Void) {
    let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    let appGroup = providerConfig["appGroup"] as? String ?? defaultAppGroup
    setCurrentAppGroup(appGroup)
    
    let configContent: String
    if let directConfig = providerConfig["vpn_config_content"] as? String, !directConfig.isEmpty {
      configContent = directConfig
    } else {
      let fileURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("vpn_config_content.txt")
      if let url = fileURL, let savedConfig = try? String(contentsOf: url, encoding: .utf8) {
        configContent = savedConfig
        try? FileManager.default.removeItem(at: url)
      } else if let userDefaults = UserDefaults(suiteName: appGroup),
         let savedConfig = userDefaults.string(forKey: "vpn_config_content") {
        configContent = savedConfig
        userDefaults.removeObject(forKey: "vpn_config_content")
        userDefaults.synchronize()
      } else {
        configContent = ""
      }
    }

    if configContent.isEmpty {
      finishStart(
        completionHandler,
        error: NSError(
          domain: "Tunnel",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "vpn_config_content is empty"]
        )
      )
      return
    }

    guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      finishStart(
        completionHandler,
        error: NSError(
          domain: "Tunnel",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "failed to resolve App Group directory: \(appGroup)"]
        )
      )
      return
    }

    prepareDebugLog(at: groupURL)
    if let lastContext = consumeLastContext() {
      appendDebugLog("previous_context=\(lastContext)")
    }
    appendDebugLog("start requested appGroup=\(appGroup)")
    updateLastContext("start requested appGroup=\(appGroup)")
    appendDebugLog("runtime snapshot \(runtimeSnapshot())")
    let lifecycleID = beginTunnelLifecycle()

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
    let ipv4Settings = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4SubnetMask])
    // CRITICAL: Must include a default route to direct all traffic into the TUN interface
    // when Clash's auto-route is disabled.
    ipv4Settings.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4Settings
    if enableIPv6Route {
      let ipv6Settings = NEIPv6Settings(
        addresses: [ipv6Address],
        networkPrefixLengths: [NSNumber(value: ipv6PrefixLength)]
      )
      ipv6Settings.includedRoutes = [NEIPv6Route.default()]
      settings.ipv6Settings = ipv6Settings
    }
    settings.mtu = NSNumber(value: tunnelMTU)
    let dns = NEDNSSettings(servers: tunnelDNSServers)
    dns.matchDomains = [""]
    dns.matchDomainsNoSearch = true
    settings.dnsSettings = dns

    // iOS 15+ bug workaround: NetworkExtension might not route traffic to the tunnel
    // unless auto-route is enabled, OR we explicitly set the default route in settings.
    // The issue here is that iOS needs to know what traffic to send to the TUN interface.

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error {
        self.appendDebugLog("setTunnelNetworkSettings failed error=\(error.localizedDescription)")
        self.updateLastContext("setTunnelNetworkSettings failed error=\(error.localizedDescription)")
        self.endTunnelLifecycle()
        self.finishStart(completionHandler, error: error)
        return
      }

      self.appendDebugLog("network settings applied dns=\(self.tunnelDNSServers.joined(separator: ",")) mtu=\(self.tunnelMTU)")
      self.updateLastContext("network settings applied")

      guard let tunFd = self.getTunnelFd() else {
        self.appendDebugLog("failed to get utun fd")
        self.updateLastContext("failed to get utun fd")
        self.endTunnelLifecycle()
        self.finishStart(
          completionHandler,
          error: NSError(
            domain: "Tunnel",
            code: -4,
            userInfo: [NSLocalizedDescriptionKey: "failed to get utun file descriptor"]
          )
        )
        return
      }
      self.appendDebugLog("utun fd acquired=\(tunFd)")
      self.updateLastContext("utun fd acquired=\(tunFd)")

      let protector = SocketProtectorAdapter(provider: self)
      self.socketProtector = protector
      
      self.mihomoQueue.async {
        self.runWithMihomoAutoreleasePool {
          MobileSetLogLevel("debug")
          guard self.isTunnelActive(lifecycleID: lifecycleID) else {
            self.finishStart(
              completionHandler,
              error: NSError(
                domain: "Tunnel",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "tunnel lifecycle changed before start completed"]
              )
            )
            return
          }

          MobileSetSocketProtector(protector)
          self.appendDebugLog("socket protector installed")

          let tunConfig = self.injectTunConfig(configContent, fd: tunFd)
          self.appendDebugLog("tun config injected \(tunConfig.replacingOccurrences(of: "\n", with: " | "))")
          let configURL = groupURL.appendingPathComponent("config.yaml", isDirectory: false)
          do {
            try tunConfig.write(to: configURL, atomically: true, encoding: .utf8)
          } catch {
            MobileClearSocketProtector()
            self.appendDebugLog("persist config failed error=\(error.localizedDescription)")
            self.endTunnelLifecycle()
            self.socketProtector = nil
            self.finishStart(
              completionHandler,
              error: NSError(
                domain: "Tunnel",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "failed to persist config.yaml: \(error.localizedDescription)"]
              )
            )
            return
          }

          self.markCoreRunning(lifecycleID: lifecycleID)
          self.appendDebugLog("core start loop begin lifecycle=\(lifecycleID)")
          self.updateLastContext("core start loop begin lifecycle=\(lifecycleID)")
          self.startDiagnosticsTimer(lifecycleID: lifecycleID)
          self.startPathMonitor(lifecycleID: lifecycleID)

          DispatchQueue.global(qos: .userInitiated).async {
            self.updateLastContext("MobileStart begin lifecycle=\(lifecycleID)")
            self.runWithMihomoAutoreleasePool {
              MobileStart(groupURL.path, "config.yaml")
            }
            self.markCoreStopped(lifecycleID: lifecycleID)
            self.appendDebugLog("core exited lifecycle=\(lifecycleID)")
            self.updateLastContext("core exited lifecycle=\(lifecycleID)")
            if self.isTunnelActive(lifecycleID: lifecycleID) {
              self.handleUnexpectedCoreExit(lifecycleID: lifecycleID, groupURL: groupURL)
            }
          }

          guard self.waitForCoreWarmup(lifecycleID: lifecycleID, timeout: 3.0) else {
            self.appendDebugLog("core warmup failed, cancel start to avoid network blackhole")
            self.updateLastContext("core warmup failed")
            self.stopDiagnosticsTimer()
            self.cancelPathMonitor()
            self.endTunnelLifecycle()
            MobileStop()
            MobileClearSocketProtector()
            self.socketProtector = nil
            self.finishStart(
              completionHandler,
              error: NSError(
                domain: "Tunnel",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "mihomo core warmup failed"]
              )
            )
            return
          }

          let connectivityProbe = self.waitForStartupConnectivity(
            lifecycleID: lifecycleID,
            timeout: 4.0
          )
          guard connectivityProbe.ok else {
            self.appendDebugLog("startup connectivity probe failed detail=\(connectivityProbe.detail)")
            self.updateLastContext("startup connectivity probe failed")
            self.stopDiagnosticsTimer()
            self.cancelPathMonitor()
            self.endTunnelLifecycle()
            MobileStop()
            MobileClearSocketProtector()
            self.socketProtector = nil
            self.finishStart(
              completionHandler,
              error: NSError(
                domain: "Tunnel",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "startup connectivity probe failed: \(connectivityProbe.detail)"]
              )
            )
            return
          }

          self.appendDebugLog("startup connectivity probe passed detail=\(connectivityProbe.detail)")
          self.updateLastContext("startup connectivity probe passed")
          self.finishStart(completionHandler, error: nil)
        }
      }
    }
  }

  private func injectTunConfig(_ configContent: String, fd: Int32) -> String {
    let injectedBlock = """
tun:
  enable: true
  stack: system
  file-descriptor: \(fd)
  inet4-address:
    - \(ipv4Address)/\(ipv4PrefixLength)
  auto-route: false
  auto-detect-interface: false
  auto-redirect: false
  mtu: \(tunnelMTU)
"""
    let lines = configContent.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    var replacedTun = false

    while index < lines.count {
      let line = lines[index]
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      
      let isTopLevelTunLine = !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmedLine.hasPrefix("tun:")

      if !replacedTun && isTopLevelTunLine {
        output.append(contentsOf: injectedBlock.components(separatedBy: .newlines))
        replacedTun = true
        index += 1
        while index < lines.count {
          let next = lines[index]
          if !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
              !next.hasPrefix(" ") &&
              !next.hasPrefix("\t") {
            break
          }
          index += 1
        }
        continue
      }
      
      output.append(line)
      index += 1
    }
    
    if !replacedTun {
      return configContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + injectedBlock + "\n"
    }
    
    return output.joined(separator: "\n")
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    appendDebugLog("stop tunnel reason=\(reason.rawValue)")
    updateLastContext("stop tunnel reason=\(reason.rawValue)")
    appendDebugLog("runtime snapshot \(runtimeSnapshot())")
    cancelPathMonitor()
    stopDiagnosticsTimer()
    endTunnelLifecycle()
    
    mihomoQueue.async {
      self.runWithMihomoAutoreleasePool {
        self.updateLastContext("MobileStop begin")
        MobileStop()
        MobileClearSocketProtector()
        self.updateLastContext("MobileStop finished")
        DispatchQueue.main.async {
          self.socketProtector = nil
          completionHandler()
        }
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    appendDebugLog("sleep")
    updateLastContext("sleep")
    completionHandler()
  }

  override func wake() {
    appendDebugLog("wake")
    updateLastContext("wake")
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard self.isCoreRunning() else {
      completionHandler?(nil)
      return
    }
    mihomoQueue.async {
      self.runWithMihomoAutoreleasePool {
        guard self.isCoreRunning() else {
          completionHandler?(nil)
          return
        }
        if let message = String(data: messageData, encoding: .utf8),
           let response = self.handleLightweightAppMessage(message) {
          completionHandler?(response)
          return
        }

        guard
          let object = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
          let action = object["action"] as? String
        else {
          completionHandler?(nil)
          return
        }

        var response: [String: Any] = ["ok": true]

        switch action {
        case "changeMode":
          let mode = object["mode"] as? String ?? "rule"
          MobileSetMode(mode)
        case "getMode":
          response["value"] = MobileGetMode()
        case "getProxies":
          response["value"] = MobileGetProxies()
        case "getSelectedProxy":
          let groupName = object["groupName"] as? String ?? "GLOBAL"
          let proxiesJson = MobileGetProxies()
          response["value"] = self.extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
        case "urlTest":
          let name = object["name"] as? String ?? "GLOBAL"
          response["value"] = MobileTestLatency(name)
        case "selectProxy":
          let groupName = object["groupName"] as? String ?? "GLOBAL"
          let proxyName = object["proxyName"] as? String ?? ""
          response["ok"] = MobileSelectProxy(groupName, proxyName)
        case "reloadConfig":
          MobileForceUpdateConfig("config.yaml")
        case "getTraffic":
          response["up"] = MobileTrafficUp()
          response["down"] = MobileTrafficDown()
          response["totalUp"] = MobileTrafficTotalUp()
          response["totalDown"] = MobileTrafficTotalDown()
        case "getDebugLog":
          response["value"] = self.readDebugLog()
        default:
          response["ok"] = false
        }

        let data = try? JSONSerialization.data(withJSONObject: response)
        completionHandler?(data)
      }
    }
  }

  private func runWithMihomoAutoreleasePool<T>(_ body: () -> T) -> T {
    return autoreleasepool(invoking: body)
  }

  private func handleLightweightAppMessage(_ message: String) -> Data? {
    if message == "getMode" {
      let mode = MobileGetMode()
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(mode, forKey: "vpn_mode_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return mode.data(using: .utf8)
    }
    if message == "getProxies" {
      let proxiesJson = MobileGetProxies()
      // 当配置过大时（如超过几百KB），UserDefaults 存取可能影响性能或失败
      // 所以我们除了写 UserDefaults，也建议使用文件传递，但保持向后兼容
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(proxiesJson, forKey: "vpn_proxies_data")
        userDefaults.synchronize()
      }
      if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: defaultAppGroup) {
        let fileURL = groupURL.appendingPathComponent("vpn_proxies_data.json")
        try? proxiesJson.write(to: fileURL, atomically: true, encoding: .utf8)
        return "file://\(fileURL.path)".data(using: .utf8)
      }
      return "shared_mem".data(using: .utf8)
    }
    if message == "getDebugLog" {
      return readDebugLog().data(using: .utf8)
    }
    if message.hasPrefix("getSelectedProxy|") {
      let groupName = String(message.dropFirst("getSelectedProxy|".count))
      let proxiesJson = MobileGetProxies()
      let selected = extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
      
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(selected, forKey: "vpn_selected_proxy_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return selected.data(using: .utf8)
    }
    if message.hasPrefix("urlTest|") {
      let name = String(message.dropFirst("urlTest|".count))
      return MobileTestLatency(name).data(using: .utf8)
    }
    return nil
  }

  private func extractSelectedProxy(groupName: String, proxiesJson: String) -> String? {
    guard let data = proxiesJson.data(using: .utf8) else { return nil }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let proxies = root["proxies"] as? [String: Any] else { return nil }
    guard let group = proxies[groupName] as? [String: Any] else { return nil }
    return group["now"] as? String
  }

  private func prepareDebugLog(at groupURL: URL) {
    syncOnDebugLogQueue {
      debugLogURL = groupURL.appendingPathComponent("packet_tunnel_debug.log", isDirectory: false)
      if let debugLogURL {
        try? Data().write(to: debugLogURL, options: .atomic)
      }
    }
  }

  private func appendDebugLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    NSLog("%@", "[PacketTunnel] \(message)")
    syncOnDebugLogQueue {
      guard let debugLogURL = self.debugLogURL, let data = line.data(using: .utf8) else { return }
      if let fileHandle = try? FileHandle(forWritingTo: debugLogURL) {
        do {
          try fileHandle.seekToEnd()
          try fileHandle.write(contentsOf: data)
          try fileHandle.synchronize()
          try fileHandle.close()
        } catch {
          try? fileHandle.close()
        }
      } else {
        try? data.write(to: debugLogURL, options: .atomic)
      }
    }
  }

  private func readDebugLog() -> String {
    return syncOnDebugLogQueue {
      guard let debugLogURL, let content = try? String(contentsOf: debugLogURL, encoding: .utf8) else {
        return ""
      }
      return content
    }
  }

  private func syncOnDebugLogQueue<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: debugLogQueueKey) != nil {
      return work()
    }
    return debugLogQueue.sync(execute: work)
  }

  private func syncOnStateQueue<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
      return work()
    }
    return stateQueue.sync(execute: work)
  }

  private func startPathMonitor(lifecycleID: UInt64) {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.updateLastObservedInterfaceName(self.preferredInterfaceName(from: path))
      let fingerprint = self.pathFingerprint(path)
      let now = Date()
      guard self.shouldForceConfigRefreshForPathUpdate(
        lifecycleID: lifecycleID,
        fingerprint: fingerprint,
        pathStatus: path.status,
        now: now
      ) else { return }
      self.appendDebugLog("path update observed, forcing config update to refresh network state")
      self.updateLastContext("path update forcing config refresh")
      self.mihomoQueue.async {
        guard self.isCoreRunning(lifecycleID: lifecycleID) else { return }
        self.runWithMihomoAutoreleasePool {
          MobileForceUpdateConfig("config.yaml")
        }
      }
    }
    let previousMonitor = replacePathMonitor(with: monitor)
    previousMonitor?.cancel()
    monitor.start(queue: DispatchQueue(label: "com.accelerator.tg.packettunnel.path"))
  }

  private func pathFingerprint(_ path: Network.NWPath) -> String {
    let statuses = path.availableInterfaces
      .map { "\(String(describing: $0.type))-\($0.name)" }
      .sorted()
      .joined(separator: ",")
    return "\(String(describing: path.status))|\(path.isExpensive ? 1 : 0)|\(path.isConstrained ? 1 : 0)|\(statuses)"
  }

  private func handleUnexpectedCoreExit(lifecycleID: UInt64, groupURL: URL) {
    if shouldAttemptCoreRecovery(lifecycleID: lifecycleID) {
      appendDebugLog("core exited unexpectedly, attempting one recovery start")
      updateLastContext("core exited unexpectedly, attempting recovery")
      DispatchQueue.global(qos: .userInitiated).async {
        self.updateLastContext("core recovery MobileStart begin lifecycle=\(lifecycleID)")
        self.runWithMihomoAutoreleasePool {
          MobileStart(groupURL.path, "config.yaml")
        }
        self.markCoreStopped(lifecycleID: lifecycleID)
        self.appendDebugLog("core recovery start exited lifecycle=\(lifecycleID)")
        self.updateLastContext("core recovery start exited lifecycle=\(lifecycleID)")
        if self.isTunnelActive(lifecycleID: lifecycleID) {
          self.appendDebugLog("core recovery failed, cancel tunnel to recover system network")
          self.updateLastContext("core recovery failed, cancel tunnel")
          self.cancelTunnelWithError(
            NSError(
              domain: "Tunnel",
              code: -8,
              userInfo: [NSLocalizedDescriptionKey: "mihomo core recovery failed"]
            )
          )
        }
      }
      return
    }
    appendDebugLog("core exited unexpectedly, cancel tunnel to recover system network")
    updateLastContext("core exited unexpectedly, cancel tunnel")
    self.cancelTunnelWithError(
      NSError(
        domain: "Tunnel",
        code: -7,
        userInfo: [NSLocalizedDescriptionKey: "mihomo core exited unexpectedly"]
      )
    )
  }

  private func shouldAttemptCoreRecovery(lifecycleID: UInt64) -> Bool {
    return syncOnStateQueue {
      guard self.lifecycleID == lifecycleID, tunnelActive, !coreRecoveryAttempted else { return false }
      coreRecoveryAttempted = true
      return true
    }
  }

  private func beginTunnelLifecycle() -> UInt64 {
    return syncOnStateQueue {
      lifecycleID += 1
      tunnelActive = true
      coreRunning = false
      coreStartedAt = Date.distantPast
      coreRecoveryAttempted = false
      hasObservedInitialPathUpdate = false
      lastPathFingerprint = nil
      lastPathRestartAt = Date.distantPast
      lastObservedInterfaceName = nil
      updateLastContext("lifecycle begin id=\(lifecycleID)")
      return lifecycleID
    }
  }

  private func endTunnelLifecycle() {
    syncOnStateQueue {
      lifecycleID += 1
      tunnelActive = false
      coreRunning = false
      coreStartedAt = Date.distantPast
      coreRecoveryAttempted = false
      hasObservedInitialPathUpdate = false
      lastPathFingerprint = nil
      lastPathRestartAt = Date.distantPast
      lastObservedInterfaceName = nil
      updateLastContext("lifecycle end id=\(lifecycleID)")
    }
  }

  private func markCoreRunning(lifecycleID: UInt64) {
    syncOnStateQueue {
      guard self.lifecycleID == lifecycleID, tunnelActive else { return }
      coreRunning = true
      coreStartedAt = Date()
    }
  }

  private func markCoreStopped(lifecycleID: UInt64) {
    syncOnStateQueue {
      guard self.lifecycleID == lifecycleID else { return }
      coreRunning = false
      coreStartedAt = Date.distantPast
    }
  }

  private func isTunnelActive(lifecycleID: UInt64) -> Bool {
    return syncOnStateQueue {
      self.lifecycleID == lifecycleID && tunnelActive
    }
  }

  private func isCoreRunning(lifecycleID: UInt64? = nil) -> Bool {
    return syncOnStateQueue {
      guard coreRunning else { return false }
      guard let lifecycleID else { return tunnelActive }
      return self.lifecycleID == lifecycleID && tunnelActive
    }
  }

  private func finishStart(_ completionHandler: @escaping (Error?) -> Void, error: Error?) {
    DispatchQueue.main.async {
      completionHandler(error)
    }
  }

  private func startDiagnosticsTimer(lifecycleID: UInt64) {
    stopDiagnosticsTimer()
    let timer = DispatchSource.makeTimerSource(queue: debugLogQueue)
    timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      guard self.isTunnelActive(lifecycleID: lifecycleID) else { return }
      self.appendDebugLog("heartbeat lifecycle=\(lifecycleID) \(self.runtimeSnapshot())")
      self.updateLastContext("heartbeat lifecycle=\(lifecycleID)")
    }
    syncOnDebugLogQueue {
      diagnosticsTimer = timer
    }
    timer.resume()
  }

  private func stopDiagnosticsTimer() {
    let timer = syncOnDebugLogQueue { () -> DispatchSourceTimer? in
      let existingTimer = diagnosticsTimer
      diagnosticsTimer = nil
      return existingTimer
    }
    timer?.cancel()
  }

  private func runtimeSnapshot() -> String {
    let residentBytes = residentMemoryBytes()
    let residentMB = Double(residentBytes) / 1024.0 / 1024.0
    let uptime = ProcessInfo.processInfo.systemUptime
    return "resident_mb=\(String(format: "%.2f", residentMB)) uptime=\(String(format: "%.1f", uptime))"
  }

  private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
  }

  private func updateLastContext(_ value: String) {
    guard let userDefaults = UserDefaults(suiteName: currentAppGroupValue()) else { return }
    userDefaults.set(value, forKey: lastContextKey)
    userDefaults.set(ISO8601DateFormatter().string(from: Date()), forKey: lastContextTimeKey)
    userDefaults.synchronize()
  }

  private func consumeLastContext() -> String? {
    guard let userDefaults = UserDefaults(suiteName: currentAppGroupValue()) else { return nil }
    let value = userDefaults.string(forKey: lastContextKey)
    let time = userDefaults.string(forKey: lastContextTimeKey)
    userDefaults.removeObject(forKey: lastContextKey)
    userDefaults.removeObject(forKey: lastContextTimeKey)
    userDefaults.synchronize()
    guard let value else { return nil }
    if let time {
      return "\(time) \(value)"
    }
    return value
  }

  private func setCurrentAppGroup(_ appGroup: String) {
    syncOnStateQueue {
      currentAppGroup = appGroup
    }
  }

  private func currentAppGroupValue() -> String {
    return syncOnStateQueue {
      currentAppGroup
    }
  }

  private func replacePathMonitor(with monitor: NWPathMonitor?) -> NWPathMonitor? {
    return syncOnStateQueue {
      let previousMonitor = pathMonitor
      pathMonitor = monitor
      return previousMonitor
    }
  }

  private func cancelPathMonitor() {
    let monitor = replacePathMonitor(with: nil)
    monitor?.cancel()
    syncOnStateQueue {
      hasObservedInitialPathUpdate = false
      lastPathFingerprint = nil
      lastPathRestartAt = Date.distantPast
      lastObservedInterfaceName = nil
    }
  }

  private func shouldForceConfigRefreshForPathUpdate(
    lifecycleID: UInt64,
    fingerprint: String,
    pathStatus: Network.NWPath.Status,
    now: Date
  ) -> Bool {
    return syncOnStateQueue {
      guard self.lifecycleID == lifecycleID, tunnelActive else { return false }
      if !hasObservedInitialPathUpdate {
        hasObservedInitialPathUpdate = true
        guard pathStatus == .satisfied, coreRunning else { return false }
        guard now.timeIntervalSince(coreStartedAt) >= minCoreUptimeBeforePathRefresh else { return false }
        guard now.timeIntervalSince(lastPathRestartAt) >= pathRestartThrottle else { return false }
        lastPathFingerprint = fingerprint
        lastPathRestartAt = now
        return true
      }
      if fingerprint == lastPathFingerprint {
        return false
      }
      lastPathFingerprint = fingerprint
      guard pathStatus == .satisfied, coreRunning else { return false }
      guard now.timeIntervalSince(coreStartedAt) >= minCoreUptimeBeforePathRefresh else { return false }
      guard now.timeIntervalSince(lastPathRestartAt) >= pathRestartThrottle else { return false }
      lastPathRestartAt = now
      return true
    }
  }

  fileprivate func protectSocket(fd: Int32, network: String?, address: String?) -> Bool {
    let interfaceName = normalizedInterfaceName(network) ?? currentObservedInterfaceName()
    guard let interfaceName else { return true }
    let interfaceIndex = if_nametoindex(interfaceName)
    if interfaceIndex == 0 { return true }
    var boundIndex = Int32(interfaceIndex)
    let size = socklen_t(MemoryLayout<Int32>.size)
    let ipv4Result = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIndex, size)
    let ipv4Errno = errno
    let ipv6Result = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &boundIndex, size)
    let ipv6Errno = errno
    if ipv4Result == 0 || ipv6Result == 0 { return true }
    if isNonFatalSocketBindError(ipv4Errno) || isNonFatalSocketBindError(ipv6Errno) { return true }
    appendDebugLog("socket protect failed fd=\(fd) network=\(network ?? "nil") address=\(address ?? "nil") if=\(interfaceName) err4=\(ipv4Errno) err6=\(ipv6Errno)")
    return false
  }

  private func isNonFatalSocketBindError(_ code: Int32) -> Bool {
    switch code {
    case EINVAL, EAFNOSUPPORT, ENOPROTOOPT, EPROTONOSUPPORT, ENOTSUP:
      return true
    default:
      return false
    }
  }

  private func normalizedInterfaceName(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("utun") else { return nil }
    return trimmed
  }

  private func preferredInterfaceName(from path: Network.NWPath) -> String? {
    let interfaces = path.availableInterfaces.filter { !$0.name.hasPrefix("utun") }
    let preferred = interfaces.sorted { lhs, rhs in
      interfacePriority(lhs.type) > interfacePriority(rhs.type)
    }
    return preferred.first?.name
  }

  private func interfacePriority(_ type: Network.NWInterface.InterfaceType) -> Int {
    switch type {
    case .wifi:
      return 4
    case .wiredEthernet:
      return 3
    case .cellular:
      return 2
    case .loopback:
      return 1
    default:
      return 0
    }
  }

  private func updateLastObservedInterfaceName(_ value: String?) {
    syncOnStateQueue {
      lastObservedInterfaceName = value
    }
  }

  private func currentObservedInterfaceName() -> String? {
    return syncOnStateQueue {
      lastObservedInterfaceName
    }
  }

  private func waitForCoreWarmup(lifecycleID: UInt64, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !isTunnelActive(lifecycleID: lifecycleID) {
        return false
      }
      if !isCoreRunning(lifecycleID: lifecycleID) {
        return false
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return isTunnelActive(lifecycleID: lifecycleID) && isCoreRunning(lifecycleID: lifecycleID)
  }

  private func waitForStartupConnectivity(
    lifecycleID: UInt64,
    timeout: TimeInterval
  ) -> (ok: Bool, detail: String) {
    let urls = [
      "https://www.apple.com/library/test/success.html",
      "https://cp.cloudflare.com/generate_204"
    ]
    let deadline = Date().addingTimeInterval(timeout)
    var lastDetail = "no probe attempts"

    while Date() < deadline {
      if !isTunnelActive(lifecycleID: lifecycleID) || !isCoreRunning(lifecycleID: lifecycleID) {
        return (false, "core stopped during startup probe")
      }
      for rawURL in urls {
        guard let url = URL(string: rawURL) else { continue }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        let singleTimeout = min(1.5, max(0.5, remaining))
        let probe = probeStartupURL(url, timeout: singleTimeout)
        if probe.ok {
          return (true, probe.detail)
        }
        lastDetail = probe.detail
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return (false, lastDetail)
  }

  private func probeStartupURL(_ url: URL, timeout: TimeInterval) -> (ok: Bool, detail: String) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: (ok: Bool, detail: String) = (false, "unknown")
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let task = session.dataTask(with: request) { _, response, error in
      defer { semaphore.signal() }
      if let error {
        result = (false, "\(url.host ?? url.absoluteString) error=\(error.localizedDescription)")
        return
      }
      if let http = response as? HTTPURLResponse {
        if (200 ... 399).contains(http.statusCode) {
          result = (true, "\(url.host ?? url.absoluteString) status=\(http.statusCode)")
        } else {
          result = (false, "\(url.host ?? url.absoluteString) status=\(http.statusCode)")
        }
        return
      }
      result = (false, "\(url.host ?? url.absoluteString) no_http_response")
    }
    task.resume()
    let waitResult = semaphore.wait(timeout: .now() + timeout + 0.2)
    session.invalidateAndCancel()
    if waitResult == .timedOut {
      return (false, "\(url.host ?? url.absoluteString) timeout")
    }
    return result
  }
}
