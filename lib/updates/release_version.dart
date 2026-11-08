/// A release number understood by the update checker.
///
/// The repository tags releases as plain semantic versions (`v1.5`,
/// `v2.0.0-beta.1`). The parser accepts those tags, the `+build` suffix pubspec
/// uses, and a missing patch component (`v1.5` → `1.5.0`). Comparison follows
/// SemVer 2.0 precedence: `2.0.0-beta.2` precedes `2.0.0`, while numeric
/// pre-release identifiers sort below alphanumeric ones.
final class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion._(this.major, this.minor, this.patch, this.preRelease);

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated pre-release identifiers; empty for a final release.
  final List<String> preRelease;

  static final RegExp _identifier = RegExp(r'^[0-9A-Za-z-]+$');

  /// Parses [raw] as a version, returning null when it is not one.
  ///
  /// A tag in the repository's own spelling (`v2.0.0-beta.2`) and a build
  /// number suffix (`2.0.0-beta.2+5`) both parse. Anything else — a branch
  /// name, a malformed tag — is not a version and must not be compared.
  static ReleaseVersion? parse(String raw) {
    String text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1).trim();
    }
    final int plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    final int dash = text.indexOf('-');
    final String corePart = dash >= 0 ? text.substring(0, dash) : text;
    final String prePart = dash >= 0 ? text.substring(dash + 1) : '';
    // A trailing hyphen is not a version: taking it as a final release would
    // let a malformed tag outrank the real beta it resembles.
    if (dash >= 0 && prePart.isEmpty) return null;
    final List<String> parts = corePart.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final List<int> numbers = <int>[];
    for (final String part in parts) {
      if (part.isEmpty || !RegExp(r'^\d+$').hasMatch(part)) return null;
      final int? value = int.tryParse(part);
      if (value == null) return null;
      numbers.add(value);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    final List<String> identifiers = prePart.isEmpty
        ? const <String>[]
        : prePart.split('.');
    for (final String identifier in identifiers) {
      if (!_identifier.hasMatch(identifier)) return null;
      // SemVer forbids leading zeroes in numeric identifiers. Accepting them
      // made "2.0.0-01" compare equal to "2.0.0-1" while normalising and
      // hashing differently.
      if (identifier.length > 1 &&
          identifier.startsWith('0') &&
          int.tryParse(identifier) != null) {
        return null;
      }
    }
    return ReleaseVersion._(
      numbers[0],
      numbers[1],
      numbers[2],
      List<String>.unmodifiable(identifiers),
    );
  }

  bool get isPreRelease => preRelease.isNotEmpty;

  /// The canonical spelling without the `v` prefix or build metadata.
  String get normalized =>
      '$major.$minor.$patch${isPreRelease ? '-${preRelease.join('.')}' : ''}';

  @override
  int compareTo(ReleaseVersion other) {
    final int core = major != other.major
        ? major.compareTo(other.major)
        : minor != other.minor
        ? minor.compareTo(other.minor)
        : patch.compareTo(other.patch);
    if (core != 0) return core;
    // A final release outranks every pre-release of the same core.
    if (!isPreRelease && !other.isPreRelease) return 0;
    if (!isPreRelease) return 1;
    if (!other.isPreRelease) return -1;
    final int count = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (int i = 0; i < count; i++) {
      final String left = preRelease[i];
      final String right = other.preRelease[i];
      final int? leftNumber = int.tryParse(left);
      final int? rightNumber = int.tryParse(right);
      final int order;
      if (leftNumber != null && rightNumber != null) {
        order = leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null) {
        // Numeric identifiers always have lower precedence than alphanumeric.
        order = -1;
      } else if (rightNumber != null) {
        order = 1;
      } else {
        order = left.compareTo(right);
      }
      if (order != 0) return order;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(preRelease));

  @override
  String toString() => normalized;
}
