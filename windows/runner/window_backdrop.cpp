#include "window_backdrop.h"
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

WindowBackdrop::WindowBackdrop(flutter::BinaryMessenger* messenger, HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "dev.naominet.lazer/window_backdrop",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [window](const auto& call, auto result) {
        if (call.method_name() != "setMica") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("arguments", "Expected backdrop options");
          return;
        }
        auto flag = [args](const char* name) {
          auto entry = args->find(flutter::EncodableValue(name));
          return entry != args->end() &&
              std::holds_alternative<bool>(entry->second) &&
              std::get<bool>(entry->second);
        };
        const bool enabled = flag("enabled");
        const BOOL dark = flag("dark");
        // Documented Windows 11 22H2 API. Numeric attributes let the app
        // compile with older SDKs; E_INVALIDARG is an ordinary solid fallback.
        constexpr DWORD kSystemBackdropType = 38;
        constexpr DWORD kImmersiveDarkMode = 20;
        const int backdrop = enabled ? 2 : 1;  // MAINWINDOW / NONE
        DwmSetWindowAttribute(window, kImmersiveDarkMode, &dark, sizeof(dark));
        const HRESULT applied = DwmSetWindowAttribute(
            window, kSystemBackdropType, &backdrop, sizeof(backdrop));
        const bool active = enabled && SUCCEEDED(applied);
        const MARGINS margins = active ? MARGINS{-1, -1, -1, -1}
                                       : MARGINS{0, 0, 1, 0};
        const HRESULT extended = DwmExtendFrameIntoClientArea(window, &margins);
        if (active && FAILED(extended)) {
          const int none = 1;
          DwmSetWindowAttribute(window, kSystemBackdropType, &none, sizeof(none));
        }
        result->Success(flutter::EncodableValue(active && SUCCEEDED(extended)));
      });
}
