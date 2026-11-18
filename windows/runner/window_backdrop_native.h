#ifndef RUNNER_WINDOW_BACKDROP_NATIVE_H_
#define RUNNER_WINDOW_BACKDROP_NATIVE_H_

#include <windows.h>
#include <dwmapi.h>

namespace window_backdrop {

// Numeric values keep older build SDKs usable. Unsupported Windows releases
// reject SYSTEMBACKDROP_TYPE, and the Flutter surface stays opaque.
constexpr DWORD kSystemBackdropType = 38;
constexpr DWORD kImmersiveDarkMode = 20;
constexpr int kBackdropNone = 1;
constexpr int kBackdropMica = 2;

struct DwmApi {
  decltype(&DwmSetWindowAttribute) set_attribute = DwmSetWindowAttribute;
  decltype(&DwmExtendFrameIntoClientArea) extend_frame =
      DwmExtendFrameIntoClientArea;
};

inline bool ApplyMica(HWND window, bool enabled, bool dark,
                      const DwmApi& api = {}) {
  if (!IsWindow(window) ||
      (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
    return false;
  }

  const auto restore_frame = [&]() {
    api.set_attribute(window, kSystemBackdropType, &kBackdropNone,
                      sizeof(kBackdropNone));
    // Preserve the frameless window's shadow when Mica is off or unsupported.
    const MARGINS shadow{0, 0, 1, 0};
    api.extend_frame(window, &shadow);
  };
  const BOOL use_dark = dark ? TRUE : FALSE;
  api.set_attribute(window, kImmersiveDarkMode, &use_dark, sizeof(use_dark));
  if (!enabled) {
    restore_frame();
    return false;
  }

  // DWM must own the full client area before installing its system backdrop.
  // Do not call window_manager.setBackgroundColor: that installs a legacy
  // ACCENT_ENABLE_(TRANSPARENT)GRADIENT policy over the system Mica material.
  const DWMNCRENDERINGPOLICY policy = DWMNCRP_ENABLED;
  const MARGINS glass{-1, -1, -1, -1};
  if (FAILED(api.set_attribute(window, DWMWA_NCRENDERING_POLICY, &policy,
                               sizeof(policy))) ||
      FAILED(api.extend_frame(window, &glass)) ||
      FAILED(api.set_attribute(window, kSystemBackdropType, &kBackdropMica,
                               sizeof(kBackdropMica)))) {
    restore_frame();
    return false;
  }
  return true;
}

}  // namespace window_backdrop

#endif  // RUNNER_WINDOW_BACKDROP_NATIVE_H_
