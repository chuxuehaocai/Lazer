import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hapticsChannel: FlutterMethodChannel?
  private var updatesChannel: FlutterMethodChannel?
  private var systemWidgetsChannel: FlutterMethodChannel?
  private let widgetStorageQueue = DispatchQueue(label: "dev.naominet.lazer.widget-storage", qos: .utility)
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LazerHaptics") else { return }
    let channel = FlutterMethodChannel(name: "dev.naominet.lazer/haptics", binaryMessenger: registrar.messenger())
    hapticsChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "impact" else { result(FlutterMethodNotImplemented); return }
      let args = call.arguments as? [String: Any] ?? [:]
      let intensity = max(0, min(1, (args["intensity"] as? NSNumber)?.doubleValue ?? 0.5))
      let kind = args["kind"] as? String ?? "tap"
      if intensity > 0 {
        // UIKit feedback generators are short-lived: build one per impact and
        // prime it right before firing. A generator kept for the life of the
        // app goes inert once iOS stops the haptic engine — a background trip
        // or an audio-session change is enough — and `impactOccurred` then
        // returns silently, without feedback and without an error, so the Dart
        // fallback never runs. Flutter's own HapticFeedback creates a
        // generator per call for the same reason.
        let style: UIImpactFeedbackGenerator.FeedbackStyle =
          kind == "boundary" ? .medium : kind == "detent" ? .rigid : .light
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: CGFloat(intensity))
      }
      result(nil)
    }

    // Release pages open in Safari; the app has no `url_launcher` dependency
    // and only needs this one call.
    guard let updatesRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "LazerUpdates") else { return }
    let updates = FlutterMethodChannel(
      name: "dev.naominet.lazer/updates",
      binaryMessenger: updatesRegistrar.messenger()
    )
    updatesChannel = updates
    updates.setMethodCallHandler { call, result in
      guard call.method == "openUrl" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      guard let raw = args["url"] as? String,
            let url = URL(string: raw),
            url.scheme == "https" || url.scheme == "http" else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }

    guard let widgetsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "LazerSystemWidgets") else { return }
    let widgets = FlutterMethodChannel(
      name: "dev.naominet.lazer/system_widgets",
      binaryMessenger: widgetsRegistrar.messenger()
    )
    systemWidgetsChannel = widgets
    widgets.setMethodCallHandler { [weak self] call, result in
      guard call.method == "updateRecentPlayback" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      guard let self = self else { result(nil); return }
      self.widgetStorageQueue.async {
        do {
          let changed = try Self.storeRecentPlayback(args)
          DispatchQueue.main.async {
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: "LazerPlayCountWidget") }
            result(nil)
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "widget_update_failed", message: "Unable to update the recent playback widget.", details: nil))
          }
        }
      }
    }
  }

  private nonisolated static func storeRecentPlayback(_ args: [String: Any]) throws -> Bool {
    let files = FileManager.default
    guard let container = files.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.naominet.lazer") else {
      // The widget can only read this container. Without the App Groups entitlement
      // (an unsigned or re-signed sideload build) every update lands nowhere and the
      // widget stays empty, so say so instead of failing silently.
      NSLog("[LazerWidget] app group %@ unavailable; snapshot not written", "group.dev.naominet.lazer")
      throw NSError(domain: "LazerWidget", code: 1)
    }
    let snapshotURL = container.appendingPathComponent("recent-playback.json")
    let previousData = try? Data(contentsOf: snapshotURL)
    let previous: [String: Any]? = previousData.flatMap { data in
      (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    let previousArtwork = previous?["artworkFile"] as? String ?? ""
    let hasTrack = args["hasTrack"] as? Bool ?? false
    var artworkFile = ""
    if hasTrack, let typed = args["artwork"] as? FlutterStandardTypedData {
      let data = typed.data
      // Flutter already downsamples to 256 px; keep the extension bounded too.
      if !data.isEmpty, data.count <= 1_048_576,
         let image = UIImage(data: data), let pixels = image.cgImage,
         pixels.width <= 256, pixels.height <= 256, let png = image.pngData() {
        let oldURL = container.appendingPathComponent(previousArtwork)
        if previousArtwork.hasPrefix("recent-playback-artwork-"),
           previousArtwork.hasSuffix(".png"),
           !previousArtwork.contains("/"), !previousArtwork.contains("\\"),
           (try? Data(contentsOf: oldURL)) == png {
          artworkFile = previousArtwork
        } else {
          artworkFile = "recent-playback-artwork-\(UUID().uuidString).png"
          try png.write(to: container.appendingPathComponent(artworkFile), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
      }
    }
    func text(_ name: String) -> String { String((args[name] as? String ?? "").prefix(512)) }
    let requestedLanguage = text("language")
    let language = ["en", "ja", "zh-Hans", "zh-Hant", "system"].contains(requestedLanguage) ? requestedLanguage : "system"
    let snapshot: [String: Any] = [
      "title": hasTrack ? text("title") : "",
      "artist": hasTrack ? text("artist") : "",
      "album": hasTrack ? text("album") : "",
      "trackId": hasTrack ? text("trackId") : "",
      "playing": hasTrack && (args["playing"] as? Bool ?? false),
      "hasTrack": hasTrack,
      "language": language,
      "artworkFile": artworkFile,
    ]
    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    // Publish metadata last so a new track cannot show the previous cover.
    let changed = previousData != data
    if changed {
      try data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      NSLog("[LazerWidget] stored snapshot (%d bytes, track=%@)", data.count, snapshot["trackId"] as? String ?? "")
    }
    // Keep the prior cover for an extension reader using the previous snapshot.
    // The next update removes it; at most two small covers remain.
    let keep = hasTrack ? Set([artworkFile, previousArtwork]) : Set<String>()
    for url in (try? files.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)) ?? [] {
      let name = url.lastPathComponent
      if name.hasPrefix("recent-playback-artwork-"), name.hasSuffix(".png"), !keep.contains(name) {
        try? files.removeItem(at: url)
      }
    }
    return changed
  }
}
