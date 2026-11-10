#include "flutter_window.h"

#include <desktop_multi_window/desktop_multi_window_plugin.h>

#include <optional>

#include "desktop_lyrics_plugin.h"
#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {

WNDPROC g_flutter_view_proc = nullptr;

// The Flutter view is a child window that covers the entire client area, so
// the cursor is always "over the child" and Windows never asks the top-level
// window where its resize borders are. Report the root's hit test from the
// child, and hand non-client clicks back to the root so Windows runs its own
// sizing loop instead of dropping the click on the child.
LRESULT CALLBACK FlutterViewProc(HWND hwnd,
                                 UINT message,
                                 WPARAM wparam,
                                 LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST: {
      const HWND root = GetAncestor(hwnd, GA_ROOT);
      if (root != nullptr) {
        const LRESULT hit = SendMessage(root, WM_NCHITTEST, wparam, lparam);
        if (hit != HTCLIENT) {
          return hit;
        }
      }
      break;
    }
    case WM_NCLBUTTONDOWN: {
      const HWND root = GetAncestor(hwnd, GA_ROOT);
      if (root != nullptr) {
        ReleaseCapture();
        return SendMessage(root, WM_NCLBUTTONDOWN, wparam, lparam);
      }
      break;
    }
  }
  return CallWindowProc(g_flutter_view_proc, hwnd, message, wparam, lparam);
}

}  // namespace

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // Subwindows created by desktop_multi_window do not run the generated
  // registrant. Register the plugins a lyrics overlay needs.
  DesktopMultiWindowSetWindowCreatedCallback(
      [](void* flutter_view_controller) {
        DesktopLyricsRegisterSubwindowPlugins(flutter_view_controller);
      });
  system_media_ = std::make_unique<SystemMediaControls>(
      flutter_controller_->engine()->messenger(), GetHandle());
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view);

  // Route the child's hit test through the root so the frameless window still
  // has real resize borders (see FlutterViewHitTestProc above).
  g_flutter_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      view, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(FlutterViewProc)));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  system_media_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (system_media_ && system_media_->HandleWindowMessage(message, lparam)) return 0;
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
