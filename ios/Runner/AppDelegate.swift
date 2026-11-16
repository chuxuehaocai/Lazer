import Flutter
import UIKit
import WidgetKit

/// Why a snapshot update produced no visible widget.
///
/// `updated` and `unchanged` are successes. Everything else names the one failure
/// the user can act on, so the app can show it instead of leaving an empty card
/// with no explanation.
///
/// Declared at file scope rather than inside `AppDelegate`: the delegate is main
/// actor isolated through `FlutterAppDelegate`, and a nested type would inherit
/// that isolation, which the `nonisolated` writer may not name.
enum WidgetWriteStatus: String {
  /// The shared container accepted the snapshot and WidgetKit was asked to reload.
  case updated
  /// The snapshot was already current, so no reload was requested.
  case unchanged
  /// No App Group container: the widget cannot read this app's files at all.
  /// This is what a free-account or re-signed sideload build produces.
  case appGroupUnavailable
  /// The container exists but the snapshot could not be serialised or written.
  case writeFailed
}

/// The widget kind `PlayCountWidget.swift` registers, so a reload asks for the
/// widget that actually exists.
let widgetKind = "LazerPlayCountWidget"
/// The one container the app writes and the extension reads.
let widgetSuite = "group.dev.naominet.lazer"
/// The snapshot the extension decodes.
let widgetSnapshot = "recent-playback.json"
/// Prefix of the cover files the extension reads beside the snapshot.
let widgetArtworkPrefix = "recent-playback-artwork-"

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
      // The channel is the app's only writer for the widget store. Unwrap the weak
      // capture here, where the result can still be answered.
      guard let self = self else {
        result(nil)
        return
      }
      self.widgetStorageQueue.async {
        // The result is a status, not an error: a widget that cannot be written
        // must not interrupt playback, but Dart still has to be able to say why
        // the home screen is empty. A thrown error reached only the log.
        let status = Self.storeRecentPlayback(args)
        DispatchQueue.main.async {
          if status == .updated {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
          }
          result(status.rawValue)
        }
      }
    }
  }

  /// Writes the snapshot the widget extension reads, and says whether it could.
  ///
  /// The shared App Group container is the only place a widget extension may read
  /// this app's files from. A build whose provisioning profile has no App Groups
  /// entitlement - a free-account or re-signed sideload, which is how this IPA is
  /// installed - makes `containerURL` return nil, and the widget then has nothing
  /// to draw no matter how often the app writes. That used to be a thrown error
  /// that only reached NSLog, so the home screen stayed empty with no way to tell
  /// "not entitled" from "nothing played yet".
  private nonisolated static func storeRecentPlayback(_ args: [String: Any]) -> WidgetWriteStatus {
    let files = FileManager.default
    guard let container = files.containerURL(
      forSecurityApplicationGroupIdentifier: widgetSuite
    ) else {
      NSLog(
        "[LazerWidget] app group %@ unavailable; the widget has no shared container to read",
        widgetSuite
      )
      return .appGroupUnavailable
    }
    let snapshotURL = container.appendingPathComponent(widgetSnapshot)
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
        if previousArtwork.hasPrefix(widgetArtworkPrefix),
           previousArtwork.hasSuffix(".png"),
           !previousArtwork.contains("/"), !previousArtwork.contains("\\"),
           (try? Data(contentsOf: oldURL)) == png {
          artworkFile = previousArtwork
        } else {
          artworkFile = "\(widgetArtworkPrefix)\(UUID().uuidString).png"
          let target = container.appendingPathComponent(artworkFile)
          // No file protection: a widget refreshes on the lock screen and after a
          // reboot, and `.completeFileProtectionUntilFirstUserAuthentication`
          // makes the file unreadable until the user unlocks once. The payload is a
          // title, an artist and a cover, so nothing here is worth locking out.
          do {
            try png.write(to: target, options: [.atomic, .noFileProtection])
          } catch {
            NSLog("[LazerWidget] cover write failed: %@", String(describing: error))
            artworkFile = ""
          }
        }
      }
    }
    func text(_ name: String) -> String { String((args[name] as? String ?? "").prefix(512)) }
    let requestedLanguage = text("language")
    let language = ["en", "ja", "zh-Hans", "zh-Hant", "system"].contains(requestedLanguage)
      ? requestedLanguage : "system"
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
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    } catch {
      NSLog("[LazerWidget] snapshot serialisation failed: %@", String(describing: error))
      return .writeFailed
    }
    // Publish metadata last so a new track cannot show the previous cover.
    let changed = previousData != data
    if changed {
      do {
        try data.write(to: snapshotURL, options: [.atomic, .noFileProtection])
      } catch {
        // A full or read-only container is a real failure, not a silent no-op:
        // without this the widget keeps showing an older song forever.
        NSLog("[LazerWidget] snapshot write failed: %@", String(describing: error))
        return .writeFailed
      }
      NSLog(
        "[LazerWidget] stored snapshot (%d bytes, track=%@)",
        data.count,
        snapshot["trackId"] as? String ?? ""
      )
    }
    // Keep the prior cover for an extension reader using the previous snapshot.
    // The next update removes it; at most two small covers remain.
    let keep = hasTrack ? Set([artworkFile, previousArtwork]) : Set<String>()
    for url in (try? files.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)) ?? [] {
      let name = url.lastPathComponent
      if name.hasPrefix(widgetArtworkPrefix), name.hasSuffix(".png"), !keep.contains(name) {
        try? files.removeItem(at: url)
      }
    }
    return changed ? .updated : .unchanged
  }

}
