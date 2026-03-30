import Flutter
import UIKit

final class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else {
      return
    }
    if shouldUseHotUpdateBundle() {
      activatePendingHotUpdate()
    }
    let window = UIWindow(windowScene: windowScene)
    let controller: FlutterViewController
    if shouldUseHotUpdateBundle(), let project = hotUpdateProject() {
      controller = FlutterViewController(project: project, nibName: nil, bundle: nil)
    } else {
      controller = FlutterViewController()
    }
    GeneratedPluginRegistrant.register(with: controller)
    window.rootViewController = controller
    self.window = window
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.configureChannelsIfNeeded(with: controller)
    }
    window.makeKeyAndVisible()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  private func hotUpdateRootURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("hot_update", isDirectory: true)
  }

  private func hotUpdateBundleRootURL() -> URL? {
    hotUpdateRootURL()?
      .appendingPathComponent("runtime_bundle", isDirectory: true)
  }

  private func shouldUseHotUpdateBundle() -> Bool {
#if DEBUG
    false
#else
    true
#endif
  }

  private func replaceDirectory(at sourceURL: URL, to targetURL: URL) -> Bool {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      return false
    }
    try? fileManager.removeItem(at: targetURL)
    try? fileManager.createDirectory(
      at: targetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try fileManager.moveItem(at: sourceURL, to: targetURL)
      return true
    } catch {
      do {
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        try? fileManager.removeItem(at: sourceURL)
        return true
      } catch {
        return false
      }
    }
  }

  private func normalizeHotUpdatePermissions(currentURL: URL) {
    let appBinaryURL = currentURL
      .appendingPathComponent("App.framework", isDirectory: true)
      .appendingPathComponent("App", isDirectory: false)
    guard FileManager.default.fileExists(atPath: appBinaryURL.path) else {
      return
    }
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: appBinaryURL.path
    )
  }

  private func migrateLegacyCurrentIfNeeded(bundleRoot: URL, legacyRoot: URL) {
    let currentURL = bundleRoot.appendingPathComponent("current", isDirectory: true)
    let legacyCurrentURL = legacyRoot.appendingPathComponent("current", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: currentURL.path) else {
      return
    }
    if replaceDirectory(at: legacyCurrentURL, to: currentURL) {
      normalizeHotUpdatePermissions(currentURL: currentURL)
    }
  }

  private func activatePendingHotUpdate() {
    guard let bundleRoot = hotUpdateBundleRootURL(),
          let legacyRoot = hotUpdateRootURL() else {
      return
    }
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
    let currentURL = bundleRoot.appendingPathComponent("current", isDirectory: true)
    let pendingCandidates = [
      bundleRoot.appendingPathComponent("pending", isDirectory: true),
      legacyRoot.appendingPathComponent("pending", isDirectory: true),
    ]
    for pendingURL in pendingCandidates {
      if replaceDirectory(at: pendingURL, to: currentURL) {
        normalizeHotUpdatePermissions(currentURL: currentURL)
        return
      }
    }
    migrateLegacyCurrentIfNeeded(bundleRoot: bundleRoot, legacyRoot: legacyRoot)
  }

  private func resolveHotUpdateFrameworkURL() -> URL? {
    guard let bundleRoot = hotUpdateBundleRootURL(),
          let legacyRoot = hotUpdateRootURL() else {
      return nil
    }
    let candidates = [
      bundleRoot.appendingPathComponent("current", isDirectory: true),
      legacyRoot.appendingPathComponent("current", isDirectory: true),
    ]
    for currentURL in candidates {
      let frameworkURL = currentURL.appendingPathComponent("App.framework", isDirectory: true)
      if isValidHotUpdateBundle(currentURL: currentURL),
         FileManager.default.fileExists(atPath: frameworkURL.path) {
        return frameworkURL
      }
    }
    return nil
  }

  private func isValidHotUpdateBundle(currentURL: URL) -> Bool {
    let fileManager = FileManager.default
    let appBinaryURL = currentURL
      .appendingPathComponent("App.framework", isDirectory: true)
      .appendingPathComponent("App", isDirectory: false)
    guard fileManager.fileExists(atPath: appBinaryURL.path) else {
      return false
    }
    let assetsURL = currentURL
      .appendingPathComponent("App.framework", isDirectory: true)
      .appendingPathComponent("flutter_assets", isDirectory: true)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: assetsURL.path, isDirectory: &isDir),
          isDir.boolValue else {
      return false
    }
    let manifestCandidates = [
      assetsURL.appendingPathComponent("AssetManifest.bin", isDirectory: false),
      assetsURL.appendingPathComponent("AssetManifest.json", isDirectory: false),
    ]
    guard manifestCandidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
      return false
    }
    return hasEnoughFlutterAssetsContent(assetsURL: assetsURL)
  }

  private func hasEnoughFlutterAssetsContent(assetsURL: URL, minCount: Int = 1) -> Bool {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
      at: assetsURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return false
    }
    let markerNames: Set<String> = [
      "AssetManifest.bin",
      "AssetManifest.bin.json",
      "AssetManifest.json",
      "FontManifest.json",
      "NativeAssetsManifest.json",
      "NOTICES.Z",
    ]
    var count = 0
    for case let url as URL in enumerator {
      let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
      guard isRegular else {
        continue
      }
      if markerNames.contains(url.lastPathComponent) {
        continue
      }
      count += 1
      if count >= minCount {
        return true
      }
    }
    return false
  }

  private func hotUpdateProject() -> FlutterDartProject? {
    guard let frameworkURL = resolveHotUpdateFrameworkURL(),
          let bundle = Bundle(path: frameworkURL.path) else {
      return nil
    }
    return FlutterDartProject(precompiledDartBundle: bundle)
  }
}
