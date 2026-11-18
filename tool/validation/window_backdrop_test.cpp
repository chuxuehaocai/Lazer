#include "../../windows/runner/window_backdrop_native.h"

#include <cassert>
#include <iostream>
#include <vector>

namespace {

std::vector<int> backdrops;
std::vector<MARGINS> frames;
HRESULT backdrop_result = S_OK;
HRESULT frame_result = S_OK;
HRESULT policy_result = S_OK;
BOOL last_dark = FALSE;
bool frame_ready = false;

HRESULT WINAPI SetAttribute(HWND, DWORD attribute, LPCVOID value, DWORD size) {
  if (attribute == window_backdrop::kSystemBackdropType) {
    assert(size == sizeof(int));
    const int backdrop = *static_cast<const int*>(value);
    backdrops.push_back(backdrop);
    if (backdrop == window_backdrop::kBackdropMica) {
      // The full transparent client frame must be ready before Mica is set.
      assert(frame_ready);
      return backdrop_result;
    }
  } else if (attribute == DWMWA_NCRENDERING_POLICY) {
    assert(*static_cast<const DWMNCRENDERINGPOLICY*>(value) == DWMNCRP_ENABLED);
    return policy_result;
  } else if (attribute == window_backdrop::kImmersiveDarkMode) {
    assert(size == sizeof(BOOL));
    last_dark = *static_cast<const BOOL*>(value);
  } else {
    assert(false && "Unexpected DWM attribute");
  }
  return S_OK;
}

HRESULT WINAPI ExtendFrame(HWND, const MARGINS* margins) {
  frames.push_back(*margins);
  const bool glass = margins->cxLeftWidth == -1;
  if (glass) {
    assert(margins->cxRightWidth == -1 && margins->cyTopHeight == -1 &&
           margins->cyBottomHeight == -1);
    frame_ready = SUCCEEDED(frame_result);
    return frame_result;
  }
  assert(margins->cxLeftWidth == 0 && margins->cxRightWidth == 0 &&
         margins->cyTopHeight == 1 && margins->cyBottomHeight == 0);
  frame_ready = false;
  return S_OK;
}

void Reset() {
  backdrops.clear();
  frames.clear();
  backdrop_result = S_OK;
  frame_result = S_OK;
  policy_result = S_OK;
  frame_ready = false;
}

}  // namespace

int main() {
  // Hidden real HWNDs exercise the window contract without disturbing a user's
  // app or requiring Flutter, wallpaper, or a visible interactive desktop.
  HWND root = CreateWindowExW(0, L"STATIC", L"Mica test", WS_OVERLAPPEDWINDOW,
                              0, 0, 120, 60, nullptr, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
  assert(root != nullptr);
  HWND view = CreateWindowExW(0, L"STATIC", L"Flutter view", WS_CHILD,
                              0, 0, 120, 60, root, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
  assert(view != nullptr);
  const LONG_PTR root_style = GetWindowLongPtrW(root, GWL_EXSTYLE);
  const LONG_PTR view_style = GetWindowLongPtrW(view, GWL_EXSTYLE);

  const window_backdrop::DwmApi fake{SetAttribute, ExtendFrame};
  assert(!window_backdrop::ApplyMica(nullptr, true, false, fake));
  assert(!window_backdrop::ApplyMica(view, true, false, fake));
  assert(backdrops.empty() && frames.empty());

  assert(window_backdrop::ApplyMica(root, true, true, fake));
  assert(last_dark == TRUE && frame_ready);
  assert(backdrops == std::vector<int>{window_backdrop::kBackdropMica});
  assert(!window_backdrop::ApplyMica(root, false, false, fake));
  assert(last_dark == FALSE && !frame_ready);
  assert(backdrops.back() == window_backdrop::kBackdropNone);

  // Each partial failure must remove the backdrop AND restore the shadow-only
  // frame, including unsupported Windows 10 / Windows Server installations.
  for (int failure = 0; failure < 3; ++failure) {
    Reset();
    if (failure == 0) policy_result = E_FAIL;
    if (failure == 1) frame_result = E_FAIL;
    if (failure == 2) backdrop_result = E_INVALIDARG;
    assert(!window_backdrop::ApplyMica(root, true, false, fake));
    assert(backdrops.back() == window_backdrop::kBackdropNone);
    assert(!frame_ready && frames.back().cyTopHeight == 1);
  }

  const int mica = window_backdrop::kBackdropMica;
  const bool supported = SUCCEEDED(DwmSetWindowAttribute(
      root, window_backdrop::kSystemBackdropType, &mica, sizeof(mica)));
  assert(window_backdrop::ApplyMica(root, true, true) == supported);
  if (supported) {
    int backdrop = 0;
    assert(SUCCEEDED(DwmGetWindowAttribute(
        root, window_backdrop::kSystemBackdropType, &backdrop, sizeof(backdrop))));
    assert(backdrop == window_backdrop::kBackdropMica);
  }
  assert(!window_backdrop::ApplyMica(root, false, false));
  if (supported) {
    int backdrop = 0;
    assert(SUCCEEDED(DwmGetWindowAttribute(
        root, window_backdrop::kSystemBackdropType, &backdrop, sizeof(backdrop))));
    assert(backdrop == window_backdrop::kBackdropNone);
  }
  // Material changes must never introduce layered-window opacity or alter the
  // Flutter child, which owns the EGL surface.
  assert(GetWindowLongPtrW(root, GWL_EXSTYLE) == root_style);
  assert(GetWindowLongPtrW(view, GWL_EXSTYLE) == view_style);
  DestroyWindow(root);
  std::cout << "Windows Mica contracts passed (system backdrop supported: "
            << supported << ")\n";
}
