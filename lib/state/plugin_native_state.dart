part of 'app_state.dart';

extension _PluginNativeState on AppState {
  bool get _pluginLyricsSupported =>
      !kIsWeb &&
      const {
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  Map<String, Object?> _pluginLyricsStatus() => {
    // These are requested settings. Window creation/desktop attachment can fail
    // asynchronously; do not present the flags as a native-window health check.
    'scope': 'requested-settings',
    'mode': desktopLyricsEnabled
        ? 'desktop'
        : floatingLyricsEnabled
        ? 'floating'
        : 'off',
    'locked': floatingLyricsLocked, 'lines': lyricsOverlayLines,
    'desktopSupported': desktopLyricsSupported,
  };

  PluginNativeApi _createPluginNativeApi() => PluginNativeApi(
    platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
    audioStatusSupported: () => hifi?.nativeAvailable == true,
    audioDevicesSupported: () => hifi?.supportsDevices == true,
    audioStatus: () => pluginNativeAudioStatus(hifi),
    audioDevices: () => pluginNativeAudioDevices(hifi),
    lyricsSupported: _pluginLyricsSupported,
    desktopLyricsSupported: desktopLyricsSupported,
    lyricsStatus: _pluginLyricsStatus,
    setFloatingLyrics: setFloatingLyricsEnabled,
    setDesktopLyrics: setDesktopLyricsEnabled,
    setLyricsLocked: setFloatingLyricsLocked,
    setLyricsLines: setLyricsOverlayLines,
  );
}
