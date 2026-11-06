/// Platform abstraction layer for LuaDardo.
///
/// This file uses conditional imports to provide platform-specific
/// implementations for IO operations.
///
/// On native platforms (VM), uses dart:io for file operations.
/// On web platforms, provides stub implementations.

import 'dart:typed_data';

import 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart'
    as platform_impl;

export 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart';

/// Abstract interface for platform-specific services.
///
/// This allows LuaDardo to run on both native and web platforms
/// by abstracting away dart:io dependencies.
abstract class PlatformServices {
  static PlatformServices? _instance;

  /// Get the singleton instance of platform services.
  /// Automatically initializes if not already done.
  static PlatformServices get instance {
    _instance ??= platform_impl.createPlatformServices();
    // Initialize printCallback to use defaultPrint on first access
    if (_instance!.printCallback == _defaultPrintCallback) {
      _instance!.printCallback = _instance!.defaultPrint;
    }
    return _instance!;
  }

  /// Initialize the platform services with a custom implementation.
  /// This is optional - if not called, a default implementation will be used.
  static void init(PlatformServices services) {
    _instance = services;
  }

  /// Reset the platform services instance (useful for testing).
  static void reset() {
    _instance = null;
  }

  /// Custom print callback. Can be overridden to redirect output.
  void Function(String) printCallback = _defaultPrintCallback;

  static void _defaultPrintCallback(String s) {
    // Placeholder - will be replaced with defaultPrint on first access
  }

  /// Print a string using the default mechanism for this platform.
  void defaultPrint(String s);

  /// Print a string followed by a newline.
  void println(String s) {
    printCallback(s);
    printCallback('\n');
  }

  /// Get an environment variable value.
  /// Returns null if not available or not supported on this platform.
  String? getEnvironmentVariable(String name);

  /// Check if a file exists at the given path.
  bool fileExists(String path);

  /// Check if a directory exists at the given path.
  bool directoryExists(String path);

  /// Read a file as bytes.
  /// Returns null if file doesn't exist or reading fails.
  Uint8List? readFileAsBytes(String path);

  /// Read a file as a string.
  /// Returns null if file doesn't exist or reading fails.
  String? readFileAsString(String path);

  /// Delete a file at the given path.
  /// Returns true if successful, false otherwise.
  bool deleteFile(String path);

  /// Rename a file from oldPath to newPath.
  /// Returns true if successful, false otherwise.
  bool renameFile(String oldPath, String newPath);

  /// Get the platform's path separator.
  String get pathSeparator;

  /// Run a process synchronously.
  /// Returns the exit code, or null if not supported.
  int? runProcess(String command, List<String> args);

  /// Exit the application with the given code.
  /// Throws UnsupportedError on platforms that don't support this.
  Never exit(int code);

  /// Whether this is running on a web platform.
  bool get isWeb;

  /// Whether this is running on a native platform.
  bool get isNative => !isWeb;

  /// Whether file system operations are supported.
  bool get supportsFileSystem;

  /// Whether process operations are supported.
  bool get supportsProcess;
}
