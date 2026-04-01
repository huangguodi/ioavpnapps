import Foundation
import NetworkExtension
import Network

final class PacketFlowBridgeAdapter: NSObject, MobilePacketFlowBridge {
  private let packetFlow: NEPacketTunnelFlow
  private let onError: (String) -> Void
  private let onPacketWritten: (Int32, Int) -> Void

  init(
    packetFlow: NEPacketTunnelFlow,
    onError: @escaping (String) -> Void,
    onPacketWritten: @escaping (Int32, Int) -> Void
  ) {
    self.packetFlow = packetFlow
    self.onError = onError
    self.onPacketWritten = onPacketWritten
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
  func write(_ packet: MobilePacketFlowPacket?) -> Bool {
    guard let packet else { return false }
    return autoreleasepool {
      guard let rawData = packet.data() else { return false }
      let af = Int32(packet.af())
      if af != AF_INET && af != AF_INET6 {
        return false
      }
      packetFlow.writePackets([rawData], withProtocols: [NSNumber(value: af)])
      onPacketWritten(af, rawData.count)
      return true
    }
  }
}

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
  private let tunnelMTU = 1400
  private let pathRestartThrottle: TimeInterval = 2.0
  private var bridge: PacketFlowBridgeAdapter?
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
  private var totalReadPackets: UInt64 = 0
  private var totalFedPackets: UInt64 = 0
  private var totalFeedFailures: UInt64 = 0
  private var totalWrittenPackets: UInt64 = 0

  override init() {
    super.init()
    let _ = NWPathMonitor()
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
      let bridge = PacketFlowBridgeAdapter(
        packetFlow: self.packetFlow,
        onError: { message in
          self.appendDebugLog("packet flow bridge error \(message)")
          self.cancelTunnelWithError(NSError(domain: "Tunnel", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
        },
        onPacketWritten: { af, size in
          self.recordWrittenPacket(af: af, size: size)
        }
      )
      self.bridge = bridge

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

          _ = MobileSetAppGroupDirectory(groupURL.path)
          MobileSetPacketFlowBridge(bridge)
          MobileSetSocketProtector(protector)
          self.appendDebugLog("packet flow bridge and socket protector installed")

          let tunConfig = self.injectTunConfig(configContent)
          self.appendDebugLog("tun config injected \(tunConfig.replacingOccurrences(of: "\n", with: " | "))")
          let configURL = groupURL.appendingPathComponent("config.yaml", isDirectory: false)
          do {
            try tunConfig.write(to: configURL, atomically: true, encoding: .utf8)
          } catch {
            MobileClearPacketFlowBridge()
            MobileClearSocketProtector()
            self.appendDebugLog("persist config failed error=\(error.localizedDescription)")
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
            self.appendDebugLog("core start failed error=\(startError?.localizedDescription ?? "unknown")")
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
          self.appendDebugLog("core started lifecycle=\(lifecycleID)")
          self.startPathMonitor(lifecycleID: lifecycleID)
          
          DispatchQueue.main.async {
            self.startReadPacketsLoop(lifecycleID: lifecycleID)
          }
          
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
  auto-route: true
  auto-detect-interface: true
  auto-redirect: false
  mtu: \(tunnelMTU)
  inet4-address:
    - \(ipv4Address)/\(ipv4PrefixLength)
  dns-hijack:
    - any:53
    - tcp://any:53
  exclude-route:
    - 127.0.0.0/8
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
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
    appendDebugLog("stop tunnel reason=\(reason.rawValue)")
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
    appendDebugLog("sleep")
    mihomoQueue.async {
      guard self.isCoreRunning() else { return }
      self.runWithMihomoAutoreleasePool {
        MobileResetNetwork()
      }
    }
    completionHandler()
  }

  override func wake() {
    appendDebugLog("wake")
    mihomoQueue.async {
      guard self.isCoreRunning() else { return }
      self.runWithMihomoAutoreleasePool {
        MobileResetNetwork()
      }
    }
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
      totalReadPackets = 0
      totalFedPackets = 0
      totalFeedFailures = 0
      totalWrittenPackets = 0
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

  private func recordWrittenPacket(af: Int32, size: Int) {
    let result = debugLogQueue.sync { () -> (Bool, UInt64) in
      totalWrittenPackets += 1
      return (totalWrittenPackets <= 5 || totalWrittenPackets % 200 == 0, totalWrittenPackets)
    }
    if result.0 {
      appendDebugLog("write packet count=\(result.1) af=\(af) size=\(size)")
    }
  }

  private func startReadPacketsLoop(lifecycleID: UInt64) {
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      guard self.isTunnelActive(lifecycleID: lifecycleID) else { return }
      let count = min(packets.count, protocols.count)
      if count > 0 {
        var packetBatch: [(Data, Int64)] = []
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
          packetBatch.append((packetData, af))
        }

        if !packetBatch.isEmpty {
          let readCount = packetBatch.count
          let readResult = self.debugLogQueue.sync { () -> (Bool, UInt64) in
            self.totalReadPackets += UInt64(readCount)
            return (self.totalReadPackets <= 5 || self.totalReadPackets % 200 == 0, self.totalReadPackets)
          }
          if readResult.0 {
            self.appendDebugLog("read packets total=\(readResult.1) batch=\(readCount)")
          }
          
          // CRITICAL FIX: Make a deep copy of the Data objects to avoid memory corruption
          // because the NSData provided by NetworkExtension is only valid within this closure.
          let copiedBatch = packetBatch.map { (Data($0.0), $0.1) }
          
          self.mihomoQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCoreRunning(lifecycleID: lifecycleID) else { return }
            self.runWithMihomoAutoreleasePool {
              for (packetData, af) in copiedBatch {
                let fed = MobileFeedPacketBytes(packetData, af)
                let event = self.debugLogQueue.sync { () -> (Bool, UInt64, UInt64) in
                  if fed {
                    self.totalFedPackets += 1
                    let shouldLog = self.totalFedPackets <= 5 || self.totalFedPackets % 200 == 0
                    return (shouldLog, self.totalFedPackets, self.totalFeedFailures)
                  } else {
                    self.totalFeedFailures += 1
                    let shouldLog = self.totalFeedFailures <= 10 || self.totalFeedFailures % 50 == 0
                    return (shouldLog, self.totalFedPackets, self.totalFeedFailures)
                  }
                }
                if event.0 {
                  if fed {
                    self.appendDebugLog("feed packet success total=\(event.1) af=\(af) size=\(packetData.count)")
                  } else {
                    self.appendDebugLog("feed packet failed failures=\(event.2) af=\(af) size=\(packetData.count)")
                  }
                }
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
      self.appendDebugLog("path update reset network")
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
