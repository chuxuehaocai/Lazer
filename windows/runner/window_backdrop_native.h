#ifndef RUNNER_WINDOW_BACKDROP_NATIVE_H_
#define RUNNER_WINDOW_BACKDROP_NATIVE_H_

#include <windows.h>
#include <dwmapi.h>

namespace window_backdrop {

// Numeric values keep older build SDKs usable. Unsupported Windows releases
// reject SYSTEMBACKDROP_TYPE, and the Flutter surface stays opaque.
constexpr DWORD kSystemBackdropType = 38;
constexpr DWORD kImmersiveDarkMode = 20;
// Windows 11 exposed Mica through this older attribute before
// DWMWA_SYSTEMBACKDROP_TYPE was documented. Some supported builds accept the
// legacy attribute while returning E_INVALIDARG for the newer one.
constexpr DWORD kLegacyMicaEffect = 1029;
constexpr int kBackdropNone = 1;
constexpr int kBackdropMica = 2;

struct DwmApi {
  decltype(&DwmSetWindowAttribute) set_attribute = DwmSetWindowAttribute;
  decltype(&DwmExtendFrameIntoClientArea) extend_frame =
      DwmExtendFrameIntoClientArea;
};

inline void ClearMica(HWND window, const DwmApi& api) {
  api.set_attribute(window, kSystemBackdropType, &kBackdropNone,
                    sizeof(kBackdropNone));
  const BOOL legacy = FALSE;
  api.set_attribute(window, kLegacyMicaEffect, &legacy, sizeof(legacy));
}

inline bool SetMica(HWND window, const DwmApi& api) {
  const HRESULT modern = api.set_attribute(
      window, kSystemBackdropType, &kBackdropMica, sizeof(kBackdropMica));
  if (SUCCEEDED(modern)) return true;
  const BOOL legacy = TRUE;
  const HRESULT old = api.set_attribute(
      window, kLegacyMicaEffect, &legacy, sizeof(legacy));
  return SUCCEEDED(old);
}

// The runner creates the window with WS_OVERLAPPEDWINDOW, so it carries a real
// caption bar. That only becomes visible once DWM owns the whole client area:
// with a system backdrop installed, DWM paints its own title bar into the
// surface, and its minimize/maximize/close cluster lands on top of the capsule
// this app draws itself. Windows shows two sets of window buttons.
//
// Dropping WS_CAPTION keeps the resize frame (WS_THICKFRAME) and the taskbar
// behaviour, and leaves the title bar entirely to Flutter, which is what both
// title-bar styles already assume.
constexpr LONG_PTR kCaptionStyle = WS_CAPTION;

inline void DetachCaption(HWND window, bool attach) {
  LONG_PTR style = GetWindowLongPtrW(window, GWL_STYLE);
  const LONG_PTR next = attach ? (style | kCaptionStyle)
                               : (style & ~kCaptionStyle);
  if (next == style) return;
  SetWindowLongPtrW(window, GWL_STYLE, next);
  // A style change only takes effect on the next frame calculation.
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
}

inline bool ApplyMica(HWND window, bool enabled, bool dark,
                      const DwmApi& api = {}) {
  if (!IsWindow(window) ||
      (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
    return false;
  }

  const auto restore_frame = [&]() {
    ClearMica(window, api);
    // Preserve the frameless window's shadow when Mica is off or unsupported.
    const MARGINS shadow{0, 0, 1, 0};
    api.extend_frame(window, &shadow);
    // Without a material DWM paints nothing into the client area, so the
    // caption bar is invisible again and may come back for the system menu.
    DetachCaption(window, true);
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
  // Apply the frameless style before DWM takes ownership of the client area.
  // Recalculating the frame after installing a backdrop can discard the
  // material on some Windows 11 builds.
  DetachCaption(window, false);
  // Non-client rendering is best effort on a frameless window. A few Windows
  // builds reject that attribute even though they still support the backdrop.
  api.set_attribute(window, DWMWA_NCRENDERING_POLICY, &policy,
                    sizeof(policy));
  if (FAILED(api.extend_frame(window, &glass)) || !SetMica(window, api)) {
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
inline bool RefreshMaterial(HWND window, bool dark,
                            const DwmApi& api = {}) {
  if (!IsWindow(window) ||
      (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
    return false;
  }
  // Hand the client area back to DWM without a material, then install it once
  // more: the second install is the one that samples the wallpaper again.
  const MARGINS bare{0, 0, 1, 0};
  ClearMica(window, api);
  api.extend_frame(window, &bare);

  const BOOL use_dark = dark ? TRUE : FALSE;
  api.set_attribute(window, kImmersiveDarkMode, &use_dark, sizeof(use_dark));
  const DWMNCRENDERINGPOLICY policy = DWMNCRP_ENABLED;
  const MARGINS glass{-1, -1, -1, -1};
  api.set_attribute(window, DWMWA_NCRENDERING_POLICY, &policy, sizeof(policy));
  api.extend_frame(window, &glass);
  return SetMica(window, api);
}

}  // namespace window_backdrop

#endif  // RUNNER_WINDOW_BACKDROP_NATIVE_H_
