/// Browser stand-in for the FFI audio library loader.
class LazerAudioLibrary {
  const LazerAudioLibrary();

  /// The native API surface; always null in the browser.
  Object? get api => null;

  String get reason => '浏览器没有原生音频库';
}

/// The browser never ships the native engine binary.
class LazerAudioLoader {
  static String? importedLibraryPath;

  static bool get isSupportedHost => false;

  static LazerAudioLibrary load() => const LazerAudioLibrary();
}
