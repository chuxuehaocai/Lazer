// Builds the native HiFi audio engine for this host and stages it where the app
// looks for it.
//
//   dart run tool/build_native_audio.dart --ffmpeg-root /path/to/ffmpeg
//   LAZER_FFMPEG_ROOT=/path/to/ffmpeg dart run tool/build_native_audio.dart
//   dart run tool/build_native_audio.dart --project-root
//   dart run tool/build_native_audio.dart --output-directory /path/to/bundle
//
// What it does:
//   1. configures CMake over `native/` into `build/native-audio/cmake`,
//   2. builds `lazer-audio` and `lazer-audio-bridge`,
//   3. copies the libraries (and FFmpeg's runtime libraries) into
//      `build/native-audio/`, which is one of the directories `LazerAudioLoader`
//      searches when the app runs from the repository root.
//
// `flutter build windows` / `flutter build linux` do the equivalent through
// `native/CMakeLists.txt` and install the same libraries into the bundle, so this
// script also supports standalone builds and macOS, whose Xcode build has no
// CMake step. --project-root also places the Windows engine at the checkout root.
//
// FFmpeg must be built with the DSD sample format; a distro package is rejected by
// the engine's configure check (see `native/lazer-audio/cmake/FindLazerFFmpeg.cmake`).
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

const String _outputDirectory = 'build/native-audio';

Future<void> main(List<String> arguments) async {
  final inspectPath = _optionValue(arguments, '--inspect-library');
  if (inspectPath != null) {
    final report = LazerAudioLoader.inspect(inspectPath);
    if (!report.supportsStreaming) {
      stderr.writeln(report.reason ?? 'Built native reader bridge is missing');
      exitCode = 1;
    } else {
      stdout.writeln('validated native audio ABI ${report.api!.abiVersion()}');
    }
    return;
  }
  try {
    exitCode = await _build(arguments);
  } on FileSystemException catch (error) {
    stderr.writeln(
      'Unable to stage native audio libraries: $error\n'
      'Close running Lazer instances before replacing a library they have loaded.',
    );
    exitCode = 1;
  }
}

Future<int> _build(List<String> arguments) async {
  final String? ffmpegRoot =
      _optionValue(arguments, '--ffmpeg-root') ??
      Platform.environment['LAZER_FFMPEG_ROOT'] ??
      Platform.environment['FFMPEG_ROOT'] ??
      _cachedFfmpegRoot();

  if (ffmpegRoot == null || ffmpegRoot.isEmpty) {
    stderr.writeln(
      'No FFmpeg prefix given. The engine needs a DSD-capable FFmpeg build:\n'
      '  dart run tool/build_native_audio.dart --ffmpeg-root /path/to/ffmpeg',
    );
    return 2;
  }
  if (!Directory(ffmpegRoot).existsSync()) {
    stderr.writeln('FFmpeg prefix does not exist: $ffmpegRoot');
    return 2;
  }
  // CMake resolves `-D` paths relative to the *build* directory, so a relative
  // prefix like `build/third_party/ffmpeg` would silently point somewhere else.
  final String ffmpegPrefix = Directory(ffmpegRoot).absolute.path;

  final String configuration = _optionValue(arguments, '--config') ?? 'Release';
  final String cmakeDirectory = '$_outputDirectory/cmake';
  final String? cmake = _which('cmake') ?? _visualStudioCmake();
  if (cmake == null) {
    stderr.writeln(
      'CMake was not found. Install the C++ CMake tools in Visual Studio.',
    );
    return 2;
  }
  if (arguments.contains('--project-root') && !Platform.isWindows) {
    stderr.writeln('--project-root is only supported on Windows.');
    return 2;
  }

  final int configured = await _run(<String>[
    cmake,
    '-S',
    'native',
    '-B',
    cmakeDirectory,
    '-DLAZER_FFMPEG_ROOT=$ffmpegPrefix',
    '-DCMAKE_BUILD_TYPE=$configuration',
    // Multi-config generators (Visual Studio, Xcode) ignore CMAKE_BUILD_TYPE and
    // need the configuration named at build time instead.
    ..._generatorArguments(arguments),
  ]);
  if (configured != 0) return configured;

  final int built = await _run(<String>[
    cmake,
    '--build',
    cmakeDirectory,
    '--config',
    configuration,
    '--target',
    'lazer-audio',
    'lazer-audio-bridge',
    '--parallel',
  ]);
  if (built != 0) {
    stderr.writeln(
      '\nThe engine failed to build. The usual cause is an FFmpeg build without\n'
      'the DSD sample format (AV_SAMPLE_FMT_DSD) or without swresample; see\n'
      'native/lazer-audio/tools/build_dsd_ffmpeg.sh for one that works.',
    );
    return built;
  }

  final Directory target = Directory(
    _optionValue(arguments, '--output-directory') ?? _outputDirectory,
  );
  await target.create(recursive: true);
  final int staged = await _stage(
    cmakeDirectory,
    target,
    ffmpegPrefix,
    configuration,
    projectRoot: arguments.contains('--project-root'),
  );
  if (staged == 0) {
    stdout.writeln('\nStaged native audio libraries in ${target.path}');
    stdout.writeln(
      'Playback now uses the native engine when the app runs from the '
      'repository root.',
    );
  }
  return staged;
}

/// Copies the built engine, bridge, and FFmpeg runtime libraries next to the app.
Future<int> _stage(
  String cmakeDirectory,
  Directory target,
  String ffmpegRoot,
  String configuration, {
  bool projectRoot = false,
}) async {
  final List<String> wanted = <String>[
    if (Platform.isWindows) ...<String>[
      'lazer-audio.dll',
      'liblazer-audio.dll',
      'lazer-audio-bridge.dll',
      'liblazer-audio-bridge.dll',
    ] else if (Platform.isMacOS) ...<String>[
      'liblazer-audio.dylib',
      'liblazer-audio-bridge.dylib',
    ] else ...<String>['liblazer-audio.so', 'liblazer-audio-bridge.so'],
  ];
  final Set<String> staged = <String>{};
  final ffmpegStaged = <String>[];
  final sourcesByName = <String, File>{};
  // Use the target's configured output, never the first same-named library in a
  // recursive walk: another configuration or old nested build may be obsolete.
  for (final name in wanted) {
    final targetName = name.contains('bridge')
        ? 'lazer-audio-bridge'
        : 'lazer-audio';
    final sources = [
      File('$cmakeDirectory/$targetName/$configuration/$name'),
      File('$cmakeDirectory/$targetName/$name'),
      File('$cmakeDirectory/$configuration/$name'),
      File('$cmakeDirectory/$name'),
    ];
    final source = sources.where((file) => file.existsSync()).firstOrNull;
    if (source == null) continue;
    sourcesByName[name] = source;
    staged.add(name);
  }
  if (!staged.any((name) => !name.contains('bridge')) ||
      !staged.any((name) => name.contains('bridge'))) {
    stderr.writeln(
      'The build must produce both the engine and its reader bridge; found $staged.',
    );
    return 1;
  }
  if (Platform.isWindows) {
    // The engine loads FFmpeg's DLLs from its own directory.
    final Directory bin = Directory('$ffmpegRoot/bin');
    if (await bin.exists()) {
      await for (final FileSystemEntity entity in bin.list()) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.dll')) {
          continue;
        }
        final String name = entity.uri.pathSegments.last;
        sourcesByName[name] = entity;
        ffmpegStaged.add(name);
      }
    }
  } else if (Platform.isMacOS || Platform.isLinux) {
    final Directory lib = Directory('$ffmpegRoot/lib');
    if (await lib.exists()) {
      await for (final FileSystemEntity entity in lib.list()) {
        final String name = entity.uri.pathSegments.last;
        final bool isRuntimeLibrary = Platform.isMacOS
            ? name.endsWith('.dylib')
            : name.startsWith('lib') && name.contains('.so');
        if ((entity is! File && entity is! Link) || !isRuntimeLibrary) {
          continue;
        }
        sourcesByName[name] = File(entity.path);
        ffmpegStaged.add(name);
      }
    }
  }
  // Demand each shared FFmpeg dependency before touching an existing bundle.
  final missing = missingNativeFfmpegComponents(ffmpegStaged);
  if (missing.isNotEmpty) {
    stderr.writeln(
      'The FFmpeg runtime next to $ffmpegRoot covered ${ffmpegStaged.length} '
      'libraries but is missing ${missing.join(', ')}; the engine cannot load '
      'without them.',
    );
    return 1;
  }
  // Validate a complete isolated staging directory before modifying any live
  // runtime file. The validation runs in a subprocess so Windows releases the
  // mapped DLLs before they are published or the staging directory is removed.
  final temporary = await target.createTemp('.stage-');
  try {
    for (final entry in sourcesByName.entries) {
      await entry.value.copy('${temporary.path}/${entry.key}');
    }
    final engineName = staged.firstWhere((name) => !name.contains('bridge'));
    final validated = await _run([
      Platform.resolvedExecutable,
      File.fromUri(Platform.script).absolute.path,
      '--inspect-library',
      File('${temporary.path}/$engineName').absolute.path,
    ]);
    if (validated != 0) return validated;
    final destinations = <({File source, File target})>[
      for (final name in sourcesByName.keys)
        (
          source: File('${temporary.path}/$name'),
          target: File('${target.path}/$name'),
        ),
      if (projectRoot)
        (
          source: File('${temporary.path}/$engineName'),
          target: File('lazer-audio.dll'),
        ),
    ];
    await publishNativeAudioFiles(destinations, temporary);
    for (final entry in destinations) {
      stdout.writeln('staged ${entry.target.path}');
    }
    return 0;
  } finally {
    await temporary.delete(recursive: true);
  }
}

List<String> missingNativeFfmpegComponents(Iterable<String> libraryNames) => [
  for (final component in const ['avcodec', 'avformat', 'avutil', 'swresample'])
    if (!libraryNames.any((name) => name.toLowerCase().contains(component)))
      component,
];

/// Checks all locked destinations before updating an engine or its companions.
/// Backups also restore the previous complete runtime if copying later fails.
Future<void> publishNativeAudioFiles(
  List<({File source, File target})> files,
  Directory temporary,
) async {
  final changed = <({File source, File target, File? backup})>[];
  for (final entry in files) {
    if (await _filesEqual(entry.source, entry.target)) continue;
    File? backup;
    if (await entry.target.exists()) {
      final handle = await entry.target.open(mode: FileMode.append);
      await handle.close();
      backup = File('${temporary.path}/previous-${changed.length}');
      await entry.target.copy(backup.path);
    }
    changed.add((source: entry.source, target: entry.target, backup: backup));
  }
  final replaced = <({File target, File? backup})>[];
  try {
    for (final entry in changed) {
      replaced.add((target: entry.target, backup: entry.backup));
      await entry.source.copy(entry.target.path);
    }
  } catch (_) {
    for (final entry in replaced.reversed) {
      if (entry.backup case final backup?) {
        await backup.copy(entry.target.path);
      } else if (await entry.target.exists()) {
        await entry.target.delete();
      }
    }
    rethrow;
  }
}

Future<bool> _filesEqual(File source, File destination) async {
  if (await destination.exists() &&
      await source.length() == await destination.length()) {
    final left = await source.open();
    final right = await destination.open();
    try {
      bool equal = true;
      while (equal) {
        final bytes = await left.read(65536);
        final existing = await right.read(65536);
        if (bytes.length != existing.length) {
          equal = false;
          break;
        }
        if (bytes.isEmpty) return true;
        for (var index = 0; index < bytes.length; index++) {
          if (bytes[index] != existing[index]) {
            equal = false;
            break;
          }
        }
      }
    } finally {
      await left.close();
      await right.close();
    }
  }
  return false;
}

String? _cachedFfmpegRoot() {
  for (final prefix in <String>[
    'third_party/ffmpeg',
    'native/ffmpeg',
    if (Platform.isWindows) ...[
      'build/native-ffmpeg/windows-${_msvcArchitecture()}',
      if (Abi.current() == Abi.windowsX64) 'build/windows-ffmpeg-local',
    ],
  ]) {
    if (File('$prefix/include/libavformat/avformat.h').existsSync()) {
      return prefix;
    }
  }
  return null;
}

String? _visualStudioCmake() {
  if (!Platform.isWindows) return null;
  for (final root in <String>[
    'C:/Program Files (x86)/Microsoft Visual Studio/Installer',
    'C:/Program Files/Microsoft Visual Studio/Installer',
  ]) {
    final vswhere = File('$root/vswhere.exe');
    if (!vswhere.existsSync()) continue;
    final result = Process.runSync(vswhere.path, <String>[
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationPath',
    ]);
    final prefix = '${result.stdout}'.trim();
    final cmake = File(
      '$prefix/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe',
    );
    if (cmake.existsSync()) return cmake.path;
  }
  return null;
}

/// Honours `--generator`, and otherwise picks a toolchain that can actually build
/// the engine.
///
/// On Windows that has to be MSVC: the WASAPI backend links against GUID symbols
/// (`KSDATAFORMAT_SUBTYPE_PCM`, `PKEY_Device_FriendlyName`) that the MinGW headers
/// only declare, so a MinGW link fails with undefined references. Visual Studio is
/// driven by CMake without needing a developer prompt.
List<String> _generatorArguments(List<String> arguments) {
  final String? generator = _optionValue(arguments, '--generator');
  if (generator != null) {
    return <String>[
      '-G',
      generator,
      if (Platform.isWindows &&
          generator.startsWith('Visual Studio')) ...<String>[
        '-A',
        _msvcArchitecture(),
      ],
    ];
  }
  if (Platform.isWindows) {
    final String? version = _visualStudioVersion();
    if (version != null) {
      return <String>[
        '-G',
        'Visual Studio $version',
        '-A',
        _msvcArchitecture(),
      ];
    }
    stderr.writeln(
      'No Visual Studio installation was found. The engine needs MSVC on Windows '
      '(MinGW cannot link its WASAPI backend).',
    );
    return const <String>[];
  }
  if (_which('ninja') != null) return <String>['-G', 'Ninja'];
  return const <String>[];
}

/// The installed Visual Studio major version, as CMake's generator spells it.
String? _visualStudioVersion() {
  for (final String root in <String>[
    'C:/Program Files (x86)/Microsoft Visual Studio/Installer',
    'C:/Program Files/Microsoft Visual Studio/Installer',
  ]) {
    final File vswhere = File('$root/vswhere.exe');
    if (!vswhere.existsSync()) continue;
    final ProcessResult result = Process.runSync(vswhere.path, <String>[
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationVersion',
    ]);
    final String out = '${result.stdout}'.trim();
    final int? major = int.tryParse(out.split('.').first);
    if (major == null) continue;
    // CMake names the generators by product year, not by internal version.
    return switch (major) {
      17 => '17 2022',
      18 => '18 2026',
      _ => null,
    };
  }
  return null;
}

/// The `-A` platform name for the host architecture.
String _msvcArchitecture() =>
    Abi.current() == Abi.windowsArm64 ? 'ARM64' : 'x64';

String? _optionValue(List<String> arguments, String name) {
  for (int index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (argument == name && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

String? _which(String executable) {
  final String? path = Platform.environment['PATH'];
  if (path == null) return null;
  final List<String> extensions = Platform.isWindows
      ? <String>['.exe', '.bat', '']
      : <String>[''];
  for (final String directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    for (final String extension in extensions) {
      final File candidate = File(
        '$directory${Platform.pathSeparator}$executable$extension',
      );
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

Future<int> _run(List<String> command) async {
  stdout.writeln('> ${command.join(' ')}');
  final Process process = await Process.start(
    command.first,
    command.sublist(1),
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
