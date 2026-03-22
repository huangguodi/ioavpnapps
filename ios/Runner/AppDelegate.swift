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

  init(fetch: @escaping (@escaping ([String: Any]) -> Void) -> Void) {
    self.fetch = fetch
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.fetch { data in
        guard let sink = self.sink else { return }
        DispatchQueue.main.async {
          sink(data)
        }
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    return nil
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let tunnelBundleIdentifier = "app.celery7240.capricorn2328.PacketTunnel"
  private let tunnelDescription = "CarbonLAM Tunnel"
  private let appGroupIdentifier = "group.25632c4e368be58f.1"
  private var trafficStreamHandler: TunnelTrafficStreamHandler?
  private var channelsConfigured = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureChannelsIfNeeded()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func resolveFlutterViewController() -> FlutterViewController? {
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for sceneWindow in windowScene.windows {
        if let controller = sceneWindow.rootViewController as? FlutterViewController {
          return controller
        }
      }
    }
    return nil
  }

  private func configureChannelsIfNeeded() {
    if channelsConfigured {
      return
    }
    guard let controller = resolveFlutterViewController() else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.configureChannelsIfNeeded()
      }
      return
    }
    channelsConfigured = true
    let channel = FlutterMethodChannel(name: "com.accelerator.tg/mihomo",
                                              binaryMessenger: controller.binaryMessenger)
    let trafficChannel = FlutterEventChannel(name: "com.accelerator.tg/mihomo/traffic",
                                             binaryMessenger: controller.binaryMessenger)
    let securityChannel = FlutterMethodChannel(name: "com.accelerator.tg/security",
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
      if call.method == "enableSecureMode" {
        result(true)
      } else if call.method == "isDebuggerAttached" {
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
    channel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "initAssets" {
          result(nil)
      } else if call.method == "requestVpnPermission" {
          self.requestTunnelPermission { error in
            if let error = error {
              result(FlutterError(code: "VPN_PERMISSION_DENIED", message: error.localizedDescription, details: nil))
            } else {
              result(true)
            }
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
              result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
            } else {
              result(nil)
            }
          }
      } else if call.method == "stopMihomo" || call.method == "stop" {
          self.stopTunnel {
            result(nil)
          }
      } else if call.method == "isRunning" || call.method == "isMihomoRunning" {
          self.loadTunnelManager { manager, _ in
            let status = manager?.connection.status ?? .invalid
            result(status == .connected || status == .connecting || status == .reasserting)
          }
      } else if call.method == "changeMode" || call.method == "setModeNative" {
          let args = call.arguments as? [String: Any]
          let mode = (args?["mode"] as? String ?? "rule")
          self.sendProviderCommand(["action": "changeMode", "mode": mode]) { resp in
            result((resp["ok"] as? Bool) ?? false)
          }
      } else if call.method == "getMode" || call.method == "getModeNative" {
          self.sendProviderCommand(["action": "getMode"]) { resp in
            result((resp["value"] as? String) ?? "rule")
          }
      } else if call.method == "getProxies" {
          self.sendProviderCommand(["action": "getProxies"]) { resp in
            result((resp["value"] as? String) ?? "{}")
          }
      } else if call.method == "urlTest" {
          let args = call.arguments as? [String: Any]
          let name = (args?["name"] as? String ?? "GLOBAL")
          self.sendProviderCommand(["action": "urlTest", "name": name]) { resp in
            result((resp["value"] as? String) ?? "")
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
          self.sendProviderCommand(["action": "getProxies"]) { resp in
            let raw = (resp["value"] as? String) ?? "{}"
            result(self.extractSelectedProxy(groupName: group, proxiesJson: raw))
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

  private func extractSelectedProxy(groupName: String, proxiesJson: String) -> String? {
    guard let data = proxiesJson.data(using: .utf8) else { return nil }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let proxies = root["proxies"] as? [String: Any] else { return nil }
    guard let group = proxies[groupName] as? [String: Any] else { return nil }
    return group["now"] as? String
  }

  private func loadTunnelManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error = error {
        completion(nil, error)
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
      if let manager = matched {
        completion(manager, nil)
      } else {
        completion(NETunnelProviderManager(), nil)
      }
    }
  }

  private func startTunnel(configContent: String, completion: @escaping (Error?) -> Void) {
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
      proto.providerConfiguration = [
        "configContent": configContent,
        "appGroup": self.appGroupIdentifier
      ]
      manager.localizedDescription = self.tunnelDescription
      manager.protocolConfiguration = proto
      manager.isEnabled = true

      manager.saveToPreferences { saveError in
        if let saveError = saveError {
          completion(saveError)
          return
        }
        manager.loadFromPreferences { loadError in
          if let loadError = loadError {
            completion(loadError)
            return
          }
          do {
            try (manager.connection as? NETunnelProviderSession)?.startVPNTunnel()
            completion(nil)
          } catch {
            completion(error)
          }
        }
      }
    }
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
      proto.providerConfiguration = [
        "appGroup": self.appGroupIdentifier
      ]
      manager.localizedDescription = self.tunnelDescription
      manager.protocolConfiguration = proto
      manager.isEnabled = true
      manager.saveToPreferences { saveError in
        if let saveError = saveError {
          completion(saveError)
          return
        }
        manager.loadFromPreferences { loadError in
          completion(loadError)
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
