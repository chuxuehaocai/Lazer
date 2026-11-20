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

/// Rebuilds the material from the wallpaper that is set right now.
///
/// DWM samples the desktop wallpaper when the material is installed and keeps
/// that sample. A window that is already open therefore keeps the picture it
/// started with, so a listener who switched wallpapers sees no change: the
/// material is still composited from the old one. Dropping the backdrop to none
/// and installing it again is what makes DWM take a fresh sample, which is the
/// same order the Personalization page goes through.
inline bool RefreshMaterial(HWND window, const DwmApi& api = {}) {
  if (!IsWindow(window) ||
      (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
    return false;
  }
  // Hand the client area back to DWM without a material, then install it once
  // more: the second install is the one that samples the wallpaper again.
  const MARGINS bare{0, 0, 1, 0};
  api.set_attribute(window, kSystemBackdropType, &kBackdropNone,
                    sizeof(kBackdropNone));
  api.extend_frame(window, &bare);

  const BOOL use_dark = TRUE;
  api.set_attribute(window, kImmersiveDarkMode, &use_dark, sizeof(use_dark));
  const DWMNCRENDERINGPOLICY policy = DWMNCRP_ENABLED;
  const MARGINS glass{-1, -1, -1, -1};
  api.set_attribute(window, DWMWA_NCRENDERING_POLICY, &policy, sizeof(policy));
  api.extend_frame(window, &glass);
  const int mica = kBackdropMica;
  return SUCCEEDED(api.set_attribute(window, kSystemBackdropType, &mica,
                                     sizeof(mica)));
}

}  // namespace window_backdrop

#endif  // RUNNER_WINDOW_BACKDROP_NATIVE_H_
