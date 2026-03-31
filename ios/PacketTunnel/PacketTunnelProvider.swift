import Foundation
import NetworkExtension
import Network

@_silgen_name("MobileMihomoWarmup") private func MihomoWarmup()
@_silgen_name("MobileMobileStartWithMemory") private func MobileStartWithMemory(_ cfgStr: NSString?, _ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
@_silgen_name("MobileStart") private func MobileStart(_ home: NSString?, _ configFileName: NSString?)
@_silgen_name("MobileStop") private func MobileStop()
@_silgen_name("MobileSetMode") private func MobileSetMode(_ mode: NSString?)
@_silgen_name("MobileGetMode") private func MobileGetMode() -> NSString
@_silgen_name("MobileGetProxies") private func MobileGetProxies() -> NSString
@_silgen_name("MobileSelectProxy") private func MobileSelectProxy(_ groupName: NSString?, _ proxyName: NSString?) -> Bool
@_silgen_name("MobileTestLatency") private func MobileTestLatency(_ proxyName: NSString?) -> NSString
@_silgen_name("MobileForceUpdateConfig") private func MobileForceUpdateConfig(_ configFileName: NSString?)
@_silgen_name("MobileTrafficUp") private func MobileTrafficUp() -> Int64
@_silgen_name("MobileTrafficDown") private func MobileTrafficDown() -> Int64
@_silgen_name("MobileTrafficTotalUp") private func MobileTrafficTotalUp() -> Int64
@_silgen_name("MobileTrafficTotalDown") private func MobileTrafficTotalDown() -> Int64
@_silgen_name("MobileSetAppGroupDirectory") private func MobileSetAppGroupDirectory(_ dir: NSString?) -> Bool
@_silgen_name("MobileSetPacketFlowBridge") private func MobileSetPacketFlowBridge(_ bridge: AnyObject?)
@_silgen_name("MobileClearPacketFlowBridge") private func MobileClearPacketFlowBridge()
@_silgen_name("MobileFeedPacketBytes") private func MobileFeedPacketBytes(_ data: NSData?, _ af: Int64) -> Bool
@_silgen_name("MobileResetNetwork") private func MobileResetNetwork()
@_silgen_name("MobileSetSocketProtector") private func MobileSetSocketProtector(_ protector: AnyObject?)
@_silgen_name("MobileClearSocketProtector") private func MobileClearSocketProtector()
@_silgen_name("MobileSleep") private func MobileSleep()
@_silgen_name("MobileWake") private func MobileWake() -> Bool
@_silgen_name("MobileRestartTunnelForNetworkChange") private func MobileRestartTunnelForNetworkChange() -> Bool

final class PacketFlowBridgeAdapter: NSObject {
  private let packetFlow: NEPacketTunnelFlow
  private let onError: (String) -> Void
  private let lockQueue = DispatchQueue(label: "com.accelerator.tg.packetflow.bridge")

  init(packetFlow: NEPacketTunnelFlow, onError: @escaping (String) -> Void) {
    self.packetFlow = packetFlow
    self.onError = onError
    super.init()
  }

  @objc(onPacketFlowError:)
  func onPacketFlowError(_ message: NSString?) {
    onError(message as String? ?? "packet flow bridge error")
  }

  @objc(readPacket)
  func readPacket() -> AnyObject? {
    return nil
  }

  @objc(writePacket:)
  func writePacket(_ packet: AnyObject?) -> Bool {
    guard let packet else { return false }
    return autoreleasepool {
      guard let rawData = packet.perform(NSSelectorFromString("data"))?.takeUnretainedValue() as? Data else { return false }
      guard let afNum = packet.perform(NSSelectorFromString("af"))?.takeUnretainedValue() as? NSNumber else { return false }
      let af = afNum.int32Value
      if af != AF_INET && af != AF_INET6 {
        return false
      }
      packetFlow.writePackets([rawData], withProtocols: [NSNumber(value: af)])
      return true
    }
  }
}

final class SocketProtectorAdapter: NSObject {
  // Currently unused since NEPacketTunnelProvider doesn't provide a mark socket API for file descriptors directly
  // But we provide the implementation for the libmihomo hook.
  
  @objc(markSocket:network:address:)
  func markSocket(_ fd: Int64, network: NSString?, address: NSString?) -> Bool {
    return true
  }
  
  @objc(protectSocket:network:address:)
  func protectSocket(_ fd: Int64, network: NSString?, address: NSString?) -> Bool {
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

  override init() {
    super.init()
    MihomoWarmup()
  }

  override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    mihomoQueue.async { [weak self] in
      guard let self = self else { return }
      self.performStartTunnel(completionHandler: completionHandler)
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
        self.finishStart(completionHandler, error: error)
        return
      }

      _ = MobileSetAppGroupDirectory(groupURL.path as NSString)

      let bridge = PacketFlowBridgeAdapter(packetFlow: self.packetFlow) { message in
        self.cancelTunnelWithError(NSError(domain: "Tunnel", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
      }
      self.bridge = bridge
      MobileSetPacketFlowBridge(bridge)
      
      let protector = SocketProtectorAdapter()
      self.socketProtector = protector
      MobileSetSocketProtector(protector)
      
      self.startReadPacketsLoop()
      
      self.mihomoQueue.async {
        let tunConfig = self.injectTunConfig(configContent)
        let safeConfig = NSString(string: tunConfig)
        var startError: NSError?
        let started = withExtendedLifetime(safeConfig) {
          MobileStartWithMemory(safeConfig, &startError)
        }
        guard started else {
          self.bridge = nil
          MobileClearPacketFlowBridge()
          self.socketProtector = nil
          MobileClearSocketProtector()
          MobileStop()
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
        self.startPathMonitor()
        self.finishStart(completionHandler, error: nil)
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
    MobileClearPacketFlowBridge()
    bridge = nil
    MobileClearSocketProtector()
    socketProtector = nil
    
    mihomoQueue.async {
      MobileStop()
      DispatchQueue.main.async {
        completionHandler()
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    MobileSleep()
    completionHandler()
  }

  override func wake() {
    if !MobileWake() {
      _ = MobileRestartTunnelForNetworkChange()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    mihomoQueue.async { [weak self] in
      guard let self else { return }
      
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
        let mode = (object["mode"] as? String ?? "rule") as NSString
        MobileSetMode(mode)
      case "getMode":
        response["value"] = MobileGetMode() as String
      case "getProxies":
        response["value"] = MobileGetProxies() as String
      case "getSelectedProxy":
        let groupName = object["groupName"] as? String ?? "GLOBAL"
        let proxiesJson = MobileGetProxies() as String
        response["value"] = self.extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
      case "urlTest":
        let name = (object["name"] as? String ?? "GLOBAL") as NSString
        response["value"] = MobileTestLatency(name) as String
      case "selectProxy":
        let groupName = object["groupName"] as? String ?? "GLOBAL"
        let proxyName = object["proxyName"] as? String ?? ""
        response["ok"] = MobileSelectProxy(groupName as NSString, proxyName as NSString)
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

  private func handleLightweightAppMessage(_ message: String) -> Data? {
    if message == "getMode" {
      let mode = MobileGetMode() as String
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(mode, forKey: "vpn_mode_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return mode.data(using: .utf8)
    }
    if message == "getProxies" {
      let proxiesJson = MobileGetProxies() as String
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(proxiesJson, forKey: "vpn_proxies_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return proxiesJson.data(using: .utf8)
    }
    if message.hasPrefix("getSelectedProxy|") {
      let groupName = String(message.dropFirst("getSelectedProxy|".count))
      let proxiesJson = MobileGetProxies() as String
      let selected = extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
      
      if let userDefaults = UserDefaults(suiteName: defaultAppGroup) {
        userDefaults.set(selected, forKey: "vpn_selected_proxy_data")
        userDefaults.synchronize()
        return "shared_mem".data(using: .utf8)
      }
      return selected.data(using: .utf8)
    }
    if message.hasPrefix("urlTest|") {
      let name = String(message.dropFirst("urlTest|".count)) as NSString
      return (MobileTestLatency(name) as String).data(using: .utf8)
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

  private func startReadPacketsLoop() {
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      let count = min(packets.count, protocols.count)
      if count > 0, let bridge = self.bridge {
        for i in 0..<count {
          let packetData = packets[i]
          let af = Int64(protocols[i].int32Value)
          if packetData.isEmpty {
            continue
          }
          if af != Int64(AF_INET) && af != Int64(AF_INET6) {
            continue
          }
          autoreleasepool {
            _ = MobileFeedPacketBytes(packetData as NSData, af)
          }
        }
      }
      // Async dispatch to prevent stack overflow and high CPU usage from synchronous recursion
      DispatchQueue.main.async { [weak self] in
        self?.startReadPacketsLoop()
      }
    }
  }

  private func startPathMonitor() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { _ in
      if !self.hasObservedInitialPathUpdate {
        self.hasObservedInitialPathUpdate = true
        return
      }
      let now = Date()
      if now.timeIntervalSince(self.lastPathRestartAt) < self.pathRestartThrottle {
        return
      }
      self.lastPathRestartAt = now
      _ = MobileRestartTunnelForNetworkChange()
    }
    monitor.start(queue: DispatchQueue(label: "com.accelerator.tg.packettunnel.path"))
    pathMonitor = monitor
  }

  private func finishStart(_ completionHandler: @escaping (Error?) -> Void, error: Error?) {
    DispatchQueue.main.async {
      completionHandler(error)
    }
  }
}
