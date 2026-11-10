#include "desktop_lyrics_plugin.h"

#include <flutter/flutter_engine.h>
#include <flutter/flutter_view.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_plugin_registrar.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <window_manager/window_manager_plugin.h>
#include <windowsx.h>

#include <algorithm>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>

namespace {

constexpr char kChannel[] = "lazer/desktop_lyrics";
constexpr int kDesktopBottomGap = 24;
constexpr int kDragHandleWidth = 24;
constexpr int kDragHandleHeight = 56;

// Makes the overlay invisible to the mouse. WM_NCHITTEST returns
// HTTRANSPARENT from the subclass below, so clicks reach the desktop even
// where a lyric glyph is painted.
void SetClickThrough(HWND window) {
  if (window == nullptr) return;
  LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);
  style |= WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
  style &= ~WS_EX_APPWINDOW;
  SetWindowLongPtrW(window, GWL_EXSTYLE, style);
}

std::wstring PositionFile() {
  wchar_t appdata[MAX_PATH] = {};
  const DWORD length =
      GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return L"";
  const std::wstring root = std::wstring(appdata) + L"\\dev.naominet";
  CreateDirectoryW(root.c_str(), nullptr);
  const std::wstring directory = root + L"\\lazer_nextgen";
  CreateDirectoryW(directory.c_str(), nullptr);
  return directory + L"\\desktop_lyrics.ini";
}

class DesktopLyricsPlugin {
 public:
  DesktopLyricsPlugin(flutter::PluginRegistrarWindows* registrar, HWND window)
      : window_(window) {
    taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
    LoadPosition();
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), kChannel,
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
          if (call.method_name() == "attachToDesktop") {
            result->Success(flutter::EncodableValue(Attach()));
          } else if (call.method_name() == "detachFromDesktop") {
            Detach();
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "startDesktopDrag") {
            StartDrag();
            result->Success(flutter::EncodableValue(true));
          } else {
            result->NotImplemented();
          }
        });
  }

  ~DesktopLyricsPlugin() {
    Detach();
    channel_.reset();
  }

  bool Attach() {
    if (!IsWindow(window_)) return false;
    HWND progman = FindWindowW(L"Progman", nullptr);
    if (progman == nullptr) return false;

    if (!saved_) {
      original_parent_ = GetParent(window_);
      original_owner_ =
          reinterpret_cast<HWND>(GetWindowLongPtrW(window_, GWLP_HWNDPARENT));
      original_style_ = GetWindowLongPtrW(window_, GWL_STYLE);
      original_ex_style_ = GetWindowLongPtrW(window_, GWL_EXSTYLE);
      GetWindowRect(window_, &original_rect_);
      saved_ = true;

      // Keep the overlay top-level. Parenting into Progman/WorkerW is not
      // portable: on Windows 11 24H2+ SHELLDLL_DefView is a layered child
      // that covers the whole desktop, so any child below it is invisible.
      if (original_parent_ != nullptr) SetParent(window_, nullptr);

      LONG_PTR style = original_style_;
      style &= ~(WS_CHILD | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU |
                 WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
      style |= WS_POPUP | WS_VISIBLE;
      SetWindowLongPtrW(window_, GWL_STYLE, style);

      LONG_PTR ex_style = original_ex_style_;
      ex_style &= ~(WS_EX_APPWINDOW | WS_EX_TOPMOST | WS_EX_WINDOWEDGE |
                    WS_EX_CLIENTEDGE | WS_EX_DLGMODALFRAME);
      ex_style |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT;
      SetWindowLongPtrW(window_, GWL_EXSTYLE, ex_style);
    }

    // Owned by Progman: the overlay stays above the desktop (and its icon
    // view) while every normal window stays above the overlay. This is more
    // stable than moving Progman behind the overlay, which Explorer undoes.
    // Re-applied on every attach so an Explorer restart picks up the new
    // Progman automatically.
    SetWindowLongPtrW(window_, GWLP_HWNDPARENT,
                      reinterpret_cast<LONG_PTR>(progman));

    MONITORINFO monitor = {};
    monitor.cbSize = sizeof(monitor);
    HMONITOR monitor_handle =
        MonitorFromWindow(window_, MONITOR_DEFAULTTOPRIMARY);
    if (!GetMonitorInfoW(monitor_handle, &monitor)) return false;

    RECT rect = {};
    if (!GetWindowRect(window_, &rect)) return false;
    const int width = rect.right - rect.left;
    const int height = rect.bottom - rect.top;
    const int work_left = static_cast<int>(monitor.rcWork.left);
    const int work_top = static_cast<int>(monitor.rcWork.top);
    const int work_right = static_cast<int>(monitor.rcWork.right);
    const int work_bottom = static_cast<int>(monitor.rcWork.bottom);
    const int work_width = work_right - work_left;
    int x = has_custom_position_
                ? custom_x_
                : work_left + (work_width - width) / 2;
    int y = has_custom_position_
                ? custom_y_
                : work_bottom - height - kDesktopBottomGap;
    x = std::max(work_left, std::min(x, work_right - width));
    y = std::max(work_top, std::min(y, work_bottom - height));

    // HWND_BOTTOM keeps the overlay at the bottom of the normal window band;
    // its Progman owner keeps it above the desktop. Every normal window stays
    // above it.
    SetWindowPos(window_, HWND_BOTTOM, x, y, width, height,
                 SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    ShowWindow(window_, SW_SHOWNOACTIVATE);
    SetClickThrough(window_);
    InstallClickThrough();
    // The Flutter view is a child window; mark it click-through too so a
    // desktop lyric never eats a double-click on an icon.
    if (view_ != nullptr) SetClickThrough(view_);
    attached_ = true;
    return true;
  }

  void StartDrag() {
    if (!attached_ || !IsWindow(window_)) return;
    ReleaseCapture();
    SendMessageW(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    RECT rect = {};
    if (GetWindowRect(window_, &rect)) {
      custom_x_ = rect.left;
      custom_y_ = rect.top;
      has_custom_position_ = true;
      SavePosition();
    }
  }

  void Detach() {
    if (!saved_ && !attached_) return;
    attached_ = false;
    RemoveClickThrough();
    if (!IsWindow(window_)) {
      saved_ = false;
      return;
    }
    ShowWindow(window_, SW_HIDE);
    SetParent(window_, original_parent_);
    SetWindowLongPtrW(window_, GWLP_HWNDPARENT,
                      reinterpret_cast<LONG_PTR>(original_owner_));
    SetWindowLongPtrW(window_, GWL_STYLE, original_style_);
    SetWindowLongPtrW(window_, GWL_EXSTYLE, original_ex_style_);
    SetWindowPos(window_, nullptr, original_rect_.left, original_rect_.top,
                 original_rect_.right - original_rect_.left,
                 original_rect_.bottom - original_rect_.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    saved_ = false;
  }

 private:
  void LoadPosition() {
    const std::wstring path = PositionFile();
    if (path.empty()) return;
    wchar_t x[32] = {};
    wchar_t y[32] = {};
    GetPrivateProfileStringW(L"desktop_lyrics", L"x", L"", x, 32,
                             path.c_str());
    GetPrivateProfileStringW(L"desktop_lyrics", L"y", L"", y, 32,
                             path.c_str());
    if (x[0] == L'\0' || y[0] == L'\0') return;
    custom_x_ = _wtoi(x);
    custom_y_ = _wtoi(y);
    has_custom_position_ = true;
  }

  void SavePosition() {
    const std::wstring path = PositionFile();
    if (path.empty()) return;
    const std::wstring x = std::to_wstring(custom_x_);
    const std::wstring y = std::to_wstring(custom_y_);
    WritePrivateProfileStringW(L"desktop_lyrics", L"x", x.c_str(),
                               path.c_str());
    WritePrivateProfileStringW(L"desktop_lyrics", L"y", y.c_str(),
                               path.c_str());
  }

  bool IsDragHandlePoint(HWND hwnd, LPARAM lparam) const {
    POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (!ScreenToClient(hwnd, &point)) return false;
    RECT client = {};
    if (!GetClientRect(hwnd, &client)) return false;
    const int top = (client.bottom - kDragHandleHeight) / 2;
    return point.x >= 0 && point.x < kDragHandleWidth &&
           point.y >= top && point.y < top + kDragHandleHeight;
  }

  void InstallClickThrough() {
    if (root_proc_ == nullptr) {
      ProcMap()[window_] = this;
      root_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
          window_, GWLP_WNDPROC,
          reinterpret_cast<LONG_PTR>(&DesktopLyricsPlugin::OverlayProc)));
    }
    view_ = FindWindowExW(window_, nullptr, L"FLUTTERVIEW", nullptr);
    if (view_ != nullptr && view_proc_ == nullptr) {
      ProcMap()[view_] = this;
      view_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
          view_, GWLP_WNDPROC,
          reinterpret_cast<LONG_PTR>(&DesktopLyricsPlugin::OverlayProc)));
    }
  }

  void RemoveClickThrough() {
    if (window_ != nullptr && root_proc_ != nullptr) {
      if (IsWindow(window_)) {
        SetWindowLongPtrW(window_, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(root_proc_));
      }
      ProcMap().erase(window_);
      root_proc_ = nullptr;
    }
    if (view_ != nullptr && view_proc_ != nullptr) {
      if (IsWindow(view_)) {
        SetWindowLongPtrW(view_, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(view_proc_));
      }
      ProcMap().erase(view_);
      view_proc_ = nullptr;
      view_ = nullptr;
    }
  }

  static std::map<HWND, DesktopLyricsPlugin*>& ProcMap() {
    static auto* map = new std::map<HWND, DesktopLyricsPlugin*>();
    return *map;
  }

  static LRESULT CALLBACK OverlayProc(HWND hwnd,
                                      UINT message,
                                      WPARAM wparam,
                                      LPARAM lparam) {
    auto& map = ProcMap();
    auto it = map.find(hwnd);
    if (it == map.end()) {
      return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    DesktopLyricsPlugin* self = it->second;
    if (self->taskbar_created_ != 0 && message == self->taskbar_created_) {
      // Explorer restarted and recreated Progman. Re-own the new desktop.
      self->Attach();
      return 0;
    }
    if (message == WM_NCHITTEST) {
      return self->IsDragHandlePoint(hwnd, lparam) ? HTCLIENT
                                                   : HTTRANSPARENT;
    }
    WNDPROC previous =
        hwnd == self->window_ ? self->root_proc_ : self->view_proc_;
    return CallWindowProcW(previous, hwnd, message, wparam, lparam);
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  HWND view_ = nullptr;
  WNDPROC root_proc_ = nullptr;
  WNDPROC view_proc_ = nullptr;
  UINT taskbar_created_ = 0;
  HWND original_parent_ = nullptr;
  HWND original_owner_ = nullptr;
  LONG_PTR original_style_ = 0;
  LONG_PTR original_ex_style_ = 0;
  RECT original_rect_ = {};
  int custom_x_ = 0;
  int custom_y_ = 0;
  bool has_custom_position_ = false;
  bool saved_ = false;
  bool attached_ = false;
};

std::map<FlutterDesktopPluginRegistrarRef, DesktopLyricsPlugin*>& Plugins() {
  static auto* plugins =
      new std::map<FlutterDesktopPluginRegistrarRef, DesktopLyricsPlugin*>();
  return *plugins;
}

void OnRegistrarDestroyed(FlutterDesktopPluginRegistrarRef registrar) {
  auto& plugins = Plugins();
  auto it = plugins.find(registrar);
  if (it == plugins.end()) return;
  delete it->second;
  plugins.erase(it);
}

}  // namespace

void DesktopLyricsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar,
    HWND window) {
  if (registrar == nullptr || window == nullptr) return;
  auto& plugins = Plugins();
  if (plugins.find(registrar) != plugins.end()) return;
  auto* plugin_registrar = flutter::PluginRegistrarManager::GetInstance()
                               ->GetRegistrar<flutter::PluginRegistrarWindows>(
                                   registrar);
  if (plugin_registrar == nullptr) return;
  plugins[registrar] = new DesktopLyricsPlugin(plugin_registrar, window);
  FlutterDesktopPluginRegistrarSetDestructionHandler(registrar,
                                                     &OnRegistrarDestroyed);
}

void DesktopLyricsRegisterSubwindowPlugins(void* flutter_view_controller) {
  if (flutter_view_controller == nullptr) return;
  auto* controller =
      static_cast<flutter::FlutterViewController*>(flutter_view_controller);
  flutter::FlutterEngine* engine = controller->engine();
  if (engine == nullptr || controller->view() == nullptr) return;

  HWND root = GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  if (root == nullptr) root = controller->view()->GetNativeWindow();

  FlutterDesktopPluginRegistrarRef registrar =
      engine->GetRegistrarForPlugin("DesktopLyricsPlugin");
  DesktopLyricsPluginRegisterWithRegistrar(registrar, root);

  FlutterDesktopPluginRegistrarRef window_manager_registrar =
      engine->GetRegistrarForPlugin("WindowManagerPlugin");
  if (window_manager_registrar != nullptr) {
    WindowManagerPluginRegisterWithRegistrar(window_manager_registrar);
  }

  // window_manager.setAlignment asks screen_retriever for the display under
  // the cursor. A subwindow engine does not run the generated registrant, so
  // register it here as well or alignment throws MissingPluginException.
  FlutterDesktopPluginRegistrarRef screen_registrar =
      engine->GetRegistrarForPlugin("ScreenRetrieverWindowsPlugin");
  if (screen_registrar != nullptr) {
    ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(screen_registrar);
  }
}
