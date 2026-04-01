import Foundation
import NetworkExtension
import Network

final class SocketProtectorAdapter: NSObject, MobileSocketProtector {
  private weak var provider: NEPacketTunnelProvider?

  init(provider: NEPacketTunnelProvider) {
    self.provider = provider
    super.init()
  }

  @objc(markSocket:network:address:)
  func markSocket(_ fd: Int64, network: String?, address: String?) -> Bool {
    return true
  }

  @objc(protectSocket:network:address:)
  func protectSocket(_ fd: Int64, network: String?, address: String?) -> Bool {
    return true
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let defaultAppGroup = "group.com.xiangyu.clash"
  private let tunnelRemoteAddress = "127.0.0.1"
  private let ipv4Address = "172.19.0.1"
  private let ipv4PrefixLength = 30
  private let ipv4SubnetMask = "255.255.255.252"
  private let tunnelIPv4DNSAddress = "172.19.0.2"
  private let enableIPv6Route = false
  private let ipv6Address = "fdfe:dcba:9876::1"
  private let ipv6PrefixLength = 126
  private let tunnelMTU = 1500
  private let pathRestartThrottle: TimeInterval = 2.0
  private var socketProtector: SocketProtectorAdapter?
  private var pathMonitor: NWPathMonitor?
  private var homeURL: URL?
  private var hasObservedInitialPathUpdate = false
  private var lastPathRestartAt = Date.distantPast
  private let mihomoQueue = DispatchQueue(label: "com.accelerator.tg.mihomo.core", qos: .userInitiated)
  private let stateQueue = DispatchQueue(label: "com.accelerator.tg.packettunnel.state")
  private let debugLogQueue = DispatchQueue(label: "com.accelerator.tg.packettunnel.debug")
  private var lifecycleID: UInt64 = 0
  private var tunnelActive = false
  private var coreRunning = false
  private var debugLogURL: URL?

  override init() {
    super.init()
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
    return self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32
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

    homeURL = groupURL
    prepareDebugLog(at: groupURL)
    appendDebugLog("start requested appGroup=\(appGroup)")
    let lifecycleID = beginTunnelLifecycle()

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
    let ipv4Settings = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4SubnetMask])
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
    let dns = NEDNSSettings(servers: [tunnelIPv4DNSAddress])
    dns.matchDomains = [""]
    dns.matchDomainsNoSearch = true
    settings.dnsSettings = dns

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error {
        self.appendDebugLog("setTunnelNetworkSettings failed error=\(error.localizedDescription)")
        self.endTunnelLifecycle()
        self.finishStart(completionHandler, error: error)
        return
      }

      self.appendDebugLog("network settings applied dns=\(self.tunnelIPv4DNSAddress) mtu=\(self.tunnelMTU)")

      guard let tunFd = self.getTunnelFd() else {
        self.appendDebugLog("failed to get utun fd")
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

          MobileStart(groupURL.path, "config.yaml")

          // MobileStart doesn't return an error in its signature, if it crashes it will crash the extension
          self.markCoreRunning(lifecycleID: lifecycleID)
          self.appendDebugLog("core started lifecycle=\(lifecycleID)")
          self.startPathMonitor(lifecycleID: lifecycleID)
          
          self.finishStart(completionHandler, error: nil)
        }
      }
    }
  }

  private func injectTunConfig(_ configContent: String, fd: Int32) -> String {
    let injectedBlock = """
tun:
  enable: true
  stack: gvisor
  file-descriptor: \(fd)
  auto-route: false
  auto-detect-interface: false
  auto-redirect: false
  mtu: 1500
  dns-hijack:
    - 0.0.0.0:53
    - "[::]:53"
"""
    let lines = configContent.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    var replacedTun = false
    var skipDns = false

    while index < lines.count {
      let line = lines[index]
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      
      let isTopLevelTunLine = !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmedLine.hasPrefix("tun:")
      let isTopLevelDnsLine = !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmedLine.hasPrefix("dns:")

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
      
      if isTopLevelDnsLine {
        skipDns = true
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
    pathMonitor?.cancel()
    pathMonitor = nil
    hasObservedInitialPathUpdate = false
    lastPathRestartAt = Date.distantPast
    endTunnelLifecycle()
    
    mihomoQueue.async {
      self.runWithMihomoAutoreleasePool {
        MobileStop()
        MobileClearSocketProtector()
        DispatchQueue.main.async {
          self.socketProtector = nil
          completionHandler()
        }
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    appendDebugLog("sleep")
    completionHandler()
  }

  override func wake() {
    appendDebugLog("wake")
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    // Note: Do not dispatch to mihomoQueue here.
    // Methods like MobileGetMode, MobileGetProxies, etc. are fast and thread-safe.
    // Dispatching them to the serial mihomoQueue can cause deadlocks if MobileStartWithMemory is stuck
    // or taking a long time to initialize.
    
    guard self.isCoreRunning() else {
      completionHandler?(nil)
      return
    }

    self.runWithMihomoAutoreleasePool {
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
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(proxiesJson, forKey: "vpn_proxies_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return proxiesJson.data(using: .utf8)
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
    debugLogQueue.sync {
      debugLogURL = groupURL.appendingPathComponent("packet_tunnel_debug.log", isDirectory: false)
      if let debugLogURL {
        try? Data().write(to: debugLogURL, options: .atomic)
      }
    }
  }

  private func appendDebugLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    NSLog("%@", "[PacketTunnel] \(message)")
    debugLogQueue.async {
      guard let debugLogURL = self.debugLogURL, let data = line.data(using: .utf8) else { return }
      if let fileHandle = try? FileHandle(forWritingTo: debugLogURL) {
        do {
          try fileHandle.seekToEnd()
          try fileHandle.write(contentsOf: data)
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
    return debugLogQueue.sync {
      guard let debugLogURL, let content = try? String(contentsOf: debugLogURL, encoding: .utf8) else {
        return ""
      }
      return content
    }
  }

  private func startPathMonitor(lifecycleID: UInt64) {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      guard let self else { return }
      guard self.isTunnelActive(lifecycleID: lifecycleID) else { return }
      if !self.hasObservedInitialPathUpdate {
        self.hasObservedInitialPathUpdate = true
        return
      }
      let now = Date()
      if now.timeIntervalSince(self.lastPathRestartAt) < self.pathRestartThrottle {
        return
      }
      self.lastPathRestartAt = now
      self.appendDebugLog("path update observed, forcing config update to refresh network state")
      self.mihomoQueue.async {
        guard self.isCoreRunning(lifecycleID: lifecycleID) else { return }
        self.runWithMihomoAutoreleasePool {
          MobileForceUpdateConfig("config.yaml")
        }
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.accelerator.tg.packettunnel.path"))
    pathMonitor = monitor
  }

  private func beginTunnelLifecycle() -> UInt64 {
    return stateQueue.sync {
      lifecycleID += 1
      tunnelActive = true
      coreRunning = false
      return lifecycleID
    }
  }

  private func endTunnelLifecycle() {
    stateQueue.sync {
      lifecycleID += 1
      tunnelActive = false
      coreRunning = false
    }
  }

  private func markCoreRunning(lifecycleID: UInt64) {
    stateQueue.sync {
      guard self.lifecycleID == lifecycleID, tunnelActive else { return }
      coreRunning = true
    }
  }

  private func isTunnelActive(lifecycleID: UInt64) -> Bool {
    return stateQueue.sync {
      self.lifecycleID == lifecycleID && tunnelActive
    }
  }

  private func isCoreRunning(lifecycleID: UInt64? = nil) -> Bool {
    return stateQueue.sync {
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
}
