import Foundation
import NetworkExtension
import Network

final class PacketFlowBridgeAdapter: NSObject, MobilePacketFlowBridgeProtocol {
  private let packetFlow: NEPacketTunnelFlow
  private let onError: (String) -> Void
  private let lockQueue = DispatchQueue(label: "com.accelerator.tg.packetflow.bridge")

  init(packetFlow: NEPacketTunnelFlow, onError: @escaping (String) -> Void) {
    self.packetFlow = packetFlow
    self.onError = onError
    super.init()
  }

  @objc(onPacketFlowError:)
  func onPacketFlowError(_ message: String?) {
    onError(message ?? "packet flow bridge error")
  }

  @objc(readPacket)
  func readPacket() -> MobilePacketFlowPacket? {
    return nil
  }

  @objc(writePacket:)
  func writePacket(_ packet: MobilePacketFlowPacket?) -> Bool {
    guard let packet else { return false }
    return autoreleasepool {
      guard let rawData = packet.data() else { return false }
      let af = Int32(packet.af())
      if af != AF_INET && af != AF_INET6 {
        return false
      }
      packetFlow.writePackets([rawData], withProtocols: [NSNumber(value: af)])
      return true
    }
  }
}

final class SocketProtectorAdapter: NSObject, MobileSocketProtectorProtocol {
  // Currently unused since NEPacketTunnelProvider doesn't provide a mark socket API for file descriptors directly
  // But we provide the implementation for the libmihomo hook.
  
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
  private let ipv4Address = "198.18.0.1"
  private let ipv4SubnetMask = "255.255.255.0"
  private let ipv6Address = "fdfe:dcba:9876::1"
  private let ipv6PrefixLength = 126
  private let dnsServers = ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"]
  private let pathRestartThrottle: TimeInterval = 2.0
  private var bridge: PacketFlowBridgeAdapter?
  private var socketProtector: SocketProtectorAdapter?
  private var pathMonitor: NWPathMonitor?
  private var homeURL: URL?
  private var hasObservedInitialPathUpdate = false
  private var lastPathRestartAt = Date.distantPast
  private let mihomoQueue = DispatchQueue(label: "com.accelerator.tg.mihomo.core", qos: .userInitiated)
  private let stateQueue = DispatchQueue(label: "com.accelerator.tg.packettunnel.state")
  private var lifecycleID: UInt64 = 0
  private var tunnelActive = false
  private var coreRunning = false

  override init() {
    super.init()
    MobileMihomoWarmup()
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
    if let userDefaults = UserDefaults(suiteName: appGroup),
       let savedConfig = userDefaults.string(forKey: "vpn_config_content") {
      configContent = savedConfig
      // 配置读取后清空，不留冗余数据
      userDefaults.removeObject(forKey: "vpn_config_content")
      userDefaults.synchronize()
    } else {
      configContent = ""
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
    let lifecycleID = beginTunnelLifecycle()

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: ipv4Address)
    let ipv4Settings = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4SubnetMask])
    ipv4Settings.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4Settings
    let ipv6Settings = NEIPv6Settings(
      addresses: [ipv6Address],
      networkPrefixLengths: [NSNumber(value: ipv6PrefixLength)]
    )
    ipv6Settings.includedRoutes = [NEIPv6Route.default()]
    settings.ipv6Settings = ipv6Settings
    settings.mtu = 9000
    let dns = NEDNSSettings(servers: dnsServers)
    dns.matchDomains = [""]
    settings.dnsSettings = dns

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error {
        self.endTunnelLifecycle()
        self.finishStart(completionHandler, error: error)
        return
      }

      let bridge = PacketFlowBridgeAdapter(packetFlow: self.packetFlow) { message in
        self.cancelTunnelWithError(NSError(domain: "Tunnel", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
      }
      self.bridge = bridge
      
      let protector = SocketProtectorAdapter()
      self.socketProtector = protector
      
      self.mihomoQueue.async {
        self.runWithMihomoAutoreleasePool {
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

          _ = MobileSetAppGroupDirectory(groupURL.path)
          MobileSetPacketFlowBridge(bridge)
          MobileSetSocketProtector(protector)
          DispatchQueue.main.async {
            self.startReadPacketsLoop(lifecycleID: lifecycleID)
          }

          let tunConfig = self.injectTunConfig(configContent)
          let configURL = groupURL.appendingPathComponent("config.yaml", isDirectory: false)
          do {
            try tunConfig.write(to: configURL, atomically: true, encoding: .utf8)
          } catch {
            MobileClearPacketFlowBridge()
            MobileClearSocketProtector()
            self.endTunnelLifecycle()
            self.bridge = nil
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
          var startError: NSError?
          let started = withExtendedLifetime(tunConfig) {
            MobileMobileStartWithMemory(tunConfig, &startError)
          }
          guard started else {
            MobileStop()
            MobileClearPacketFlowBridge()
            MobileClearSocketProtector()
            self.endTunnelLifecycle()
            self.bridge = nil
            self.socketProtector = nil
            self.finishStart(
              completionHandler,
              error: startError ?? NSError(
                domain: "Tunnel",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "MobileStartWithMemory returned false"]
              )
            )
            return
          }

          self.markCoreRunning(lifecycleID: lifecycleID)
          self.startPathMonitor(lifecycleID: lifecycleID)
          self.finishStart(completionHandler, error: nil)
        }
      }
    }
  }

  private func injectTunConfig(_ configContent: String) -> String {
    let tunBlock = """
tun:
  enable: true
  stack: gvisor
  auto-route: false
  auto-detect-interface: false
  auto-redirect: false
  mtu: 9000
  dns-hijack:
    - 0.0.0.0:53
    - "[::]:53"
"""
    let lines = configContent.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    var replaced = false
    while index < lines.count {
      let line = lines[index]
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let isTopLevelTunLine = !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmedLine.hasPrefix("tun:")
      if !replaced && isTopLevelTunLine {
        output.append(contentsOf: tunBlock.components(separatedBy: .newlines))
        replaced = true
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
    if !replaced {
      return configContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + tunBlock + "\n"
    }
    return output.joined(separator: "\n")
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    pathMonitor?.cancel()
    pathMonitor = nil
    hasObservedInitialPathUpdate = false
    lastPathRestartAt = Date.distantPast
    endTunnelLifecycle()
    
    mihomoQueue.async {
      self.runWithMihomoAutoreleasePool {
        MobileStop()
        MobileClearPacketFlowBridge()
        MobileClearSocketProtector()
        DispatchQueue.main.async {
          self.bridge = nil
          self.socketProtector = nil
          completionHandler()
        }
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    mihomoQueue.async {
      guard self.isCoreRunning() else { return }
      self.runWithMihomoAutoreleasePool {
        MobileResetNetwork()
      }
    }
    completionHandler()
  }

  override func wake() {
    mihomoQueue.async {
      guard self.isCoreRunning() else { return }
      self.runWithMihomoAutoreleasePool {
        MobileResetNetwork()
      }
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    mihomoQueue.async { [weak self] in
      guard let self else { return }
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
          response["value"] = self.mobileGetModeString()
        case "getProxies":
          response["value"] = self.mobileGetProxiesString()
        case "getSelectedProxy":
          let groupName = object["groupName"] as? String ?? "GLOBAL"
          let proxiesJson = self.mobileGetProxiesString()
          response["value"] = self.extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
        case "urlTest":
          let name = object["name"] as? String ?? "GLOBAL"
          response["value"] = self.mobileTestLatencyString(name)
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
      let mode = mobileGetModeString()
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(mode, forKey: "vpn_mode_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return mode.data(using: .utf8)
    }
    if message == "getProxies" {
      let proxiesJson = mobileGetProxiesString()
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(proxiesJson, forKey: "vpn_proxies_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return proxiesJson.data(using: .utf8)
    }
    if message.hasPrefix("getSelectedProxy|") {
      let groupName = String(message.dropFirst("getSelectedProxy|".count))
      let proxiesJson = mobileGetProxiesString()
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
      return mobileTestLatencyString(name).data(using: .utf8)
    }
    return nil
  }

  private func mobileGetModeString() -> String {
    return autoreleasepool {
      return MobileGetMode()
    }
  }

  private func mobileGetProxiesString() -> String {
    return autoreleasepool {
      return MobileGetProxies()
    }
  }

  private func mobileTestLatencyString(_ proxyName: String) -> String {
    return autoreleasepool {
      return MobileTestLatency(proxyName)
    }
  }

  private func extractSelectedProxy(groupName: String, proxiesJson: String) -> String? {
    guard let data = proxiesJson.data(using: .utf8) else { return nil }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let proxies = root["proxies"] as? [String: Any] else { return nil }
    guard let group = proxies[groupName] as? [String: Any] else { return nil }
    return group["now"] as? String
  }

  private func startReadPacketsLoop(lifecycleID: UInt64) {
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      guard self.isTunnelActive(lifecycleID: lifecycleID) else { return }
      let count = min(packets.count, protocols.count)
      if count > 0 {
        var packetBatch: [(NSData, Int64)] = []
        packetBatch.reserveCapacity(count)
        for i in 0..<count {
          let packetData = packets[i]
          let af = Int64(protocols[i].int32Value)
          if packetData.isEmpty {
            continue
          }
          if af != Int64(AF_INET) && af != Int64(AF_INET6) {
            continue
          }
          packetBatch.append((packetData as NSData, af))
        }

        if !packetBatch.isEmpty {
          self.mihomoQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCoreRunning(lifecycleID: lifecycleID) else { return }
            self.runWithMihomoAutoreleasePool {
              for (packetData, af) in packetBatch {
                _ = MobileFeedPacketBytes(packetData, af)
              }
            }
          }
        }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.isTunnelActive(lifecycleID: lifecycleID) else { return }
        self.startReadPacketsLoop(lifecycleID: lifecycleID)
      }
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
      self.mihomoQueue.async {
        guard self.isCoreRunning(lifecycleID: lifecycleID) else { return }
        self.runWithMihomoAutoreleasePool {
          MobileResetNetwork()
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
