#ifndef RUNNER_DESKTOP_LYRICS_PLUGIN_H_
#define RUNNER_DESKTOP_LYRICS_PLUGIN_H_

#include <windows.h>

#include <flutter_plugin_registrar.h>

#ifdef __cplusplus
extern "C" {
#endif

// Registers the desktop-lyrics channel on one engine and remembers its window.
void DesktopLyricsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar,
    HWND window);

// Called from desktop_multi_window's window-created callback. Registers the
// plugins a lyrics subwindow needs: window_manager, screen_retriever and the
// desktop-placement channel. |flutter_view_controller| is a
// flutter::FlutterViewController*.
void DesktopLyricsRegisterSubwindowPlugins(void* flutter_view_controller);

#ifdef __cplusplus
}
#endif

#endif  // RUNNER_DESKTOP_LYRICS_PLUGIN_H_
