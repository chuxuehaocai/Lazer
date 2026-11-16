import Foundation

/// The App Group the app and the widget extension share.
///
/// Read from the bundle's `Info.plist` rather than hardcoded, because the value a
/// re-signed install needs is *not* the one this repository was built with: App
/// Groups are registered per team, so a sideload that keeps `dev.naominet.lazer`
/// on a different team cannot create or join `group.dev.naominet.lazer` at all.
/// A plist string is something a re-signing step can rewrite without an Xcode
/// build, which a Swift literal is not.
///
/// `LAZER_APP_GROUP_IDENTIFIER` in `ios/Flutter/LazerAppGroup.xcconfig` supplies
/// the default this repo ships with.
enum LazerAppGroup {
  /// The configured group, or the fallback when the key is missing.
  ///
  /// A missing key means the bundle was built before this setting existed, so the
  /// original identifier is the only value that can be meant.
  static var identifier: String {
    let configured = Bundle.main.object(
      forInfoDictionaryKey: "LazerAppGroupIdentifier"
    ) as? String
    let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallbackIdentifier : trimmed
  }

  /// What this repository builds with.
  static let fallbackIdentifier = "group.dev.naominet.lazer"
}
