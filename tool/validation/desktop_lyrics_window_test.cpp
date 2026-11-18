#include "../../windows/runner/desktop_lyrics_window.h"

#include <cassert>
#include <iostream>

int main() {
  // Hidden windows exercise the real USER32 layering contract without touching
  // an application window or depending on a running Flutter engine.
  HWND root = CreateWindowExW(WS_EX_APPWINDOW, L"STATIC", L"Lyrics test",
                              WS_POPUP, 0, 0, 120, 60, nullptr, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
  assert(root != nullptr);
  HWND view = CreateWindowExW(0, L"STATIC", L"Flutter view test", WS_CHILD,
                              0, 0, 120, 60, root, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
  assert(view != nullptr);

  for (const bool transparent : {true, false, true, false}) {
    assert(desktop_lyrics::SetClickThrough(root, transparent));
    const LONG_PTR style = GetWindowLongPtrW(root, GWL_EXSTYLE);
    assert((style & WS_EX_LAYERED) != 0);
    assert(((style & WS_EX_TRANSPARENT) != 0) == transparent);
    assert((style & WS_EX_APPWINDOW) == 0);
    assert((style & WS_EX_NOACTIVATE) != 0);

    BYTE alpha = 0;
    DWORD flags = 0;
    COLORREF color = 0;
    assert(GetLayeredWindowAttributes(root, &color, &alpha, &flags));
    assert(alpha == 255);
    assert(flags == LWA_ALPHA);
    assert((GetWindowLongPtrW(view, GWL_EXSTYLE) & WS_EX_LAYERED) == 0);
  }

  // A Flutter rendering child must never be given its own layered surface.
  assert(!desktop_lyrics::SetClickThrough(view));
  assert((GetWindowLongPtrW(view, GWL_EXSTYLE) & WS_EX_LAYERED) == 0);
  assert(!desktop_lyrics::SetClickThrough(nullptr));
  DestroyWindow(root);
  std::cout << "desktop lyric native transparency contracts passed\n";
}
