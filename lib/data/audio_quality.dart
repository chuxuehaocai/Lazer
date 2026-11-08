// i18n:data — interface strings declared here are translated at their render sites.
/// The four audio tiers the player and downloader expose.
///
/// The values line up with the music provider `/song/url/v1` `level` names: requests
/// are made by level, while the gateway maps each level onto the bitrate the
/// upstream player-url endpoint understands. [fallbackChain] is used when the
/// account cannot receive the requested tier (no VIP, region lock, no FLAC
/// rendition), so playback and downloads degrade instead of failing.
enum AudioQuality { standard, higher, exhigh, lossless }

extension AudioQualityInfo on AudioQuality {
  /// Chinese source string, translated through `context.tr` where shown.
  String get label => switch (this) {
    AudioQuality.standard => '标准',
    AudioQuality.higher => '较高',
    AudioQuality.exhigh => '极高',
    AudioQuality.lossless => '无损',
  };

  String get detail => switch (this) {
    AudioQuality.standard => '128 kbps · 文件更小',
    AudioQuality.higher => '192 kbps · 兼顾体积与细节',
    AudioQuality.exhigh => '320 kbps · 推荐',
    AudioQuality.lossless => 'FLAC 无损 · 取决于音源',
  };

  /// The upstream `level` parameter.
  String get level => switch (this) {
    AudioQuality.standard => 'standard',
    AudioQuality.higher => 'higher',
    AudioQuality.exhigh => 'exhigh',
    AudioQuality.lossless => 'lossless',
  };

  /// Bitrate the gateway asks the player-url endpoint for.
  int get bitrate => switch (this) {
    AudioQuality.standard => 128000,
    AudioQuality.higher => 192000,
    AudioQuality.exhigh => 320000,
    AudioQuality.lossless => 999000,
  };

  /// Approximate bits per second used for the size estimate in the download
  /// dialog. FLAC's estimate assumes a CD-quality stream.
  int get estimatedBitrate => switch (this) {
    AudioQuality.standard => 128000,
    AudioQuality.higher => 192000,
    AudioQuality.exhigh => 320000,
    AudioQuality.lossless => 1411200,
  };

  String get bitrateLabel => switch (this) {
    AudioQuality.standard => '128 kbps',
    AudioQuality.higher => '192 kbps',
    AudioQuality.exhigh => '320 kbps',
    AudioQuality.lossless => 'FLAC',
  };

  bool get requiresVip => this == AudioQuality.lossless;

  /// Rough file size for [duration] at [estimatedBitrate].
  int estimatedBytes(Duration duration) =>
      (duration.inMilliseconds / 1000 * estimatedBitrate / 8).round();

  /// This tier followed by every lower tier, used for automatic degradation.
  List<AudioQuality> get fallbackChain => <AudioQuality>[
    this,
    for (final AudioQuality quality in AudioQuality.values.reversed)
      if (quality.index < index) quality,
  ];

  static AudioQuality parse(String? name) => AudioQuality.values.firstWhere(
    (AudioQuality quality) => quality.name == name,
    orElse: () => AudioQuality.exhigh,
  );

  /// Maps a music provider `level` string back onto a tier.
  static AudioQuality? fromLevel(String? level) {
    final String value = level?.trim().toLowerCase() ?? '';
    for (final AudioQuality quality in AudioQuality.values) {
      if (quality.level == value) return quality;
    }
    return switch (value) {
      'hires' || 'jyeffect' || 'sky' || 'jymaster' => AudioQuality.lossless,
      _ => null,
    };
  }

  /// Reads the tier from the bitrate the gateway actually returned.
  static AudioQuality? fromBitrate(int? bitrate) {
    if (bitrate == null || bitrate <= 0) return null;
    if (bitrate >= 900000) return AudioQuality.lossless;
    if (bitrate >= 256000) return AudioQuality.exhigh;
    if (bitrate >= 160000) return AudioQuality.higher;
    return AudioQuality.standard;
  }

  /// Highest tier present in [qualities].
  static AudioQuality? best(Iterable<AudioQuality> qualities) {
    AudioQuality? best;
    for (final AudioQuality quality in qualities) {
      if (best == null || quality.index > best.index) best = quality;
    }
    return best;
  }
}

/// One resolved audio stream, before it is downloaded or handed to the engine.
class AudioSource {
  const AudioSource({
    required this.url,
    required this.quality,
    this.format,
    this.bytes,
    this.headers = const {},
  });

  /// HTTP(S) or local `file:` URL.
  final String url;

  /// The tier of the rendition that was actually returned, which can be lower
  /// than the requested tier after automatic degradation.
  final AudioQuality quality;

  /// `mp3`, `flac`, `m4a`, … when the service or URL tells us.
  final String? format;

  /// Advertised file size, when the service reports it.
  final int? bytes;
  final Map<String, String> headers;
}
