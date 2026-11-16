#if canImport(WidgetKit)
import SwiftUI
import UIKit
import WidgetKit

private let widgetSuite = "group.dev.naominet.lazer"

fileprivate struct RecentPlayback: Decodable {
  let title: String
  let artist: String
  let album: String
  let trackId: String
  let playing: Bool
  let hasTrack: Bool
  let language: String
  let artworkFile: String

  static let empty = RecentPlayback(title: "", artist: "", album: "", trackId: "", playing: false, hasTrack: false, language: "system", artworkFile: "")

  /// Stands in for a real song in the gallery preview and in the placeholder
  /// frame, so an empty collection never resolves to a blank card.
  static let sample = RecentPlayback(title: "Lazer", artist: "最近播放", album: "", trackId: "", playing: true, hasTrack: true, language: "system", artworkFile: "")

  private var resolvedLanguage: String {
    language == "system" ? (Locale.preferredLanguages.first ?? "en") : language
  }

  func localized(_ simplified: String, _ traditional: String, _ japanese: String, _ english: String) -> String {
    let value = resolvedLanguage.lowercased()
    if value.hasPrefix("ja") { return japanese }
    if value.hasPrefix("zh") {
      return value.contains("hant") || value.contains("tw") || value.contains("hk") || value.contains("mo") ? traditional : simplified
    }
    return english
  }

  var displayTitle: String {
    if !hasTrack { return localized("无最近播放的音乐", "無最近播放的音樂", "最近再生した音楽はありません", "No recently played music") }
    return title.isEmpty ? localized("未知曲目", "未知曲目", "不明な曲", "Unknown track") : title
  }

  var displayArtist: String {
    guard hasTrack else { return "" }
    if !artist.isEmpty { return artist }
    return album.isEmpty ? localized("未知艺术家", "未知藝人", "不明なアーティスト", "Unknown artist") : album
  }

  /// The second line of the empty state: what the listener has to do first.
  var displayHint: String {
    localized(
      "在 Lazer 播放音乐后显示",
      "在 Lazer 播放音樂後顯示",
      "Lazer で再生するとここに表示されます",
      "Play something in Lazer to see it here"
    )
  }
}

/// Reads the snapshot written by the app. Every field is optional: a snapshot
/// from an older or newer build must still render the fields it does carry,
/// instead of failing to decode and leaving the widget permanently empty.
private struct PlaybackKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

extension RecentPlayback {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: PlaybackKey.self)
    func text(_ key: String) -> String {
      let value = (try? container.decode(String.self, forKey: PlaybackKey(key))) ?? ""
      return String(value.prefix(512))
    }
    func flag(_ key: String) -> Bool {
      (try? container.decode(Bool.self, forKey: PlaybackKey(key))) ?? false
    }

    let storedTitle = text("title")
    let storedLanguage = text("language")
    self.init(
      title: storedTitle,
      artist: text("artist"),
      album: text("album"),
      trackId: text("trackId"),
      playing: flag("playing"),
      // A snapshot without an explicit flag still carries a track when it has
      // a title, which is what an older writer produced.
      hasTrack: flag("hasTrack") || !storedTitle.isEmpty,
      language: storedLanguage.isEmpty ? "system" : storedLanguage,
      artworkFile: text("artworkFile")
    )
  }
}

struct PlayCountEntry: TimelineEntry {
  let date: Date
  fileprivate let playback: RecentPlayback
  let artwork: UIImage?
}

struct PlayCountProvider: TimelineProvider {
  func placeholder(in context: Context) -> PlayCountEntry {
    // WidgetKit redraws this entry as a skeleton, but the gallery and every
    // pre-timeline frame keep the real composition: cover, icon and two lines
    // of type, never a single grey block.
    PlayCountEntry(date: Date(), playback: .sample, artwork: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (PlayCountEntry) -> Void) {
    completion(loadEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PlayCountEntry>) -> Void) {
    // The app reloads this timeline when playback changes, so no periodic
    // network fetch is needed. The half-hour retry is only a safety net: a
    // reload that never reached the widget (the app was terminated before it
    // could ask) would otherwise leave a stale or empty card until the next
    // launch, because `.never` never asks again.
    completion(
      Timeline(
        entries: [loadEntry()],
        policy: .after(Date().addingTimeInterval(1800))
      )
    )
  }

  private func loadEntry() -> PlayCountEntry {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: widgetSuite) else {
      NSLog("[LazerWidget] app group %@ unavailable; showing the empty state", widgetSuite)
      return PlayCountEntry(date: Date(), playback: .empty, artwork: nil)
    }
    guard let data = try? Data(contentsOf: container.appendingPathComponent("recent-playback.json")) else {
      NSLog("[LazerWidget] no snapshot in the shared container yet")
      return PlayCountEntry(date: Date(), playback: .empty, artwork: nil)
    }
    guard let playback = try? JSONDecoder().decode(RecentPlayback.self, from: data) else {
      NSLog("[LazerWidget] snapshot (%d bytes) could not be decoded", data.count)
      return PlayCountEntry(date: Date(), playback: .empty, artwork: nil)
    }
    var artwork: UIImage?
    if playback.hasTrack,
       playback.artworkFile.hasPrefix("recent-playback-artwork-"),
       playback.artworkFile.hasSuffix(".png"),
       !playback.artworkFile.contains("/"), !playback.artworkFile.contains("\\"),
       let imageData = try? Data(contentsOf: container.appendingPathComponent(playback.artworkFile)),
       imageData.count <= 1_048_576 {
      artwork = UIImage(data: imageData)
    }
    return PlayCountEntry(date: Date(), playback: playback, artwork: artwork)
  }
}

private struct RecentPlaybackView: View {
  let entry: PlayCountEntry
  @Environment(\.colorScheme) private var colorScheme

  private var background: Color {
    colorScheme == .dark ? Color(red: 0.105, green: 0.105, blue: 0.12) : Color(red: 0.965, green: 0.965, blue: 0.975)
  }

  private var placeholderColor: Color {
    colorScheme == .dark ? Color(red: 0.20, green: 0.20, blue: 0.23) : Color(red: 0.85, green: 0.85, blue: 0.88)
  }

  private var content: some View {
    GeometryReader { geometry in
      let coverSize = min(82, max(44, geometry.size.height * 0.48))
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          ZStack {
            placeholderColor
            if let artwork = entry.artwork {
              Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
            } else {
              // Nothing to show yet: the app mark reads as "waiting for music"
              // instead of leaving an unexplained empty tile.
              Image("LazerWidgetIcon")
                .resizable()
                .scaledToFit()
                .frame(width: coverSize * 0.52, height: coverSize * 0.52)
                .opacity(entry.playback.hasTrack ? 0.35 : 0.8)
            }
          }
          .frame(width: coverSize, height: coverSize)
          .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
          .accessibilityHidden(true)

          Spacer(minLength: 12)

          Image("LazerWidgetIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 27, height: 27)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
        }

        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: 3) {
          Text(entry.playback.displayTitle)
            .font(.custom("MiSans-Semibold", size: 15, relativeTo: .subheadline))
            .foregroundStyle(.primary)
            .lineLimit(entry.playback.hasTrack ? 1 : 2)
            .minimumScaleFactor(0.8)
          if entry.playback.hasTrack {
            Text(entry.playback.displayArtist)
              .font(.custom("MiSans-Regular", size: 12, relativeTo: .caption))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } else {
            // An empty widget must explain itself: the title alone read as a
            // broken card on the home screen.
            Text(entry.playback.displayHint)
              .font(.custom("MiSans-Regular", size: 12, relativeTo: .caption))
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  var body: some View {
    if #available(iOS 17.0, *) {
      // WidgetKit supplies the system content margins and owns the background.
      content.containerBackground(for: .widget) { background }
    } else {
      // Before iOS 17 widgets do not receive automatic content margins.
      content.padding(16).background(background)
    }
  }
}

struct PlayCountWidget: Widget {
  // Preserve the kind and extension identity so installed widgets upgrade in place.
  let kind = "LazerPlayCountWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: PlayCountProvider()) { entry in
      RecentPlaybackView(entry: entry)
    }
    .configurationDisplayName(LocalizedStringKey("widget_recent_playback"))
    .description(LocalizedStringKey("widget_recent_description"))
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct LazerPlayCountWidgetBundle: WidgetBundle {
  var body: some Widget {
    PlayCountWidget()
  }
}
#endif
