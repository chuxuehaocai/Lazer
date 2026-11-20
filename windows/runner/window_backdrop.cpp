#include "window_backdrop.h"
#include <flutter/standard_method_codec.h>

#include "window_backdrop_native.h"

WindowBackdrop::WindowBackdrop(flutter::BinaryMessenger* messenger, HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "dev.naominet.lazer/window_backdrop",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [window](const auto& call, auto result) {
        if (call.method_name() == "refreshMaterial") {
          // Re-installs the material so DWM rebuilds it from the current
          // desktop wallpaper. DWM samples that wallpaper once and keeps the
          // result; a listener who changed the picture while the window was
          // already open would otherwise keep looking at the old sample, which
          // reads as "Mica ignored my new wallpaper".
          result->Success(flutter::EncodableValue(
              window_backdrop::RefreshMaterial(window)));
          return;
        }
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
        result->Success(flutter::EncodableValue(
            window_backdrop::ApplyMica(window, enabled, flag("dark"))));
      });
}

WindowBackdrop::~WindowBackdrop() {
  channel_->SetMethodCallHandler(nullptr);
}

void WindowBackdrop::HandleWindowMessage(UINT message) {
  switch (message) {
    case WM_DWMCOMPOSITIONCHANGED:
    case WM_DWMCOLORIZATIONCOLORCHANGED:
    case WM_THEMECHANGED:
    case WM_SETTINGCHANGE:
      // DWM can discard frame extensions or change its material policy. Let
      // Dart reapply the current route/theme and update its opaque fallback.
      // The async reply also runs after Win32Window's system-theme handler.
      channel_->InvokeMethod("refresh", nullptr);
      break;
  }
}
