import Flutter
import UIKit
import Darwin
import NetworkExtension

@_silgen_name("MobileStart") private func MobileStart(_ home: NSString?, _ configFileName: NSString?)
@_silgen_name("MobileStop") private func MobileStop()
@_silgen_name("MobileSetMode") private func MobileSetMode(_ mode: NSString?)
@_silgen_name("MobileGetMode") private func MobileGetMode() -> NSString
@_silgen_name("MobileGetProxies") private func MobileGetProxies() -> NSString
@_silgen_name("MobileSelectProxy") private func MobileSelectProxy(_ groupName: NSString?, _ proxyName: NSString?) -> Bool
@_silgen_name("MobileTestLatency") private func MobileTestLatency(_ proxyName: NSString?) -> NSString
@_silgen_name("MobileForceUpdateConfig") private func MobileForceUpdateConfig(_ configFileName: NSString?)

final class TunnelTrafficStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var timer: Timer?
  private let fetch: (@escaping ([String: Any]) -> Void) -> Void
  private var lastSnapshot: [String: Int64]?
  private var unchangedTickCount = 0

  private let activeInterval: TimeInterval = 1.0
  private let idleInterval: TimeInterval = 1.8
  private let inactiveInterval: TimeInterval = 3.0

  init(fetch: @escaping (@escaping ([String: Any]) -> Void) -> Void) {
    self.fetch = fetch
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    lastSnapshot = nil
    unchangedTickCount = 0
    scheduleNextTick(after: 0.15)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    return nil
  }

  private func scheduleNextTick(after interval: TimeInterval) {
    timer?.invalidate()
    guard sink != nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
      [weak self] _ in
      self?.performTick()
    }
  }

  private func performTick() {
    guard sink != nil else { return }
    fetch { [weak self] data in
      guard let self, let sink = self.sink else { return }
      let snapshot = self.snapshot(from: data)
      let didChange = snapshot != self.lastSnapshot
      if didChange {
        self.lastSnapshot = snapshot
        self.unchangedTickCount = 0
      } else {
        self.unchangedTickCount += 1
      }

      if didChange || self.unchangedTickCount == 0 || self.unchangedTickCount % 3 == 0 {
        DispatchQueue.main.async {
          sink(data)
        }
      }
      self.scheduleNextTick(after: self.nextInterval(didChange: didChange))
    }
  }

  private func nextInterval(didChange: Bool) -> TimeInterval {
    if UIApplication.shared.applicationState != .active {
      return inactiveInterval
    }
    if didChange || unchangedTickCount < 3 {
      return activeInterval
    }
    return idleInterval
  }

  private func snapshot(from data: [String: Any]) -> [String: Int64] {
    [
      "up": data["up"] as? Int64 ?? Int64(data["up"] as? Int ?? 0),
      "down": data["down"] as? Int64 ?? Int64(data["down"] as? Int ?? 0),
      "totalUp": data["totalUp"] as? Int64 ?? Int64(data["totalUp"] as? Int ?? 0),
      "totalDown": data["totalDown"] as? Int64 ?? Int64(data["totalDown"] as? Int ?? 0),
    ]
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let tunnelBundleIdentifier = "com.xiangyu.clash.packettunnel"
  private let tunnelDescription = "CarbonLAM Tunnel"
  private let appGroupIdentifier = "group.com.xiangyu.clash"
  private var trafficStreamHandler: TunnelTrafficStreamHandler?
  private var channelsConfigured = false
  private var cachedTunnelManager: NETunnelProviderManager?
  private var isLoadingTunnelManager = false
  private var pendingTunnelManagerCompletions: [(NETunnelProviderManager?, Error?) -> Void] = []
  private let postStartStatusQueryDelay: TimeInterval = 1.2
  private let tunnelStartRetryDelay: TimeInterval = 1.0
  private let tunnelStartMaxAttempts = 2
  private var deferStatusQueriesUntil: Date?
  
  private var cachedProxiesJson: String?
  private var lastProxiesFileModification: Date?
  private let fileIOQueue = DispatchQueue(label: "com.accelerator.tg.fileio", qos: .userInitiated)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    primeTunnelManagerCache()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func configureChannelsIfNeeded(with controller: FlutterViewController) {
    if channelsConfigured {
      return
    }
    channelsConfigured = true
    let channel = FlutterMethodChannel(name: "com.accelerator.tg/mihomo",
                                              binaryMessenger: controller.binaryMessenger)
    let trafficChannel = FlutterEventChannel(name: "com.accelerator.tg/mihomo/traffic",
                                             binaryMessenger: controller.binaryMessenger)
    let securityChannel = FlutterMethodChannel(name: "com.accelerator.tg/security",
                                               binaryMessenger: controller.binaryMessenger)
    let hotUpdateChannel = FlutterMethodChannel(name: "com.accelerator.tg/hot_update",
                                                binaryMessenger: controller.binaryMessenger)
    let handler = TunnelTrafficStreamHandler { completion in
      self.sendProviderCommand(["action": "getTraffic"]) { resp in
        let up = resp["up"] as? Int64 ?? Int64(resp["up"] as? Int ?? 0)
        let down = resp["down"] as? Int64 ?? Int64(resp["down"] as? Int ?? 0)
        completion([
          "up": up,
          "down": down,
          "totalUp": resp["totalUp"] as? Int64 ?? Int64(resp["totalUp"] as? Int ?? 0),
          "totalDown": resp["totalDown"] as? Int64 ?? Int64(resp["totalDown"] as? Int ?? 0),
        ])
      }
    }
    trafficStreamHandler = handler
    trafficChannel.setStreamHandler(handler)
    securityChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "isDebuggerAttached" {
        result(self.isDebuggerAttached())
      } else if call.method == "isAppDebuggable" {
        #if DEBUG
        result(true)
        #else
        result(false)
        #endif
      } else if call.method == "isProxyDetected" {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        let httpEnable = (settings?["HTTPEnable"] as? NSNumber)?.boolValue ?? false
        let httpsEnable = (settings?["HTTPSEnable"] as? NSNumber)?.boolValue ?? false
        result(httpEnable || httpsEnable)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
    hotUpdateChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "restartApp" {
        result(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          exit(0)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
    channel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "initAssets" {
          result(nil)
      } else if call.method == "requestVpnPermission" {
          self.requestTunnelPermission { error in
            if let error = error {
              result(FlutterError(code: "VPN_PERMISSION_DENIED", message: self.describeError(error), details: nil))
            } else {
              result(true)
            }
          }
      } else if call.method == "getAppGroupDirectory" {
          if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.appGroupIdentifier) {
            result(groupURL.path)
          } else {
            result(FlutterError(code: "UNAVAILABLE", message: "Cannot get App Group directory", details: nil))
          }
      } else if call.method == "getAesKey" {
          result(self.nativeAesKey())
      } else if call.method == "getObfuscateKey" {
          result(self.nativeObfuscateKey())
      } else if call.method == "getServerUrlKey" {
          result(self.nativeServerUrlKey())
      } else if call.method == "startMihomo" || call.method == "start" {
          guard let args = call.arguments as? [String: Any],
                let configPath = args["configPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "configPath is required", details: nil))
            return
          }
          let configContent = (args["configContent"] as? String) ?? (try? String(contentsOfFile: configPath)) ?? ""
          self.startTunnel(configContent: configContent) { error in
            if let error = error {
              result(FlutterError(code: "START_FAILED", message: self.describeError(error), details: nil))
            } else {
              result(nil)
            }
          }
      } else if call.method == "stopMihomo" || call.method == "stop" {
          self.stopTunnel {
            result(nil)
          }
      } else if call.method == "isRunning" || call.method == "isMihomoRunning" {
          self.loadTunnelManager(forceRefresh: true) { manager, _ in
            let status = manager?.connection.status ?? .invalid
            result(status == .connected || status == .reasserting || status == .connecting)
          }
      } else if call.method == "changeMode" || call.method == "setModeNative" {
          let args = call.arguments as? [String: Any]
          let mode = (args?["mode"] as? String ?? "rule")
          self.sendProviderCommand(["action": "changeMode", "mode": mode]) { resp in
            result((resp["ok"] as? Bool) ?? false)
          }
      } else if call.method == "getMode" || call.method == "getModeNative" {
          self.sendProviderStringMessage("getMode") { value in
            guard let val = value else {
              result(nil)
              return
            }
            if val == "shared_mem" {
              if let userDefaults = UserDefaults(suiteName: self.appGroupIdentifier),
                 let mode = userDefaults.string(forKey: "vpn_mode_data") {
                result(mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
              } else {
                result(nil)
              }
            } else {
              result(val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
          }
      } else if call.method == "getProxies" {
          self.sendProviderStringMessage("getProxies") { value in
            guard let val = value else {
              result("{}")
              return
            }
            if val == "shared_mem" {
              if let userDefaults = UserDefaults(suiteName: self.appGroupIdentifier),
                 let content = userDefaults.string(forKey: "vpn_proxies_data") {
                result(content)
              } else {
                result("{}")
              }
            } else if val.hasPrefix("file://") {
              let path = String(val.dropFirst(7))
              self.fileIOQueue.async {
                do {
                  let attrs = try FileManager.default.attributesOfItem(atPath: path)
                  let modDate = attrs[.modificationDate] as? Date
                  
                  if let cached = self.cachedProxiesJson,
                     let lastMod = self.lastProxiesFileModification,
                     let currentMod = modDate,
                     lastMod == currentMod {
                    DispatchQueue.main.async { result(cached) }
                    return
                  }
                  
                  let content = try String(contentsOfFile: path, encoding: .utf8)
                  self.cachedProxiesJson = content
                  self.lastProxiesFileModification = modDate
                  DispatchQueue.main.async { result(content) }
                } catch {
                  DispatchQueue.main.async { result("{}") }
                }
              }
            } else {
              // Fallback to original value if it's somehow returned directly
              result(val)
            }
          }
      } else if call.method == "urlTest" {
          let args = call.arguments as? [String: Any]
          let name = (args?["name"] as? String ?? "GLOBAL")
          self.sendProviderStringMessage("urlTest|\(name)") { value in
            result(value ?? "")
          }
      } else if call.method == "selectProxy" {
          let args = call.arguments as? [String: Any]
          let name = (args?["name"] as? String ?? args?["proxyName"] as? String ?? "")
          if name.isEmpty {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "proxy name is required", details: nil))
            return
          }
          self.sendProviderCommand(["action": "selectProxy", "groupName": "GLOBAL", "proxyName": name]) { resp in
            result((resp["ok"] as? Bool) ?? false)
          }
      } else if call.method == "selectProxyByGroup" {
          let args = call.arguments as? [String: Any]
          let group = (args?["groupName"] as? String ?? "")
          let name = (args?["name"] as? String ?? args?["proxyName"] as? String ?? "")
          if group.isEmpty || name.isEmpty {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "groupName/proxyName required", details: nil))
            return
          }
          self.sendProviderCommand(["action": "selectProxy", "groupName": group, "proxyName": name]) { resp in
            result((resp["ok"] as? Bool) ?? false)
          }
      } else if call.method == "getSelectedProxy" {
          let args = call.arguments as? [String: Any]
          let group = (args?["groupName"] as? String ?? "")
          if group.isEmpty {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "groupName required", details: nil))
            return
          }
          self.sendProviderStringMessage("getSelectedProxy|\(group)") { value in
            guard let val = value else {
              result(nil)
              return
            }
            if val == "shared_mem" {
              if let userDefaults = UserDefaults(suiteName: self.appGroupIdentifier),
                 let selected = userDefaults.string(forKey: "vpn_selected_proxy_data") {
                result(selected.trimmingCharacters(in: .whitespacesAndNewlines))
              } else {
                result(nil)
              }
            } else {
              result(val.trimmingCharacters(in: .whitespacesAndNewlines))
            }
          }
      } else if call.method == "reloadConfig" {
          self.sendProviderCommand(["action": "reloadConfig"]) { resp in
            result((resp["ok"] as? Bool) ?? false)
          }
      } else {
          result(FlutterMethodNotImplemented)
      }
    })
  }

  private func isDebuggerAttached() -> Bool {
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var infoSize = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&name, u_int(name.count), &info, &infoSize, nil, 0)
    if result != 0 {
      return false
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0
  }

  private func primeTunnelManagerCache() {
    loadTunnelManager(forceRefresh: true) { _, _ in }
  }

  private func markPostStartStatusDelay() {
    deferStatusQueriesUntil = Date().addingTimeInterval(postStartStatusQueryDelay)
  }

  private func performAfterPostStartDelayIfNeeded(
    method: String,
    execute: @escaping () -> Void
  ) {
    guard
      let until = deferStatusQueriesUntil,
      until.timeIntervalSinceNow > 0,
      method == "getMode" || method == "getProxies" || method == "getSelectedProxy"
    else {
      execute()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow) {
      execute()
    }
  }

  private func completeTunnelManagerLoad(
    manager: NETunnelProviderManager?,
    error: Error?
  ) {
    let completions = pendingTunnelManagerCompletions
    pendingTunnelManagerCompletions.removeAll()
    for completion in completions {
      completion(manager, error)
    }
  }

  private func sendProviderStringMessage(_ message: String, completion: @escaping (String?) -> Void) {
    let method: String
    if let separator = message.firstIndex(of: "|") {
      method = String(message[..<separator])
    } else {
      method = message
    }
    performAfterPostStartDelayIfNeeded(method: method) {
      self.loadTunnelManager(forceRefresh: true) { manager, _ in
        let status = manager?.connection.status ?? .invalid
        guard
          let session = manager?.connection as? NETunnelProviderSession,
          status == .connected || status == .reasserting,
          let data = message.data(using: .utf8)
        else {
          completion(nil)
          return
        }
        do {
          try session.sendProviderMessage(data) { responseData in
            guard
              let responseData = responseData,
              let value = String(data: responseData, encoding: .utf8)
            else {
              completion(nil)
              return
            }
            completion(value)
          }
        } catch {
          completion(nil)
        }
      }
    }
  }

  private func loadTunnelManager(
    forceRefresh: Bool = false,
    completion: @escaping (NETunnelProviderManager?, Error?) -> Void
  ) {
    if !forceRefresh, let cachedTunnelManager {
      completion(cachedTunnelManager, nil)
      return
    }
    pendingTunnelManagerCompletions.append(completion)
    if isLoadingTunnelManager {
      return
    }
    isLoadingTunnelManager = true
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      self.isLoadingTunnelManager = false
      if let error = error {
        self.completeTunnelManagerLoad(manager: nil, error: error)
        return
      }
      let matched = managers?.first(where: { manager in
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
          if proto.providerBundleIdentifier == self.tunnelBundleIdentifier {
            return true
          }
        }
        return manager.localizedDescription == self.tunnelDescription
      })
      let manager = matched ?? NETunnelProviderManager()
      self.cachedTunnelManager = manager
      self.completeTunnelManagerLoad(manager: manager, error: nil)
    }
  }

  private func startTunnel(configContent: String, completion: @escaping (Error?) -> Void) {
    startTunnel(configContent: configContent, attempt: 1, completion: completion)
  }

  private func startTunnel(
    configContent: String,
    attempt: Int,
    completion: @escaping (Error?) -> Void
  ) {
    loadTunnelManager(forceRefresh: attempt > 1) { manager, error in
      if let error = error {
        completion(error)
        return
      }
      guard let manager = manager else {
        completion(NSError(domain: "Tunnel", code: -1))
        return
      }

      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = self.tunnelBundleIdentifier
      proto.serverAddress = "CarbonLAM"
      proto.disconnectOnSleep = false
      proto.providerConfiguration = [
        "appGroup": self.appGroupIdentifier
      ]
      
      if let userDefaults = UserDefaults(suiteName: self.appGroupIdentifier) {
        userDefaults.set(configContent, forKey: "vpn_config_content")
        userDefaults.synchronize()
      }
      
      manager.localizedDescription = self.tunnelDescription
      manager.protocolConfiguration = proto
      manager.isEnabled = true

      manager.saveToPreferences { saveError in
        if let saveError = saveError {
          completion(self.wrapError(stage: "saveToPreferences", error: saveError))
          return
        }
        manager.loadFromPreferences { loadError in
          if let loadError = loadError {
            completion(self.wrapError(stage: "loadFromPreferences", error: loadError))
            return
          }
          self.cachedTunnelManager = manager
          let status = manager.connection.status
          if status == .connected || status == .reasserting {
            self.markPostStartStatusDelay()
            completion(nil)
            return
          }
          if status == .connecting || status == .disconnecting {
            // It is in a transition state. Stop it first, then wait for it to become inactive.
            (manager.connection as? NETunnelProviderSession)?.stopVPNTunnel()
            self.waitTunnelStopped(manager: manager, retries: 24) { stopped in
              if !stopped {
                self.completeTunnelStart(
                  manager: manager,
                  configContent: configContent,
                  attempt: attempt,
                  error: NSError(
                    domain: "Tunnel",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "tunnel not ready for start: stuck in transition"]
                  ),
                  completion: completion
                )
                return
              }
              // Now it's stopped, try starting it
              do {
                guard let session = manager.connection as? NETunnelProviderSession else {
                  completion(NSError(domain: "Tunnel", code: -3, userInfo: [NSLocalizedDescriptionKey: "invalid tunnel session"]))
                  return
                }
                try session.startVPNTunnel()
                self.waitTunnelConnected(manager: manager, retries: 8) { error in
                  self.completeTunnelStart(
                    manager: manager,
                    configContent: configContent,
                    attempt: attempt,
                    error: error,
                    completion: completion
                  )
                }
              } catch {
                self.completeTunnelStart(
                  manager: manager,
                  configContent: configContent,
                  attempt: attempt,
                  error: self.wrapError(stage: "startVPNTunnel", error: error),
                  completion: completion
                )
              }
            }
            return
          }
          do {
            guard let session = manager.connection as? NETunnelProviderSession else {
              completion(NSError(domain: "Tunnel", code: -3, userInfo: [NSLocalizedDescriptionKey: "invalid tunnel session"]))
              return
            }
            try session.startVPNTunnel()
            self.waitTunnelConnected(manager: manager, retries: 8) { error in
              self.completeTunnelStart(
                manager: manager,
                configContent: configContent,
                attempt: attempt,
                error: error,
                completion: completion
              )
            }
          } catch {
            self.completeTunnelStart(
              manager: manager,
              configContent: configContent,
              attempt: attempt,
              error: self.wrapError(stage: "startVPNTunnel", error: error),
              completion: completion
            )
          }
        }
      }
    }
  }

  private func waitTunnelReadyForStart(
    manager: NETunnelProviderManager,
    retries: Int,
    completion: @escaping (NETunnelProviderManager, NEVPNStatus) -> Void
  ) {
    loadTunnelManager(forceRefresh: true) { refreshedManager, _ in
      let activeManager = refreshedManager ?? manager
      let status = activeManager.connection.status
      self.cachedTunnelManager = activeManager
      // Only return if it is no longer connecting or disconnecting.
      if status != .connecting && status != .disconnecting {
        completion(activeManager, status)
        return
      }
      if retries <= 0 {
        completion(activeManager, status)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.waitTunnelReadyForStart(
          manager: activeManager,
          retries: retries - 1,
          completion: completion
        )
      }
    }
  }

  private func completeTunnelStart(
    manager: NETunnelProviderManager,
    configContent: String,
    attempt: Int,
    error: Error?,
    completion: @escaping (Error?) -> Void
  ) {
    guard let error else {
      completion(nil)
      return
    }
    enrichTunnelStartError(manager: manager, error: error) { resolvedError in
      guard
        self.shouldRetryTunnelStart(error: resolvedError, attempt: attempt)
      else {
        completion(resolvedError)
        return
      }
      (manager.connection as? NETunnelProviderSession)?.stopVPNTunnel()
      DispatchQueue.main.asyncAfter(deadline: .now() + self.tunnelStartRetryDelay) {
        self.startTunnel(configContent: configContent, attempt: attempt + 1, completion: completion)
      }
    }
  }

  private func waitTunnelConnected(manager: NETunnelProviderManager, retries: Int, completion: @escaping (Error?) -> Void) {
    loadTunnelManager(forceRefresh: true) { refreshedManager, _ in
      let activeManager = refreshedManager ?? manager
      let status = activeManager.connection.status
      self.cachedTunnelManager = activeManager
      if status == .connected || status == .reasserting {
        self.markPostStartStatusDelay()
        completion(nil)
        return
      }
      if status == .invalid {
        completion(NSError(domain: "Tunnel", code: -4, userInfo: [NSLocalizedDescriptionKey: "tunnel status: \(status.rawValue)"]))
        return
      }
      if retries <= 0 {
        completion(NSError(domain: "Tunnel", code: -5, userInfo: [NSLocalizedDescriptionKey: "tunnel status timeout: \(status.rawValue)"]))
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.waitTunnelConnected(manager: activeManager, retries: retries - 1, completion: completion)
      }
    }
  }

  private func waitTunnelStopped(
    manager: NETunnelProviderManager,
    retries: Int,
    completion: @escaping (Bool) -> Void
  ) {
    loadTunnelManager(forceRefresh: true) { refreshedManager, _ in
      let activeManager = refreshedManager ?? manager
      let status = activeManager.connection.status
      self.cachedTunnelManager = activeManager
      if status == .disconnected || status == .invalid {
        completion(true)
        return
      }
      if retries <= 0 {
        completion(false)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.waitTunnelStopped(manager: activeManager, retries: retries - 1, completion: completion)
      }
    }
  }

  private func shouldRetryTunnelStart(error: Error, attempt: Int) -> Bool {
    guard attempt < tunnelStartMaxAttempts else {
      return false
    }
    let nsError = error as NSError
    if nsError.domain == "Tunnel" && (nsError.code == -4 || nsError.code == -5) {
      return true
    }
    if nsError.domain == "NEVPNConnectionErrorDomain" {
      return true
    }
    return false
  }

  private func enrichTunnelStartError(
    manager: NETunnelProviderManager,
    error: Error,
    completion: @escaping (NSError) -> Void
  ) {
    let nsError = error as NSError
    let statusText = tunnelStatusDescription(manager.connection.status)
    if #available(iOS 16.0, *) {
      manager.connection.fetchLastDisconnectError { lastError in
        if let lastError {
          let disconnectError = lastError as NSError
          completion(
            NSError(
              domain: nsError.domain,
              code: nsError.code,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "\(nsError.localizedDescription); status: \(statusText); disconnect: [\(disconnectError.domain):\(disconnectError.code)] \(disconnectError.localizedDescription)"
              ]
            )
          )
        } else {
          completion(
            NSError(
              domain: nsError.domain,
              code: nsError.code,
              userInfo: [NSLocalizedDescriptionKey: "\(nsError.localizedDescription); status: \(statusText)"]
            )
          )
        }
      }
      return
    }
    completion(
      NSError(
        domain: nsError.domain,
        code: nsError.code,
        userInfo: [NSLocalizedDescriptionKey: "\(nsError.localizedDescription); status: \(statusText)"]
      )
    )
  }

  private func tunnelStatusDescription(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
      return "invalid(0)"
    case .disconnected:
      return "disconnected(1)"
    case .connecting:
      return "connecting(2)"
    case .connected:
      return "connected(3)"
    case .reasserting:
      return "reasserting(4)"
    case .disconnecting:
      return "disconnecting(5)"
    @unknown default:
      return "unknown(\(status.rawValue))"
    }
  }

  private func describeError(_ error: Error) -> String {
    let nsError = error as NSError
    return "[\(nsError.domain):\(nsError.code)] \(nsError.localizedDescription)"
  }

  private func wrapError(stage: String, error: Error) -> NSError {
    let nsError = error as NSError
    return NSError(
      domain: nsError.domain,
      code: nsError.code,
      userInfo: [NSLocalizedDescriptionKey: "\(stage) failed: \(nsError.localizedDescription)"]
    )
  }

  private func requestTunnelPermission(completion: @escaping (Error?) -> Void) {
    loadTunnelManager { manager, error in
      if let error = error {
        completion(error)
        return
      }
      guard let manager = manager else {
        completion(NSError(domain: "Tunnel", code: -1))
        return
      }
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = self.tunnelBundleIdentifier
      proto.serverAddress = "CarbonLAM"
      proto.disconnectOnSleep = false
      proto.providerConfiguration = [
        "appGroup": self.appGroupIdentifier
      ]
      manager.localizedDescription = self.tunnelDescription
      manager.protocolConfiguration = proto
      manager.isEnabled = true
      manager.saveToPreferences { saveError in
        if let saveError = saveError {
          completion(self.wrapError(stage: "permission.saveToPreferences", error: saveError))
          return
        }
        manager.loadFromPreferences { loadError in
          if let loadError = loadError {
            completion(self.wrapError(stage: "permission.loadFromPreferences", error: loadError))
          } else {
            self.cachedTunnelManager = manager
            self.waitTunnelReadyForStart(manager: manager, retries: 24) {
              _, _ in
              completion(nil)
            }
          }
        }
      }
    }
  }

  private func stopTunnel(completion: @escaping () -> Void) {
    loadTunnelManager { manager, _ in
      (manager?.connection as? NETunnelProviderSession)?.stopVPNTunnel()
      completion()
    }
  }

  private func sendProviderCommand(_ command: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    loadTunnelManager { manager, _ in
      guard
        let session = manager?.connection as? NETunnelProviderSession,
        let data = try? JSONSerialization.data(withJSONObject: command)
      else {
        completion([:])
        return
      }
      do {
        try session.sendProviderMessage(data) { responseData in
          guard
            let responseData = responseData,
            let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
          else {
            completion([:])
            return
          }
          completion(object)
        }
      } catch {
        completion([:])
      }
    }
  }

  private func xorDecode(_ enc: [UInt8], key: UInt8 = 0x5A) -> String {
    let decoded = enc.map { $0 ^ key }
    return String(bytes: decoded, encoding: .utf8) ?? ""
  }

  private func nativeAesKey() -> String {
    return xorDecode([
      0x62, 0x63, 0x1b, 0x6d, 0x18, 0x6c, 0x19, 0x6f, 0x1e, 0x6e, 0x1f, 0x69, 0x1c, 0x68, 0x6a, 0x6b,
      0x63, 0x62, 0x6d, 0x6c, 0x6f, 0x6e, 0x69, 0x68, 0x6b, 0x6a, 0x1b, 0x18, 0x19, 0x1e, 0x1f, 0x1c,
      0x6b, 0x68, 0x69, 0x6e, 0x6f, 0x6c, 0x68, 0x62, 0x63, 0x6a, 0x1b, 0x18, 0x19, 0x1e, 0x1f, 0x1c,
      0x62, 0x63, 0x1b, 0x6d, 0x18, 0x6c, 0x19, 0x6f, 0x1e, 0x6e, 0x1f, 0x69, 0x1c, 0x68, 0x6a, 0x6b
    ])
  }

  private func nativeObfuscateKey() -> String {
    return xorDecode([
      0x6d, 0x17, 0x62, 0x14, 0x63, 0x18, 0x62, 0x0c, 0x6d, 0x19, 0x63, 0x02, 0x62, 0x00, 0x6d, 0x1b,
      0x63, 0x09, 0x62, 0x1e, 0x6d, 0x1c, 0x63, 0x1d, 0x62, 0x12, 0x6d, 0x10, 0x63, 0x11, 0x62, 0x16,
      0x6d, 0x0a, 0x63, 0x15, 0x62, 0x13, 0x6d, 0x0f, 0x63, 0x03, 0x62, 0x0d, 0x6d, 0x0e, 0x63, 0x08,
      0x62, 0x0a, 0x6d, 0x17, 0x63, 0x14, 0x62, 0x18, 0x6d, 0x0c, 0x63, 0x19, 0x62, 0x02, 0x6d, 0x00,
      0x63, 0x1b, 0x62, 0x09, 0x6d, 0x1e, 0x63, 0x1c, 0x62, 0x1d, 0x6d, 0x12, 0x63, 0x10, 0x62, 0x11,
      0x6d, 0x16, 0x6c, 0x0a
    ])
  }

  private func nativeServerUrlKey() -> String {
    return xorDecode([
      0x32, 0x2e, 0x2e, 0x2a, 0x29, 0x60, 0x75, 0x75, 0x2c, 0x2a, 0x34, 0x3b, 0x2a, 0x33, 0x29, 0x74,
      0x39, 0x35, 0x37
    ])
  }
}
