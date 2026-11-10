import Cocoa
import FlutterMacOS
import desktop_multi_window
import screen_retriever_macos
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      WindowManagerPlugin.register(
        with: controller.registrar(forPlugin: "WindowManagerPlugin"))
      ScreenRetrieverMacosPlugin.register(
        with: controller.registrar(forPlugin: "ScreenRetrieverMacosPlugin"))
    }

    super.awakeFromNib()
  }
}
