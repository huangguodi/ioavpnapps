import Flutter
import UIKit
import Darwin

@_silgen_name("MobileStart") private func MobileStart(_ home: NSString?, _ configFileName: NSString?)
@_silgen_name("MobileStop") private func MobileStop()
@_silgen_name("MobileSetMode") private func MobileSetMode(_ mode: NSString?)
@_silgen_name("MobileGetMode") private func MobileGetMode() -> NSString
@_silgen_name("MobileGetProxies") private func MobileGetProxies() -> NSString
@_silgen_name("MobileSelectProxy") private func MobileSelectProxy(_ groupName: NSString?, _ proxyName: NSString?) -> Bool
@_silgen_name("MobileTestLatency") private func MobileTestLatency(_ proxyName: NSString?) -> NSString
@_silgen_name("MobileForceUpdateConfig") private func MobileForceUpdateConfig(_ configFileName: NSString?)

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var coreRunning = false
  private let defaultServerUrlKey = "https://vpnapis.com"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.accelerator.tg/mihomo",
                                              binaryMessenger: controller.binaryMessenger)
    let securityChannel = FlutterMethodChannel(name: "com.accelerator.tg/security",
                                               binaryMessenger: controller.binaryMessenger)
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
      } else if call.method == "getAesKey" {
          result(self.stringConfigValue(keys: ["APP_AES_KEY", "AES_KEY"], defaultValue: ""))
      } else if call.method == "getObfuscateKey" {
          result(self.stringConfigValue(keys: ["APP_OBFUSCATE_KEY", "OBFUSCATE_KEY"], defaultValue: ""))
      } else if call.method == "getServerUrlKey" {
          result(self.stringConfigValue(keys: ["APP_SERVER_URL", "SERVER_URL_KEY"], defaultValue: self.defaultServerUrlKey))
      } else if call.method == "startMihomo" || call.method == "start" {
          guard let args = call.arguments as? [String: Any],
                let configPath = args["configPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "configPath is required", details: nil))
            return
          }
          let url = URL(fileURLWithPath: configPath)
          let home = url.deletingLastPathComponent().path as NSString
          let configName = url.lastPathComponent as NSString
          MobileStart(home, configName)
          self.coreRunning = true
          result(nil)
      } else if call.method == "stopMihomo" || call.method == "stop" {
          MobileStop()
          self.coreRunning = false
          result(nil)
      } else if call.method == "isRunning" || call.method == "isMihomoRunning" {
          result(self.coreRunning)
      } else if call.method == "changeMode" || call.method == "setModeNative" {
          let args = call.arguments as? [String: Any]
          let mode = (args?["mode"] as? String ?? "rule") as NSString
          MobileSetMode(mode)
          result(true)
      } else if call.method == "getMode" || call.method == "getModeNative" {
          result(MobileGetMode() as String)
      } else if call.method == "getProxies" {
          result(MobileGetProxies() as String)
      } else if call.method == "urlTest" {
          let args = call.arguments as? [String: Any]
          let name = (args?["name"] as? String ?? "GLOBAL") as NSString
          result(MobileTestLatency(name) as String)
      } else if call.method == "selectProxy" {
          let args = call.arguments as? [String: Any]
          let name = (args?["name"] as? String ?? args?["proxyName"] as? String ?? "")
          if name.isEmpty {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "proxy name is required", details: nil))
            return
          }
          result(MobileSelectProxy("GLOBAL", name as NSString))
      } else if call.method == "selectProxyByGroup" {
          let args = call.arguments as? [String: Any]
          let group = (args?["groupName"] as? String ?? "")
          let name = (args?["name"] as? String ?? args?["proxyName"] as? String ?? "")
          if group.isEmpty || name.isEmpty {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "groupName/proxyName required", details: nil))
            return
          }
          result(MobileSelectProxy(group as NSString, name as NSString))
      } else if call.method == "getSelectedProxy" {
          let args = call.arguments as? [String: Any]
          let group = (args?["groupName"] as? String ?? "")
          if group.isEmpty {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "groupName required", details: nil))
            return
          }
          result(self.extractSelectedProxy(groupName: group, proxiesJson: MobileGetProxies() as String))
      } else if call.method == "reloadConfig" {
          MobileForceUpdateConfig("config.yaml")
          result(true)
      } else {
          result(FlutterMethodNotImplemented)
      }
    })

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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

  private func stringConfigValue(keys: [String], defaultValue: String) -> String {
    for key in keys {
      if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }
    return defaultValue
  }
}
