#ifndef RUNNER_DESKTOP_LYRICS_WINDOW_H_
#define RUNNER_DESKTOP_LYRICS_WINDOW_H_

#include <windows.h>

namespace desktop_lyrics {

// A layered top-level window can pass input to other processes. Keep its
// composition surface stable while only changing mouse passthrough. Flutter's
// child HWND owns the EGL surface and must not become a second layered window.
inline bool SetClickThrough(HWND window, bool transparent = true) {
  if (window == nullptr || !IsWindow(window) ||
      (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
    return false;
  }
  const LONG_PTR previous = GetWindowLongPtrW(window, GWL_EXSTYLE);
  LONG_PTR style = previous | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED;
  if (transparent) {
    style |= WS_EX_TRANSPARENT;
  } else {
    style &= ~WS_EX_TRANSPARENT;
  }
  style &= ~WS_EX_APPWINDOW;
  if (style != previous) {
    SetLastError(ERROR_SUCCESS);
    if (SetWindowLongPtrW(window, GWL_EXSTYLE, style) == 0 &&
        GetLastError() != ERROR_SUCCESS) {
      return false;
    }
  }

  // WS_EX_LAYERED alone does not initialize layered-window rendering. Use full
  // global opacity; Flutter's per-pixel alpha and the transparent DWM backdrop
  // still provide the visible shape. A color key would erase lyric shadows.
  BYTE alpha = 0;
  DWORD flags = 0;
  if (GetLayeredWindowAttributes(window, nullptr, &alpha, &flags) &&
      alpha == 255 && flags == LWA_ALPHA) {
    return true;
  }
  return SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA) != FALSE;
}

}  // namespace desktop_lyrics

#endif  // RUNNER_DESKTOP_LYRICS_WINDOW_H_
