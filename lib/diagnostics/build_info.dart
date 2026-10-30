import '../updates/release_version.dart';

/// The source commit and release version the running binary was built from.
///
/// Automated builds stamp both through `--dart-define` (see
/// `.github/workflows/build.yml`): `LAZER_COMMIT=<sha>` and
/// `LAZER_VERSION=<tag>`. Local builds without the defines fall back to the
/// values this tree was cut from, so the About row and the update checker
/// still have something honest to compare against.
abstract final class BuildInfo {
  static const String _stamped = String.fromEnvironment('LAZER_COMMIT');
  static const String _fallback = 'a8518ab';
  static const String _stampedVersion = String.fromEnvironment('LAZER_VERSION');
  static const String _fallbackVersion = '2.0.0-beta.4';

  /// The full commit SHA the binary was built from.
  static String get commit => _stamped.isEmpty ? _fallback : _stamped;

  /// The first seven characters, the short form GitHub prints.
  static String get shortCommit {
    final String value = commit.trim();
    return value.length <= 7 ? value : value.substring(0, 7);
  }

  /// The release version without the tag's `v` prefix, e.g. `2.0.0-beta.2`.
  ///
  /// A branch build (`nextgen`) is not a version, so it falls back to the
  /// version in pubspec instead of feeding a branch name to SemVer comparison.
  static String get version {
    final ReleaseVersion? parsed = ReleaseVersion.parse(_stampedVersion);
    return parsed?.normalized ?? _fallbackVersion;
  }

  /// The version as it appears in the interface.
  static String get displayVersion => 'v$version';
}
