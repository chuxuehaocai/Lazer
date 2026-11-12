#if canImport(WidgetKit)
import SwiftUI
import WidgetKit

private let playCountSuite = "group.dev.naominet.lazer"

struct PlayCountEntry: TimelineEntry {
  let date: Date
  let count: Int
}

struct PlayCountProvider: TimelineProvider {
  func placeholder(in context: Context) -> PlayCountEntry {
    PlayCountEntry(date: Date(), count: 0)
  }

  func getSnapshot(in context: Context, completion: @escaping (PlayCountEntry) -> Void) {
    completion(PlayCountEntry(date: Date(), count: count()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PlayCountEntry>) -> Void) {
    let entry = PlayCountEntry(date: Date(), count: count())
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
  }

  private func count() -> Int {
    UserDefaults(suiteName: playCountSuite)?.integer(forKey: "play_count") ?? 0
  }
}

struct PlayCountWidget: Widget {
  let kind = "LazerPlayCountWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: PlayCountProvider()) { entry in
      VStack(spacing: 4) {
        Text("播放次数").font(.caption).foregroundStyle(.secondary)
        Text("\(entry.count)").font(.title.bold())
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.08))
    }
    .configurationDisplayName("播放次数")
    .description("查看设备上的累计播放次数")
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
