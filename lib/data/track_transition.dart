// i18n:data — interface strings declared here are translated at their render sites.
/// How the end of one queue entry reaches the next one.
///
/// [albumGapless] is the default: the engine is only handed the following song
/// when it belongs to the same album, so an album runs join to join without a
/// reload while a different album starts with the normal cut. [autoMix]
/// replaces that policy — every following song is prepared, so it can be mixed
/// in before the current one ends.
enum TrackTransition {
  albumGapless,
  autoMix;

  /// Reads the setting back from the stored AutoMix switch.
  static TrackTransition fromAutoMix(bool enabled) =>
      enabled ? TrackTransition.autoMix : TrackTransition.albumGapless;
}

extension TrackTransitionInfo on TrackTransition {
  /// Chinese source string, translated through `context.tr` where shown.
  String get label => switch (this) {
    TrackTransition.albumGapless => '专辑无缝播放',
    TrackTransition.autoMix => '自动混音',
  };

  String get detail => switch (this) {
    TrackTransition.albumGapless => '同一专辑的曲目之间无缝衔接，其他情况正常切歌',
    TrackTransition.autoMix => '替代专辑无缝播放：下一首在当前歌曲结束前混入',
  };

  /// Whether the audio engine should overlap the following song.
  bool get mixes => this == TrackTransition.autoMix;
}
