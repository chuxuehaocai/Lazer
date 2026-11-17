// i18n:data — interface strings declared here are translated at their render sites.
/// How the end of one queue entry reaches the next one.
///
/// [off] disables cross-track preparation; playback stops and cuts cleanly into
/// the next track when complete.
/// [albumGapless] is the default: the engine is only handed the following song
/// when it belongs to the same album, so an album runs join to join without a
/// reload while a different album starts with the normal cut.
/// [autoMix] replaces that policy — every following song is prepared, so it can
/// be mixed in before the current one ends.
enum TrackTransition {
  off,
  albumGapless,
  autoMix;

  /// Reads the setting back from stored preferences with backwards compatibility.
  static TrackTransition fromStored(String? name, {bool? legacyAutoMix}) {
    if (name != null) {
      for (final value in TrackTransition.values) {
        if (value.name == name) return value;
      }
    }
    if (legacyAutoMix != null) {
      return legacyAutoMix
          ? TrackTransition.autoMix
          : TrackTransition.albumGapless;
    }
    return TrackTransition.albumGapless;
  }

  /// Reads the setting back from the stored AutoMix switch.
  static TrackTransition fromAutoMix(bool enabled) =>
      enabled ? TrackTransition.autoMix : TrackTransition.albumGapless;
}

extension TrackTransitionInfo on TrackTransition {
  /// Chinese source string, translated through `context.tr` where shown.
  String get label => switch (this) {
    TrackTransition.off => '从不生效',
    TrackTransition.albumGapless => '只对同一专辑生效',
    TrackTransition.autoMix => '对任何歌曲生效',
  };

  String get detail => switch (this) {
    TrackTransition.off => '从不生效：每首歌曲播完自然停止后，正常切入下一首',
    TrackTransition.albumGapless => '只对同一专辑生效：同一专辑内曲目 0 间隙无缝顺畅衔接，不重叠音轨',
    TrackTransition.autoMix => '对任何歌曲生效：上一首结束前平滑淡出，下一首同时淡入',
  };

  /// Whether the audio engine should overlap the following song.
  bool get mixes => this == TrackTransition.autoMix;

  /// Whether playback crosses within the same album.
  bool get gapless => this == TrackTransition.albumGapless;
}
