/// Native platform implementation using dart:io.
///
/// This file is only imported on native platforms (VM).

import 'dart:io' as io;
import 'dart:typed_data';

import 'platform.dart';

/// Creates the native platform services instance.
PlatformServices createPlatformServices() => NativePlatformServices();

/// Native implementation of platform services using dart:io.
class NativePlatformServices extends PlatformServices {
  @override
  void defaultPrint(String s) {
    io.stdout.write(s);
  }

  @override
  String? getEnvironmentVariable(String name) {
    return io.Platform.environment[name];
  }

  @override
  bool fileExists(String path) {
    return io.File(path).existsSync();
  }

  @override
  bool directoryExists(String path) {
    return io.Directory(path).existsSync();
  }

  @override
  Uint8List? readFileAsBytes(String path) {
    try {
      final file = io.File(path);
      if (file.existsSync()) {
        return file.readAsBytesSync();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  String? readFileAsString(String path) {
    try {
      final file = io.File(path);
      if (file.existsSync()) {
        return file.readAsStringSync();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool deleteFile(String path) {
    try {
      io.File(path).deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool renameFile(String oldPath, String newPath) {
    try {
      io.File(oldPath).renameSync(newPath);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  String get pathSeparator => io.Platform.pathSeparator;

  @override
  int? runProcess(String command, List<String> args) {
    try {
      final result = io.Process.runSync(command, args);
      return result.exitCode;
    } catch (_) {
      return null;
    }
  }

  @override
  Never exit(int code) {
    io.exit(code);
  }

  @override
  bool get isWeb => false;

  @override
  bool get supportsFileSystem => true;

  @override
  bool get supportsProcess => true;
}
