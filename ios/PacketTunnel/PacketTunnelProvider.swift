import Foundation
import NetworkExtension
import Network

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
@_silgen_name("MobileFeedPacketFromFlow") private func MobileFeedPacketFromFlow(_ packet: AnyObject?) -> Bool
@_silgen_name("MobileNewPacketFlowPacket") private func MobileNewPacketFlowPacket(_ data: NSData?, _ af: Int64) -> AnyObject?
@_silgen_name("MobileSleep") private func MobileSleep()
@_silgen_name("MobileWake") private func MobileWake() -> Bool
@_silgen_name("MobileRestartTunnelForNetworkChange") private func MobileRestartTunnelForNetworkChange() -> Bool

final class PacketFlowBridgeAdapter: NSObject {
  private let packetFlow: NEPacketTunnelFlow
  private let onError: (String) -> Void
  private let lockQueue = DispatchQueue(label: "com.accelerator.tg.packetflow.bridge")
  private var inboundQueue: [AnyObject] = []

  init(packetFlow: NEPacketTunnelFlow, onError: @escaping (String) -> Void) {
    self.packetFlow = packetFlow
    self.onError = onError
    super.init()
  }

  func enqueueInbound(_ packet: AnyObject) {
    lockQueue.sync {
      inboundQueue.append(packet)
      if inboundQueue.count > 2048 {
        inboundQueue.removeFirst(inboundQueue.count - 2048)
      }
    }
  }

  @objc(onPacketFlowError:)
  func onPacketFlowError(_ message: NSString?) {
    onError(message as String? ?? "packet flow bridge error")
  }

  @objc(readPacket)
  func readPacket() -> AnyObject? {
    lockQueue.sync {
      if inboundQueue.isEmpty {
        return nil
      }
      return inboundQueue.removeFirst()
    }
  }

  @objc(writePacket:)
  func writePacket(_ packet: AnyObject?) -> Bool {
    guard let packet else { return false }
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

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let defaultAppGroup = "group.com.xiangyu.clash"
  private let ipv4Address = "198.18.0.1"
  private let ipv4SubnetMask = "255.255.255.0"
  private let ipv6Address = "fdfe:dcba:9876::1"
  private let ipv6PrefixLength = 126
  private let dnsServers = ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"]
  private let pathRestartThrottle: TimeInterval = 2.0
  private var bridge: PacketFlowBridgeAdapter?
  private var pathMonitor: NWPathMonitor?
  private var homeURL: URL?
  private var hasObservedInitialPathUpdate = false
  private var lastPathRestartAt = Date.distantPast

  override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    let configContent = providerConfig["configContent"] as? String ?? ""
    let appGroup = providerConfig["appGroup"] as? String ?? defaultAppGroup

    guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      completionHandler(NSError(domain: "Tunnel", code: -2, userInfo: [NSLocalizedDescriptionKey: "invalid app group"]))
      return
    }

    homeURL = groupURL
    let configURL = groupURL.appendingPathComponent("config.yaml")

    do {
      try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
      try configContent.write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      completionHandler(error)
      return
    }

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
    settings.mtu = 1400
    let dns = NEDNSSettings(servers: dnsServers)
    dns.matchDomains = [""]
    settings.dnsSettings = dns

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error = error {
        completionHandler(error)
        return
      }

      guard MobileSetAppGroupDirectory(groupURL.path as NSString) else {
        completionHandler(NSError(domain: "Tunnel", code: -3, userInfo: [NSLocalizedDescriptionKey: "set app group directory failed"]))
        return
      }

      let bridge = PacketFlowBridgeAdapter(packetFlow: self.packetFlow) { message in
        self.cancelTunnelWithError(NSError(domain: "Tunnel", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
      }
      self.bridge = bridge
      MobileSetPacketFlowBridge(bridge)
      MobileStart(groupURL.path as NSString, "config.yaml")
      self.startReadPacketsLoop()
      self.startPathMonitor()
      completionHandler(nil)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    pathMonitor?.cancel()
    pathMonitor = nil
    hasObservedInitialPathUpdate = false
    lastPathRestartAt = Date.distantPast
    MobileClearPacketFlowBridge()
    bridge = nil
    MobileStop()
    completionHandler()
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
    if let message = String(data: messageData, encoding: .utf8),
       let response = handleLightweightAppMessage(message) {
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
      response["value"] = extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
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

  private func handleLightweightAppMessage(_ message: String) -> Data? {
    if message == "getMode" {
      return (MobileGetMode() as String).data(using: .utf8)
    }
    if message == "getProxies" {
      return (MobileGetProxies() as String).data(using: .utf8)
    }
    if message.hasPrefix("getSelectedProxy|") {
      let groupName = String(message.dropFirst("getSelectedProxy|".count))
      let proxiesJson = MobileGetProxies() as String
      let selected = extractSelectedProxy(groupName: groupName, proxiesJson: proxiesJson) ?? ""
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
          if let mobilePacket = MobileNewPacketFlowPacket(packetData as NSData, af) {
            bridge.enqueueInbound(mobilePacket)
            _ = MobileFeedPacketFromFlow(mobilePacket)
          }
        }
      }
      self.startReadPacketsLoop()
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
}
