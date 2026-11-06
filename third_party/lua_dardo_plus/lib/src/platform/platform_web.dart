/// Web platform stub implementation.
///
/// This file is imported on web platforms where dart:io is not available.
/// Most file system and process operations throw UnsupportedError.

import 'dart:typed_data';

import 'platform.dart';

/// Creates the web platform services instance.
PlatformServices createPlatformServices() => WebPlatformServices();

/// Web implementation of platform services.
///
/// File system and process operations are not supported on web
/// and will throw [UnsupportedError].
class WebPlatformServices extends PlatformServices {
  @override
  void defaultPrint(String s) {
    // Use print() on web - it goes to browser console
    // ignore: avoid_print
    print(s);
  }

  @override
  String? getEnvironmentVariable(String name) {
    // Environment variables not available on web
    return null;
  }

  @override
  bool fileExists(String path) {
    // File system not available on web
    return false;
  }

  @override
  bool directoryExists(String path) {
    // File system not available on web
    return false;
  }

  @override
  Uint8List? readFileAsBytes(String path) {
    // File system not available on web
    return null;
  }

  @override
  String? readFileAsString(String path) {
    // File system not available on web
    return null;
  }

  @override
  bool deleteFile(String path) {
    throw UnsupportedError('File operations are not supported on web platform');
  }

  @override
  bool renameFile(String oldPath, String newPath) {
    throw UnsupportedError('File operations are not supported on web platform');
  }

  @override
  String get pathSeparator => '/';

  @override
  int? runProcess(String command, List<String> args) {
    throw UnsupportedError(
        'Process operations are not supported on web platform');
  }

  @override
  Never exit(int code) {
    throw UnsupportedError('exit() is not supported on web platform');
  }

  @override
  bool get isWeb => true;

  @override
  bool get supportsFileSystem => false;

  @override
  bool get supportsProcess => false;
}
