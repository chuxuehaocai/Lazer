// Builds the native HiFi audio engine for this host and stages it where the app
// looks for it.
//
//   dart run tool/build_native_audio.dart --ffmpeg-root /path/to/ffmpeg
//   LAZER_FFMPEG_ROOT=/path/to/ffmpeg dart run tool/build_native_audio.dart
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
// script is for `flutter run` during development and for macOS, whose Xcode build
// has no CMake step.
//
// FFmpeg must be built with the DSD sample format; a distro package is rejected by
// the engine's configure check (see `native/lazer-audio/cmake/FindLazerFFmpeg.cmake`).
import 'dart:ffi' show Abi;
import 'dart:io';

const String _outputDirectory = 'build/native-audio';

Future<void> main(List<String> arguments) async {
  exitCode = await _build(arguments);
}

Future<int> _build(List<String> arguments) async {
  final String? ffmpegRoot =
      _optionValue(arguments, '--ffmpeg-root') ??
      Platform.environment['LAZER_FFMPEG_ROOT'] ??
      Platform.environment['FFMPEG_ROOT'];

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

  final int configured = await _run(<String>[
    'cmake',
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
    'cmake',
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

  final Directory target = Directory(_outputDirectory);
  await target.create(recursive: true);
  final int staged = await _stage(cmakeDirectory, target, ffmpegPrefix);
  if (staged == 0) {
    stdout.writeln('\nStaged native audio libraries in ${target.path}');
    stdout.writeln('Playback now uses the native engine when the app runs from the '
        'repository root.');
  }
  return staged;
}

/// Copies the built engine, bridge, and FFmpeg runtime libraries next to the app.
Future<int> _stage(
  String cmakeDirectory,
  Directory target,
  String ffmpegRoot,
) async {
  final List<String> wanted = <String>[
    if (Platform.isWindows) ...<String>[
      'lazer-audio.dll',
      'liblazer-audio.dll',
      'lazer-audio-bridge.dll',
      'liblazer-audio-bridge.dll',
    ] else if (Platform.isMacOS) ...<String>[
      'liblazer-audio.dylib',
      'liblazer-audio-bridge.dylib',
    ] else ...<String>[
      'liblazer-audio.so',
      'liblazer-audio-bridge.so',
    ],
  ];
  int staged = 0;
  // Visual Studio writes a release build under `Release/`; Ninja and Makefiles put
  // it next to the sources. A recursive walk covers both.
  await for (final FileSystemEntity entity in Directory(cmakeDirectory).list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final String name = entity.uri.pathSegments.last;
    if (!wanted.contains(name)) continue;
    final File destination = File('${target.path}${Platform.pathSeparator}$name');
    await entity.copy(destination.path);
    stdout.writeln('staged ${destination.path}');
    staged++;
  }
  if (staged == 0) {
    stderr.writeln(
      'Nothing to stage: the build produced none of ${wanted.join(', ')}.',
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
        await entity.copy('${target.path}${Platform.pathSeparator}$name');
      }
    }
  } else if (Platform.isMacOS) {
    final Directory lib = Directory('$ffmpegRoot/lib');
    if (await lib.exists()) {
      await for (final FileSystemEntity entity in lib.list()) {
        if ((entity is! File && entity is! Link) ||
            !entity.path.endsWith('.dylib')) {
          continue;
        }
        final String name = entity.uri.pathSegments.last;
        await File(
          entity.path,
        ).copy('${target.path}${Platform.pathSeparator}$name');
      }
    }
  }
  return 0;
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
      if (Platform.isWindows && generator.startsWith('Visual Studio'))
        ...<String>['-A', _msvcArchitecture()],
    ];
  }
  if (Platform.isWindows) {
    final String? version = _visualStudioVersion();
    if (version != null) {
      return <String>['-G', 'Visual Studio $version', '-A', _msvcArchitecture()];
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
