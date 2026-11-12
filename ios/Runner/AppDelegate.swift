import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hapticsChannel: FlutterMethodChannel?
  private var updatesChannel: FlutterMethodChannel?
  private var systemWidgetsChannel: FlutterMethodChannel?
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
    widgets.setMethodCallHandler { call, result in
      guard call.method == "updatePlayCount" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      let count = max(0, (args["count"] as? NSNumber)?.intValue ?? 0)
      UserDefaults(suiteName: "group.dev.naominet.lazer")?.set(count, forKey: "play_count")
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    }
  }
}
