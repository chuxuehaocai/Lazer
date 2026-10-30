// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/audio_engine.dart';
import '../audio/hifi_controller.dart';
import '../diagnostics/build_info.dart';
import '../downloads/download_manager.dart';
import '../interaction/app_haptics.dart';
import '../data/audio_quality.dart';
import '../data/catalog.dart';
import '../data/lyrics.dart';
import '../local/local_library.dart';
import '../local/coalescing_writer.dart';
import '../scrolling/scroll_motion.dart';
import '../l10n/app_language.dart';
import '../data/models.dart';
import '../gateway/gateway.dart';
import '../gateway/transport.dart';
import '../lyrics/imported_lyrics_store.dart';
import '../updates/release_version.dart';
import '../updates/update_checker.dart';
import '../utils/background_image.dart';
import '../legacy/legacy_background.dart' show albumSeedForCover;
import 'build_safe_notifier.dart';
import 'listen_together.dart';
import 'media_shortcuts.dart';
import 'playback_queue_store.dart';
import 'hifi_settings.dart';
import 'ui_preferences.dart';
import '../theme/font_preferences.dart';

part 'music_platform_state.dart';

/// How the session was authenticated.
enum AuthMethod { qrcode, sms, password, cookie }

/// Immutable snapshot of the signed-in user.
class SessionUser {
  const SessionUser({
    required this.name,
    required this.handle,
    required this.method,
    required this.detail,
    this.userId = 0,
    this.avatarUrl,
    this.signature,
    this.vipType,
  });

  /// The default session: the app boots straight into the shell with this
  /// guest — no gate, no credentials. Signing in is optional, from the
  /// user card or the settings sheet.
  static const SessionUser guest = SessionUser(
    name: '游客',
    handle: '@guest',
    method: AuthMethod.cookie,
    detail: '未登录',
  );

  final String name;
  final String handle;
  final AuthMethod method;

  /// Human-readable credential detail, e.g. masked phone number.
  final String detail;
  final int userId;

  /// Profile avatar, when the gateway returned one.
  final String? avatarUrl;

  /// The user's profile signature ("个人简介").
  final String? signature;

  /// Raw NetEase VIP tier (0 = none).
  final int? vipType;

  bool get isGuest => handle == '@guest';

  /// Membership badge text for the profile header; null when not a VIP.
  String? get vipLabel {
    final int type = vipType ?? 0;
    if (isGuest || type <= 0) return null;
    return '黑胶会员';
  }

  String get methodLabel => isGuest
      ? '游客模式'
      : switch (method) {
          AuthMethod.qrcode => '二维码登录',
          AuthMethod.sms => '短信验证码登录',
          AuthMethod.password => '密码登录',
          AuthMethod.cookie => 'Cookie 登录',
        };

  factory SessionUser.fromProfile(
    GatewayUserProfile profile, {
    required AuthMethod method,
    required String detail,
  }) {
    return SessionUser(
      name: profile.nickname.isEmpty ? '乐迷' : profile.nickname,
      handle: '@${profile.userId}',
      method: method,
      detail: detail,
      userId: profile.userId,
      avatarUrl: profile.avatarUrl,
      signature: profile.signature,
      vipType: profile.vipType,
    );
  }
}

/// Outcome of a sign-in attempt; [error] is user-facing.
class AuthOutcome {
  const AuthOutcome(this.ok, {this.error});

  final bool ok;
  final String? error;
}

/// Single source of truth: session (real gateway) + playback engine.
///
/// Playback uses a real [AudioEngine] and stream URL from the gateway.
class AppState extends ChangeNotifier with BuildSafeNotifier {
  AppState({
    Catalog? catalog,
    LocalLibrary? localLibrary,
    DownloadManager? downloadManager,
    ImportedLyricsStore? importedLyrics,
    PlaybackQueueStore? queueStore,
    UpdateChecker? updateChecker,
    this.audioEngine,
    this._independentPlayback = false,
    this.enableExternalCharts = false,
    this.deviceIsTelevision = false,
    this.hifiSettings = const HifiSettings(),
    this.hifi,
    this.artworkSeedLoader = albumSeedForCover,
    this.navidromeFactory,
  }) : catalog = catalog ?? Catalog(),
       localLibrary = localLibrary ?? LocalLibrary(),
       _queueStore = queueStore ?? PlaybackQueueStore(),
       updateChecker = updateChecker ?? UpdateChecker() {
    this.importedLyrics = importedLyrics ?? ImportedLyricsStore();
    this.downloadManager =
        downloadManager ??
        DownloadManager(catalog: this.catalog, library: this.localLibrary);
    _ownsDownloadManager = downloadManager == null;
    _completionSubscription = audioEngine?.completed.listen(
      (_) => _onEngineCompleted(),
    );
    // An engine that can hold a queue hands the next track over without a
    // reload; that hand-off arrives as an index change, never as a completion.
    _indexSubscription = _queueEngine?.indexStream.listen(_onEngineAdvanced);
    // Terminal failures of the native engine (device lost, decode error) have no
    // throw site to reach the load path, so they arrive here instead.
    final AudioEngine? engine = audioEngine;
    _failureSubscription = engine is FailureReportingAudioEngine
        ? (engine as FailureReportingAudioEngine).failures.listen(
            _onEngineFailure,
          )
        : null;
    _bufferSubscription = engine is BufferChangeReportingAudioEngine
        ? (engine as BufferChangeReportingAudioEngine).bufferChanges.listen(
            (_) => _onBufferChanged(),
          )
        : null;
  }

  /// HiFi output settings: device, exclusive/bit-perfect policy, DSD mode, buffer,
  /// and the equaliser. Applied to the native engine by [hifi].
  HifiSettings hifiSettings;

  /// Owns applying those settings; null when the app runs on `just_audio`.
  final HifiController? hifi;

  /// Persists the HiFi settings; a single writer so a value the engine refused is
  /// not stored as if it had taken effect.
  Future<void> setHifiSettings(HifiSettings next) async {
    if (next == hifiSettings) return;
    hifiSettings = next;
    notifyListeners();
    // Keep the controller's copy in sync and push live DSP settings to the
    // native engine. Without this, the settings page only changed AppState and
    // SharedPreferences; EQ and crossfeed never reached the audio thread.
    final HifiController? controller = hifi;
    if (controller != null) {
      await controller.update(next);
      return;
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final MapEntry<String, Object?> entry in next.toMap().entries) {
      final Object? value = entry.value;
      if (value == null) {
        await prefs.remove(entry.key);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else {
        await prefs.setString(entry.key, '$value');
      }
    }
  }

  bool _independentPlayback;
  final bool enableExternalCharts;
  bool get independentPlayback => _independentPlayback;

  /// Whether the Android device under this app is a television.
  ///
  /// Detected natively before the first frame (Leanback / `UI_MODE_TYPE_
  /// TELEVISION` / no touch screen). It selects the television profile in
  /// automatic mode and turns every tap target into a D-pad focus stop.
  final bool deviceIsTelevision;

  /// Finds newer GitHub releases for this build.
  final UpdateChecker updateChecker;

  /// How often a launch may ask GitHub for a new release. A daily cadence
  /// keeps the unauthenticated API comfortably inside its rate limit and
  /// avoids a network round trip on every start.
  static const Duration updateCheckInterval = Duration(hours: 24);

  /// Whether a release check is in flight.
  bool updateChecking = false;

  /// Why the last check failed, if it did. Cleared when a new check starts.
  String? updateError;

  /// The normalised version the user asked not to be reminded about again.
  String? skippedUpdateVersion;

  /// When the last successful check happened, in milliseconds since epoch.
  int updateCheckedAt = 0;

  /// Whether an automatic check is due for [now].
  bool autoUpdateCheckDue({DateTime? now}) {
    final DateTime moment = now ?? DateTime.now();
    if (updateCheckedAt <= 0) return true;
    return moment.millisecondsSinceEpoch - updateCheckedAt >=
        updateCheckInterval.inMilliseconds;
  }

  /// Asks GitHub for a newer release.
  ///
  /// Returns null when the build is current, when an automatic check is not
  /// due, when the newest release was skipped, or when the network failed
  /// ([updateError] then says why). A [manual] check ignores both the daily
  /// cadence and a previous skip, because the user explicitly asked.
  Future<AppRelease?> checkForUpdates({bool manual = false}) async {
    if (updateChecking) return null;
    if (!manual && !autoUpdateCheckDue()) return null;
    final ReleaseVersion? current = ReleaseVersion.parse(BuildInfo.version);
    if (current == null) {
      updateError = 'unsupported current version';
      notifyListeners();
      return null;
    }
    updateChecking = true;
    updateError = null;
    notifyListeners();
    try {
      final AppRelease? release = await updateChecker.findUpdate(
        current,
        includePrerelease: current.isPreRelease,
      );
      updateCheckedAt = DateTime.now().millisecondsSinceEpoch;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt('lazer_update_checked_at', updateCheckedAt);
      if (release == null) return null;
      final String? skipped = skippedUpdateVersion;
      if (!manual && skipped != null && release.version.normalized == skipped) {
        return null;
      }
      return release;
    } catch (error) {
      updateError = '$error';
      return null;
    } finally {
      updateChecking = false;
      notifyListeners();
    }
  }

  /// Stops automatic reminders for [release]; a later release still prompts.
  Future<void> skipUpdate(AppRelease release) async {
    skippedUpdateVersion = release.version.normalized;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('lazer_skipped_update', skippedUpdateVersion!);
  }

  /// Clears a previous skip, so the next automatic check prompts again.
  Future<void> clearSkippedUpdate() async {
    if (skippedUpdateVersion == null) return;
    skippedUpdateVersion = null;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('lazer_skipped_update');
  }

  /// Downloaded and scanned files, shared by playback, downloads and the
  /// library page.
  final LocalLibrary localLibrary;

  /// Download queue. Owned by this state unless a test injects one.
  late final DownloadManager downloadManager;
  late final bool _ownsDownloadManager;

  /// Imported `.lrc` files, which take priority over cloud lyrics.
  late final ImportedLyricsStore importedLyrics;

  Future<void> setIndependentPlayback(bool value) async {
    if (_independentPlayback == value) return;
    _independentPlayback = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_independent_playback', _independentPlayback);
  }

  /// Tier requested for streaming. Changing it while a track is loaded reloads
  /// that track at the new tier and keeps its position.
  AudioQuality playbackQuality = AudioQuality.exhigh;

  /// Tier preselected by the download dialog.
  AudioQuality downloadQuality = AudioQuality.exhigh;

  /// Last directory the download picker returned, used as its start folder.
  String? downloadDirectory;

  Future<void> setPlaybackQuality(AudioQuality value) async {
    if (playbackQuality == value) return;
    playbackQuality = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_playback_quality',
      value.name,
    );
    if (_realActive && current != null) {
      unawaited(_reloadForQuality(_position));
    }
  }

  Future<void> setDownloadQuality(AudioQuality value) async {
    if (downloadQuality == value) return;
    downloadQuality = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_download_quality',
      value.name,
    );
  }

  Future<void> setDownloadDirectory(String? value) async {
    final String? normalized = value == null || value.trim().isEmpty
        ? null
        : value.trim();
    if (downloadDirectory == normalized) return;
    downloadDirectory = normalized;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (normalized == null) {
      await prefs.remove('lazer_download_directory');
    } else {
      await prefs.setString('lazer_download_directory', normalized);
    }
  }

  Future<void> _reloadForQuality(Duration position) async {
    await _startAudio(resumeAt: position);
  }

  static const String _sessionKey = 'lazer_gateway_cookie';

  static const String _recentTracksKey = 'lazer_recent_tracks_v1';
  static const int _recentTracksLimit = 60;

  final Catalog catalog;
  final NavidromeGateway Function(
    String server,
    String username,
    bool allowHttp,
  )?
  navidromeFactory;
  late final _MusicPlatformState _musicPlatforms = _MusicPlatformState(this);
  MusicProvider get musicProvider => catalog.activeGateway.provider;
  String get activeConnectionKey =>
      GatewayRegistry.keyOf(catalog.activeGateway);
  bool get isNavidrome => musicProvider.id == 'navidrome';
  String audioQualityLabel(AudioQuality value) =>
      isNavidrome && value == AudioQuality.lossless ? '原始音质' : value.label;
  String audioQualityDetail(AudioQuality value) =>
      isNavidrome && value == AudioQuality.lossless
      ? '服务器原始文件，不转码'
      : value.detail;
  String audioQualityBitrate(AudioQuality value) =>
      isNavidrome && value == AudioQuality.lossless
      ? '原始格式'
      : value.bitrateLabel;
  List<MusicGateway> get musicConnections => catalog.connections.connections;
  bool get platformChanging => _musicPlatforms.busy;
  bool supportsMusic(MusicCapability capability) =>
      catalog.activeGateway.supports(capability);
  Future<AuthOutcome> signInWithNavidrome({
    required String serverUrl,
    required String username,
    required String password,
    bool allowInsecureHttp = false,
  }) => _musicPlatforms.login(serverUrl, username, password, allowInsecureHttp);
  Future<void> selectMusicConnection(String key) => _musicPlatforms.select(key);
  late final ListenTogetherController listenTogether = ListenTogetherController(
    state: this,
  );
  StreamSubscription<void>? _completionSubscription;
  StreamSubscription<void>? _bufferSubscription;
  StreamSubscription<int>? _indexSubscription;
  StreamSubscription<String>? _failureSubscription;
  Timer? _bufferPulseTimer;
  static const playbackInterval = Duration(milliseconds: 100);
  bool hapticsEnabled = true;
  final AppHaptics haptics = AppHaptics();
  Future<void> feedback({bool detent = false, bool boundary = false}) =>
      haptics.pulse(
        enabled: hapticsEnabled,
        intensity: hapticIntensity,
        detent: detent,
        boundary: boundary,
      );
  double hapticIntensity = 0.5;
  ThemeMode themeMode = ThemeMode.system;
  double _volume = 1;
  double _unmutedVolume = 1;
  double get volume => _volume;

  Future<void> setVolume(double value) async {
    if (!value.isFinite) return;
    _volume = value.clamp(0, 1);
    if (_volume > 0) _unmutedVolume = _volume;
    notifyListeners();
    await audioEngine?.setVolume(_volume);
    // Persist the latest value even when several drag updates are in flight.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_volume', _volume);
    await prefs.setDouble('lazer_unmuted_volume', _unmutedVolume);
  }

  /// Live volume change for a drag in progress: updates the engine and the
  /// in-memory value without notifying the whole shell or touching prefs.
  /// Callers persist once on release with [setVolume].
  void previewVolume(double value) {
    if (!value.isFinite) return;
    _volume = value.clamp(0, 1);
    if (_volume > 0) _unmutedVolume = _volume;
    unawaited(audioEngine?.setVolume(_volume) ?? Future<void>.value());
  }

  Future<void> toggleMute() => setVolume(_volume > 0 ? 0 : _unmutedVolume);

  /// Relative volume step used by the keyboard shortcuts.
  Future<void> adjustVolume(double delta) => setVolume(_volume + delta);

  Future<void> setHapticIntensity(double value) async {
    hapticIntensity = value.clamp(0, 1);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_haptic_intensity',
      hapticIntensity,
    );
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_theme_mode',
      value.name,
    );
  }

  AppLanguage language = AppLanguage.system;
  Future<void> setLanguage(AppLanguage value) async {
    language = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_language',
      value.code,
    );
  }

  // -- interface ------------------------------------------------------------

  /// Which presentation the shell forces; [AppUiMode.auto] follows the width.
  AppUiMode uiMode = AppUiMode.auto;

  /// Which device form the density is tuned for; [AppSurface.auto] recognises
  /// a car head unit from the platform.
  AppSurface surface = AppSurface.auto;

  /// Manual interface scale, used while [autoDpiScale] is off.
  double dpiScale = kDpiScaleDefault;

  /// Whether the interface scale is derived from the window instead of
  /// [dpiScale].
  bool autoDpiScale = true;

  Future<void> setUiMode(AppUiMode value) async {
    if (uiMode == value) return;
    uiMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_ui_mode',
      value.name,
    );
  }

  /// How many playlist cards the library draws per row. `0` follows the
  /// window width; a fixed count is the listener's own arrangement.
  int playlistColumns = 0;

  /// Applies a 歌单排列 choice.
  Future<void> setPlaylistColumns(int value) async {
    final int next = value.clamp(0, kPlaylistColumnsMax);
    if (playlistColumns == next) return;
    playlistColumns = next;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      'lazer_playlist_columns',
      next,
    );
  }

  /// The listener's own order for the library playlists, as playlist ids.
  ///
  /// Ids the list does not mention keep their catalogue order behind the
  /// arranged ones, so a fresh subscription still shows up and a playlist
  /// removed on another device never leaves a hole.
  List<String> playlistOrder = const <String>[];
  late final CoalescingWriter _playlistOrderWriter = CoalescingWriter(() async {
    final snapshot = playlistOrder.join('\n');
    await (await SharedPreferences.getInstance()).setString(
      'lazer_playlist_order',
      snapshot,
    );
  });

  /// Stores the order the library was dragged into.
  Future<void> setPlaylistOrder(List<String> order) async {
    final List<String> next = List<String>.unmodifiable(<String>{
      for (final String id in order)
        if (id.isNotEmpty) id,
    });
    if (listEquals(playlistOrder, next)) return;
    playlistOrder = next;
    notifyListeners();
    await _playlistOrderWriter.request();
  }

  /// Legacy shell backdrop: the album-coloured flowing canvas, the listener's
  /// own picture, or off.
  LegacyBackgroundMode legacyBackground =
      LegacyBackgroundMode.nowPlayingDynamic;

  /// Stored copy of the picture used by [LegacyBackgroundMode.customImage].
  /// Null until the listener picks one; the canvas still renders without it.
  String? legacyBackgroundImagePath;

  /// `内容不透明度` of the legacy shell — how much of the backdrop the content
  /// veil hides.
  double legacyUiAlpha = 0.7;
  double browseBackgroundFps = 30;
  double playerBackgroundFps = 0;
  LegacyBackgroundMode playerBackground =
      LegacyBackgroundMode.nowPlayingDynamic;
  Color? browseBackgroundColor, playerBackgroundColor;
  String? playerBackgroundImagePath;

  Future<void> setBackgroundFps(double fps, {bool player = false}) async {
    if (!fps.isFinite) return;
    final double value = player && fps == 0
        ? 0
        : fps.clamp(10, 1000).roundToDouble();
    if (player) {
      playerBackgroundFps = value;
    } else {
      browseBackgroundFps = value;
    }
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      player ? 'lazer_player_background_fps' : 'lazer_browse_background_fps',
      value,
    );
  }

  Future<void> setPlayerBackground(LegacyBackgroundMode mode) async {
    playerBackground = mode;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_player_background',
      mode.name,
    );
  }

  Future<void> setBackgroundColor(Color? color, {bool player = false}) async {
    if (player) {
      playerBackgroundColor = color;
    } else {
      browseBackgroundColor = color;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final key = player
        ? 'lazer_player_background_color'
        : 'lazer_browse_background_color';
    if (color == null) {
      await prefs.remove(key);
    } else {
      await prefs.setInt(key, color.toARGB32());
    }
  }

  Future<void> setPlayerBackgroundImage(String? path) async {
    playerBackgroundImagePath = path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove('lazer_player_background_image');
    } else {
      await prefs.setString(
        'lazer_player_background_image',
        backgroundImageStore.preferenceValue(path),
      );
    }
  }

  Future<void> setLegacyBackground(LegacyBackgroundMode value) async {
    if (legacyBackground == value) return;
    legacyBackground = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_legacy_background',
      value.name,
    );
  }

  Future<void> setLegacyBackgroundImage(String? path) async {
    if (legacyBackgroundImagePath == path) return;
    legacyBackgroundImagePath = path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove('lazer_legacy_background_image');
    } else {
      // Persist the name, not the sandbox path: iOS may move the container
      // between launches. See [BackgroundImageStore].
      await prefs.setString(
        'lazer_legacy_background_image',
        backgroundImageStore.preferenceValue(path),
      );
    }
  }

  Future<void> setLegacyUiAlpha(double value) async {
    if (!value.isFinite) return;
    legacyUiAlpha = value.clamp(0.4, 1.0);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_legacy_ui_alpha',
      legacyUiAlpha,
    );
  }

  /// Keyboard combinations that control playback. A null value disables the
  /// action; actions missing from the map keep their default binding.
  Map<MediaShortcutAction, MediaShortcutBinding?> mediaShortcuts =
      MediaShortcutSettings.defaults();

  MediaShortcutBinding? mediaShortcutFor(MediaShortcutAction action) =>
      mediaShortcuts[action];

  Future<void> setMediaShortcut(
    MediaShortcutAction action,
    MediaShortcutBinding? binding,
  ) async {
    if (mediaShortcuts[action] == binding) return;
    mediaShortcuts = <MediaShortcutAction, MediaShortcutBinding?>{
      ...mediaShortcuts,
      action: binding,
    };
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_media_shortcuts',
      MediaShortcutSettings.encode(mediaShortcuts),
    );
  }

  Future<void> resetMediaShortcuts() async {
    mediaShortcuts = MediaShortcutSettings.defaults();
    notifyListeners();
    await (await SharedPreferences.getInstance()).remove(
      'lazer_media_shortcuts',
    );
  }

  /// `动态背景渲染精度` — how dense and how often the flowing album canvas is
  /// redrawn, 0.1 … 1.0. It is the one knob a slow GPU needs: at 1.0 the mesh
  /// paints 551 warped vertices thirty times a second.
  double dynamicBackgroundQuality = kDynamicBackgroundQualityDefault;
  double playerBackgroundQuality = kDynamicBackgroundQualityDefault;

  Future<void> setPlayerBackgroundQuality(double value) async {
    final next = normalizeDynamicBackgroundQuality(value);
    if (playerBackgroundQuality == next) return;
    playerBackgroundQuality = next;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_player_background_quality',
      next,
    );
  }

  /// Applies a precision setting, snapped to the slider grid and clamped to
  /// the supported range.
  Future<void> setDynamicBackgroundQuality(double value) async {
    final double next = normalizeDynamicBackgroundQuality(value);
    if (dynamicBackgroundQuality == next) return;
    dynamicBackgroundQuality = next;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_dynamic_background_quality',
      next,
    );
  }

  /// Restores the tuned default.
  Future<void> resetDynamicBackgroundQuality() =>
      setDynamicBackgroundQuality(kDynamicBackgroundQualityDefault);

  Future<void> setSurface(AppSurface value) async {
    if (surface == value) return;
    surface = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_surface',
      value.name,
    );
  }

  /// Pins a manual scale. Dragging the slider is an explicit choice, so it
  /// turns the automatic mode off; [setAutoDpiScale] can turn it back on.
  Future<void> setDpiScale(double value) async {
    final double next = normalizeDpiScale(value);
    if (dpiScale == next && !autoDpiScale) return;
    dpiScale = next;
    autoDpiScale = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_dpi_scale', next);
    await prefs.setBool('lazer_auto_dpi_scale', false);
  }

  Future<void> setAutoDpiScale(bool value) async {
    if (autoDpiScale == value) return;
    autoDpiScale = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_auto_dpi_scale',
      value,
    );
  }

  /// Back to the shipped behaviour: automatic scale, 100% manual fallback.
  Future<void> resetDpiScale() async {
    autoDpiScale = true;
    dpiScale = kDpiScaleDefault;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_auto_dpi_scale', true);
    await prefs.setDouble('lazer_dpi_scale', kDpiScaleDefault);
  }

  double lyricControlsSeconds = 1.5;
  bool lyricBlurEnabled = true;
  bool showFrameStats = const bool.fromEnvironment('LAZER_FRAME_STATS');

  /// Hidden developer switches. They stay out of the settings list until the
  /// version card in 关于 is tapped repeatedly, so ordinary users never see
  /// the frame overlay or the audio-device dump.
  bool debugOptionsEnabled = false;

  Future<void> setDebugOptionsEnabled(bool value) async {
    if (debugOptionsEnabled == value) return;
    debugOptionsEnabled = value;
    // The switch that turns the overlay back off disappears with the debug
    // section, so never leave it running behind closed doors.
    if (!value) showFrameStats = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_debug_options', value);
    if (!value) await prefs.setBool('lazer_show_frame_stats', false);
  }

  double lyricFontSize = 22;
  int lyricFontWeight = 600;
  FontPreferences fontPreferences = const FontPreferences();
  final ValueNotifier<bool> playerPresented = ValueNotifier(false);
  final ValueNotifier<bool> browseTransitionActive = ValueNotifier(false);
  int _playerPresentations = 0;
  bool _presentationDisposed = false;

  void playerPresentationChanged(bool entered) {
    if (_presentationDisposed) return;
    _playerPresentations += entered ? 1 : -1;
    if (_playerPresentations < 0) _playerPresentations = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_presentationDisposed) {
        playerPresented.value = _playerPresentations > 0;
      }
    });
  }

  void browseTransitionChanged(bool moving) {
    if (_presentationDisposed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_presentationDisposed) browseTransitionActive.value = moving;
    });
  }

  final Future<Color?> Function(String?) artworkSeedLoader;
  int _paletteGeneration = 0;
  (String?, String?)? _paletteIdentity;

  Future<void> refreshArtworkSeed() async {
    final Track? track = current;
    final identity = (track?.id, track?.coverUrl);
    if (_paletteIdentity == identity) return;
    _paletteIdentity = identity;
    final int generation = ++_paletteGeneration;
    try {
      final seed = await artworkSeedLoader(track?.coverUrl);
      if (generation == _paletteGeneration &&
          current?.id == track?.id &&
          current?.coverUrl == track?.coverUrl) {
        setLegacySeed(seed);
      }
    } catch (_) {
      if (generation == _paletteGeneration) setLegacySeed(null);
    }
  }

  bool showArtworkWithLyrics = false;
  String? importedEnginePath;

  Future<void> setImportedEnginePath(String? path) async {
    importedEnginePath = path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove('lazer_native_engine_path');
    } else {
      await prefs.setString('lazer_native_engine_path', path);
    }
  }

  Future<void> setFontCustomization(
    FontCategory category,
    FontCustomization? value,
  ) async {
    final normalized = value == null
        ? null
        : FontCustomization(
            scale: FontCustomization.normalizeScale(value.scale),
            weight: value.weight == null
                ? null
                : FontCustomization.normalizeWeight(value.weight!),
          );
    if (fontPreferences[category] ==
        (normalized ?? const FontCustomization())) {
      return;
    }
    fontPreferences = fontPreferences.update(category, normalized);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_font_preferences',
      fontPreferences.encode(),
    );
  }

  Future<void> resetFonts() async {
    fontPreferences = const FontPreferences();
    lyricFontSize = 22;
    lyricFontWeight = 600;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lazer_font_preferences');
    await prefs.remove('lazer_lyric_font_size');
    await prefs.remove('lazer_lyric_font_weight');
  }

  Future<void> setShowArtworkWithLyrics(bool value) async {
    if (showArtworkWithLyrics == value) return;
    showArtworkWithLyrics = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_show_artwork_with_lyrics',
      value,
    );
  }

  static int normalizeLyricWeight(int value) =>
      (value.clamp(400, 700) / 100).round() * 100;

  Future<void> setShowFrameStats(bool value) async {
    if (showFrameStats == value) return;
    showFrameStats = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_show_frame_stats',
      value,
    );
  }

  /// The legacy shell's accent palette: the fixed Lazer scheme, one seeded
  /// from the current cover like the app's "follow the song" palette, or the
  /// listener's own colour.
  LegacyPaletteMode legacyPalette = LegacyPaletteMode.fixed;

  /// The accent picked in [LegacyPaletteMode.custom]; null until the listener
  /// chooses one, in which case the shipped red remains in effect.
  Color? legacyAccentColor;

  /// The last artwork seed the legacy backdrop extracted; only used while
  /// [legacyPalette] is [LegacyPaletteMode.nowPlaying].
  Color? legacySeed;

  /// The accent seed handed to the Apple theme builders. Null keeps the
  /// shipped Apple Music red.
  Color? get legacyAccentSeed => switch (legacyPalette) {
    LegacyPaletteMode.fixed => null,
    LegacyPaletteMode.nowPlaying => legacySeed,
    LegacyPaletteMode.custom => legacyAccentColor,
  };

  Future<void> setLegacyPalette(LegacyPaletteMode value) async {
    if (legacyPalette == value) return;
    legacyPalette = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_legacy_palette',
      value.name,
    );
  }

  Future<void> setLegacyAccent(Color value) async {
    if (legacyAccentColor == value) return;
    legacyAccentColor = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      'lazer_legacy_accent',
      value.toARGB32(),
    );
  }

  void setLegacySeed(Color? value) {
    if (legacySeed == value) return;
    legacySeed = value;
    // The fixed palette does not consume the seed; rebuilding the whole shell
    // for it on every track change was pure work.
    if (legacyPalette == LegacyPaletteMode.nowPlaying) notifyListeners();
  }

  Future<void> setLyricFontSize(double value) async {
    if (!value.isFinite) return;
    lyricFontSize = value.clamp(14, 40);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_lyric_font_size',
      lyricFontSize,
    );
  }

  Future<void> setLyricFontWeight(int value) async {
    lyricFontWeight = normalizeLyricWeight(value);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      'lazer_lyric_font_weight',
      lyricFontWeight,
    );
  }

  double scrollRetention = ScrollMotion.defaultRetention;
  double scrollAcceleration = ScrollMotion.defaultAcceleration;

  Future<void> setScrollAcceleration(double value) async {
    if (!value.isFinite) return;
    scrollAcceleration = value.clamp(
      ScrollMotion.minAcceleration,
      ScrollMotion.maxAcceleration,
    );
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_scroll_acceleration',
      scrollAcceleration,
    );
  }

  double lyricResumeSeconds = 2;

  Future<void> setLyricBlurEnabled(bool value) async {
    lyricBlurEnabled = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_lyric_blur',
      value,
    );
  }

  Future<void> setScrollRetention(double value) async {
    scrollRetention = value.clamp(
      ScrollMotion.minRetention,
      ScrollMotion.maxRetention,
    );
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_scroll_retention',
      scrollRetention,
    );
  }

  Future<void> setLyricResumeSeconds(double value) async {
    lyricResumeSeconds = value.clamp(1, 10);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_lyric_resume_seconds',
      lyricResumeSeconds,
    );
  }

  Future<void> setHapticsEnabled(bool value) async {
    hapticsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_haptics', value);
  }

  Future<void> setLyricControlsSeconds(double value) async {
    lyricControlsSeconds = value.clamp(1, 10);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_lyric_controls_seconds', lyricControlsSeconds);
  }

  /// Real playback engine (just_audio in the app).
  final AudioEngine? audioEngine;

  /// The engine's queue capability, when it has one.
  ///
  /// Present only for engines that can cross a track boundary without a
  /// reload; everything else keeps the completion-driven, one-URL-at-a-time
  /// path in [_startAudio].
  QueueAudioEngine? get _queueEngine {
    final AudioEngine? engine = audioEngine;
    // The two interfaces are unrelated, so `is` cannot promote the field type.
    return engine is QueueAudioEngine ? engine as QueueAudioEngine : null;
  }

  /// Live home feed once [bootstrap] loaded it.
  HomeFeed? get home => catalog.home;
  String? get homeError => catalog.homeError;
  List<MusicChart> discoveryCharts = const <MusicChart>[];
  bool discoveryChartsLoading = false;
  String? discoveryChartsError;
  String? playbackError;
  UserCollections collections = UserCollections.empty;
  bool collectionsLoading = false;
  String? collectionsError;
  Future<void>? _collectionsPending;

  /// All-time play counts, joined with song durations for 听歌排行.
  List<TrackPlayStat> playStats = const <TrackPlayStat>[];
  bool playStatsLoading = false;
  String? playStatsError;
  int? _playStatsUid;

  /// Loads the play record once per account. The library asks for it lazily;
  /// a guest never issues the request.
  Future<void> loadPlayStats({bool force = false}) async {
    if (isNavidrome) return;
    final int uid = user.userId;
    if (uid <= 0) {
      playStats = const <TrackPlayStat>[];
      playStatsError = null;
      return;
    }
    if (playStatsLoading) return;
    if (!force && _playStatsUid == uid && playStats.isNotEmpty) return;
    _playStatsUid = uid;
    playStatsLoading = true;
    playStatsError = null;
    notifyListeners();
    try {
      // Push anything queued offline before reading the record back, so the
      // counts the library shows include this device's latest plays.
      await _flushPlayUploads();
      final List<TrackPlayStat> loaded = await catalog.playStats(
        uid,
        force: force,
      );
      if (user.userId != uid) return;
      playStats = loaded;
    } catch (_) {
      if (user.userId == uid) {
        playStatsError = '播放记录加载失败，请稍后重试。'; // i18n:key
      }
    } finally {
      if (user.userId == uid) {
        playStatsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshCollections({bool force = false}) {
    if (_presentationDisposed) return Future<void>.value();
    final int uid = user.userId;
    if (uid <= 0) {
      collections = UserCollections.empty;
      collectionsError = null;
      return Future<void>.value();
    }
    final Future<void>? pending = _collectionsPending;
    if (pending != null) {
      // A forced refresh must never be answered by a request that started
      // before the mutation. Wait for it, then read again so an awaited
      // `refreshCollections(force: true)` observes the change itself.
      return force
          ? pending.then((_) => refreshCollections(force: true))
          : pending;
    }
    final Future<void> run = _refreshCollections(uid, force: force);
    late final Future<void> tracked;
    tracked = run.whenComplete(() {
      if (identical(_collectionsPending, tracked)) _collectionsPending = null;
    });
    _collectionsPending = tracked;
    return tracked;
  }

  Future<void> _refreshCollections(int uid, {required bool force}) async {
    if (_presentationDisposed) return;
    final connection = activeConnectionKey;
    collectionsLoading = true;
    collectionsError = null;
    notifyListeners();
    try {
      if (force) {
        await catalog.invalidateCollections(uid);
      } else if (collections.liked == null &&
          collections.created.isEmpty &&
          collections.subscribed.isEmpty) {
        // Paint the last stored library before the network answers. A cold
        // start or a blocked request then still opens 资料库 with content
        // instead of an empty page and a spinner.
        final UserCollections? stored = await catalog.cachedUserCollections(
          uid,
        );
        if (!_presentationDisposed &&
            stored != null &&
            user.userId == uid &&
            activeConnectionKey == connection) {
          collections = stored;
          notifyListeners();
        }
      }
      final loaded = await catalog.userCollections(uid);
      if (!_presentationDisposed &&
          user.userId == uid &&
          activeConnectionKey == connection) {
        collections = loaded;
        if (isNavidrome) {
          _musicPlatforms.liked
            ..clear()
            ..addAll(loaded.liked?.trackIds ?? const []);
        }
      }
    } catch (_) {
      if (!_presentationDisposed &&
          user.userId == uid &&
          activeConnectionKey == connection) {
        collectionsError = '歌单读取失败，请重试。';
      }
    } finally {
      if (!_presentationDisposed &&
          user.userId == uid &&
          activeConnectionKey == connection) {
        collectionsLoading = false;
        notifyListeners();
      }
    }
  }

  void clearPlaybackError() {
    playbackError = null;
    notifyListeners();
  }

  List<LyricLine> lyrics = const <LyricLine>[];
  String? lyricsError;
  bool lyricsLoading = false;
  bool lyricsPureMusic = false;

  /// True when the displayed lyrics came from a user-imported `.lrc`.
  bool lyricsImported = false;
  String? _lyricsTrackId;
  int _lyricGeneration = 0;
  final Set<String> _metadataLoaded = <String>{};
  final Set<String> _metadataPending = <String>{};
  Set<int> _likedSongIds = <int>{};
  String? likeError;
  bool get currentLiked {
    if (MusicId.tryParse(current?.id ?? '') != null) {
      return _musicPlatforms.liked.contains(current?.id);
    }
    final id = int.tryParse(current?.id ?? '');
    return id != null && _likedSongIds.contains(id);
  }

  /// Size of the loaded personal like list (0 while guest or not yet loaded).
  int get likedCount =>
      isNavidrome ? collections.liked?.trackCount ?? 0 : _likedSongIds.length;

  /// Whether the gateway was reachable on the last interaction.
  bool get online => catalog.online;

  NeteaseGateway get gateway => catalog.gateway;

  // -- session --------------------------------------------------------------

  /// Never null: the guest session is the default, so there is no gate —
  /// the shell is always reachable and sign-in is an upgrade, not a toll.
  SessionUser _user = SessionUser.guest;
  SessionUser get user => _user;
  bool get isGuest => _user.isGuest;
  bool get signedIn => !_user.isGuest;

  /// Restores any persisted gateway session, then loads the home feed.
  Future<void> bootstrap() async {
    final int initialQueueActivity = _queueActivity;
    try {
      final prefs = await SharedPreferences.getInstance();
      _independentPlayback =
          prefs.getBool('lazer_independent_playback') ?? _independentPlayback;
      hapticsEnabled = prefs.getBool('lazer_haptics') ?? true;
      hapticIntensity = (prefs.getDouble('lazer_haptic_intensity') ?? 0.5)
          .clamp(0, 1);
      themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == prefs.getString('lazer_theme_mode'),
        orElse: () => ThemeMode.system,
      );
      language = AppLanguage.parse(prefs.getString('lazer_language'));
      legacyBackground = LegacyBackgroundModeLabels.parse(
        prefs.getString('lazer_legacy_background'),
      );
      playerBackground = LegacyBackgroundModeLabels.parse(
        prefs.getString('lazer_player_background'),
      );
      final browseFps = prefs.getDouble('lazer_browse_background_fps') ?? 30;
      browseBackgroundFps = browseFps.isFinite ? browseFps.clamp(10, 1000) : 30;
      final playerFps = prefs.getDouble('lazer_player_background_fps') ?? 0;
      playerBackgroundFps = playerFps.isFinite
          ? (playerFps == 0 ? 0 : playerFps.clamp(10, 1000))
          : 0;
      final browseColor = prefs.getInt('lazer_browse_background_color');
      browseBackgroundColor = browseColor == null ? null : Color(browseColor);
      final playerColor = prefs.getInt('lazer_player_background_color');
      playerBackgroundColor = playerColor == null ? null : Color(playerColor);
      playerBackgroundImagePath = await backgroundImageStore.restore(
        prefs.getString('lazer_player_background_image'),
      );
      final String? storedBackgroundImage = prefs.getString(
        'lazer_legacy_background_image',
      );
      final String? restoredBackgroundImage = await backgroundImageStore
          .restore(storedBackgroundImage);
      legacyBackgroundImagePath = restoredBackgroundImage;
      mediaShortcuts = MediaShortcutSettings.decode(
        prefs.getString('lazer_media_shortcuts'),
      );
      if (storedBackgroundImage != null &&
          restoredBackgroundImage != null &&
          storedBackgroundImage != restoredBackgroundImage) {
        // Migrate an absolute path from an older build to the portable name.
        await prefs.setString(
          'lazer_legacy_background_image',
          backgroundImageStore.preferenceValue(restoredBackgroundImage),
        );
      }
      legacyUiAlpha = (prefs.getDouble('lazer_legacy_ui_alpha') ?? 0.7).clamp(
        0.4,
        1.0,
      );
      dynamicBackgroundQuality = normalizeDynamicBackgroundQuality(
        prefs.getDouble('lazer_dynamic_background_quality') ??
            kDynamicBackgroundQualityDefault,
      );
      playerBackgroundQuality = normalizeDynamicBackgroundQuality(
        prefs.getDouble('lazer_player_background_quality') ??
            kDynamicBackgroundQualityDefault,
      );
      uiMode = AppUiModeLabels.parse(prefs.getString('lazer_ui_mode'));
      playlistColumns = (prefs.getInt('lazer_playlist_columns') ?? 0).clamp(
        0,
        kPlaylistColumnsMax,
      );
      playlistOrder = List<String>.unmodifiable(<String>[
        for (final String id
            in (prefs.getString('lazer_playlist_order') ?? '').split('\n'))
          if (id.isNotEmpty) id,
      ]);
      final String? storedSurface = prefs.getString('lazer_surface');
      surface = AppSurfaceLabels.parse(storedSurface);
      if (deviceIsTelevision && storedSurface == null) {
        // A television boots straight into 大屏幕模式: its panel, its remote and
        // its viewing distance are the ones that mode is designed for. An
        // explicit choice (including 自动选择) is never overwritten.
        surface = AppSurface.tv;
      }
      dpiScale = normalizeDpiScale(
        prefs.getDouble('lazer_dpi_scale') ?? kDpiScaleDefault,
      );
      autoDpiScale = prefs.getBool('lazer_auto_dpi_scale') ?? true;
      _volume = (prefs.getDouble('lazer_volume') ?? 1).clamp(0, 1);
      _unmutedVolume =
          (prefs.getDouble('lazer_unmuted_volume') ??
                  (_volume > 0 ? _volume : 1))
              .clamp(0.01, 1);
      playbackQuality = AudioQualityInfo.parse(
        prefs.getString('lazer_playback_quality'),
      );
      hifiSettings = HifiSettings.fromMap(<String, Object?>{
        'hifi_native_engine': prefs.getBool('hifi_native_engine'),
        'hifi_output_token': prefs.getString('hifi_output_token'),
        'hifi_output_name': prefs.getString('hifi_output_name'),
        'hifi_exclusive': prefs.getBool('hifi_exclusive'),
        'hifi_bit_perfect': prefs.getBool('hifi_bit_perfect'),
        'hifi_dsd_mode': prefs.getString('hifi_dsd_mode'),
        'hifi_dsd_rate_policy': prefs.getString('hifi_dsd_rate_policy'),
        'hifi_volume_normalization': prefs.getString(
          'hifi_volume_normalization',
        ),
        'hifi_crossfeed': prefs.getString('hifi_crossfeed'),
        'hifi_buffer_millis': prefs.getInt('hifi_buffer_millis'),
        'hifi_equalizer': prefs.getString('hifi_equalizer'),
      });
      unawaited(hifi?.apply() ?? Future<void>.value());
      downloadQuality = AudioQualityInfo.parse(
        prefs.getString('lazer_download_quality'),
      );
      downloadDirectory = prefs.getString('lazer_download_directory');
      lyricControlsSeconds =
          (prefs.getDouble('lazer_lyric_controls_seconds') ?? 1.5).clamp(1, 10);
      lyricBlurEnabled = prefs.getBool('lazer_lyric_blur') ?? true;
      showFrameStats =
          prefs.getBool('lazer_show_frame_stats') ?? showFrameStats;
      debugOptionsEnabled = prefs.getBool('lazer_debug_options') ?? false;
      // A build without the hidden switch must not boot with the overlay on.
      if (!debugOptionsEnabled) {
        showFrameStats = const bool.fromEnvironment('LAZER_FRAME_STATS');
      }
      lyricFontSize = (prefs.getDouble('lazer_lyric_font_size') ?? 22).clamp(
        14,
        40,
      );
      lyricFontWeight = normalizeLyricWeight(
        prefs.getInt('lazer_lyric_font_weight') ?? 600,
      );
      fontPreferences = FontPreferences.decode(
        prefs.getString('lazer_font_preferences'),
      );
      importedEnginePath = prefs.getString('lazer_native_engine_path');
      showArtworkWithLyrics =
          prefs.getBool('lazer_show_artwork_with_lyrics') ?? false;
      legacyPalette = LegacyPaletteModeLabels.parse(
        prefs.getString('lazer_legacy_palette'),
      );
      final int? accent = prefs.getInt('lazer_legacy_accent');
      legacyAccentColor = accent == null ? null : Color(accent);
      scrollRetention =
          (prefs.getDouble('lazer_scroll_retention') ??
                  ScrollMotion.defaultRetention)
              .clamp(ScrollMotion.minRetention, ScrollMotion.maxRetention);
      scrollAcceleration =
          (prefs.getDouble('lazer_scroll_acceleration') ??
                  ScrollMotion.defaultAcceleration)
              .clamp(
                ScrollMotion.minAcceleration,
                ScrollMotion.maxAcceleration,
              );
      lyricResumeSeconds = (prefs.getDouble('lazer_lyric_resume_seconds') ?? 2)
          .clamp(1, 10);
      skippedUpdateVersion = prefs.getString('lazer_skipped_update');
      updateCheckedAt = prefs.getInt('lazer_update_checked_at') ?? 0;
      _restorePlayUploads(prefs);
    } catch (_) {}
    // Apply interaction preferences before session and catalogue requests.
    notifyListeners();
    await localLibrary.load();
    await audioEngine?.setVolume(_volume);
    await _restoreRecentTracks();
    await _restoreQueue(initialQueueActivity);
    unawaited(_loadCurrentArtwork());
    unawaited(ensureCurrentLyrics());
    await _restoreSession();
    await _musicPlatforms.restore();
    if (signedIn) unawaited(_flushPlayUploads());
    await refreshHome();
  }

  Future<void> refreshHome({bool force = false}) async {
    if (_presentationDisposed) return;
    if (force) {
      await catalog.invalidateHome(userId: signedIn ? _user.userId : null);
    }
    unawaited(refreshCollections());
    await catalog.loadHome(userId: _user.userId);
    notifyListeners();
    if (enableExternalCharts) {
      unawaited(refreshDiscoveryCharts(force: force));
    }
  }

  Future<void> refreshDiscoveryCharts({bool force = false}) async {
    if (isNavidrome) {
      discoveryCharts = const [];
      discoveryChartsError = null;
      return;
    }
    if (discoveryChartsLoading) return;
    discoveryChartsLoading = true;
    discoveryChartsError = null;
    notifyListeners();
    try {
      if (force) await catalog.invalidateDiscoveryCharts();
      final externalFuture = catalog.discoveryCharts().catchError(
        (_) => const <MusicChart>[],
      );
      try {
        final netease = await catalog.neteaseMirrorCharts();
        if (netease.isNotEmpty) {
          discoveryCharts = _sortDiscoveryCharts(netease);
          notifyListeners();
        }
      } catch (_) {
        // External charts below can still populate the section.
      }
      final external = await externalFuture;
      if (external.isNotEmpty) {
        final ids = discoveryCharts.map((chart) => chart.id).toSet();
        discoveryCharts = _sortDiscoveryCharts(<MusicChart>[
          ...discoveryCharts,
          ...external.where((chart) => ids.add(chart.id)),
        ]);
      }
      if (discoveryCharts.isEmpty) discoveryChartsError = '暂无榜单数据';
    } catch (_) {
      if (discoveryCharts.isEmpty) {
        discoveryChartsError = '榜单暂时连接不上';
      }
    } finally {
      discoveryChartsLoading = false;
      notifyListeners();
    }
  }

  List<MusicChart> _sortDiscoveryCharts(Iterable<MusicChart> charts) {
    final result = charts.toList();
    int priority(MusicChart chart) {
      final title = chart.title.toLowerCase();
      if (title.contains('billboard')) return 0;
      final provider = chart.providerKey ?? '';
      if (provider == 'biliboard:1') return 1;
      if (provider == 'biliboard:2') return 2;
      if (provider == 'biliboard:3') return 3;
      if (provider.startsWith('biliboard:')) return 4;
      return 5;
    }

    result.sort((left, right) {
      final byPriority = priority(left).compareTo(priority(right));
      if (byPriority != 0) return byPriority;
      return left.title.compareTo(right.title);
    });
    return result;
  }

  Future<void> _restoreSession() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cookie = prefs.getString(_sessionKey);
      if (cookie == null || cookie.trim().isEmpty) return;
      gateway.sessionCookie = cookie;
      final GatewayLoginStatus status = await gateway.loginStatus();
      final GatewayUserProfile? profile = status.profile;
      if (status.signedIn && profile != null) {
        _user = SessionUser.fromProfile(
          profile,
          method: AuthMethod.cookie,
          detail: _cookieDetail(cookie),
        );
        notifyListeners();
        unawaited(_refreshLikedSongs());
      } else {
        gateway.clearSession();
        await prefs.remove(_sessionKey);
      }
    } catch (_) {
      // Tests (no plugin) and offline boots stay on the guest session.
    }
  }

  Future<AuthOutcome> signInWithCookie(String cookie) async {
    try {
      if (isNavidrome) await _musicPlatforms.selectNetease();
      final GatewayLoginStatus status = await gateway.loginWithCookie(cookie);
      final GatewayUserProfile? profile = status.profile;
      if (!status.signedIn || profile == null) {
        return const AuthOutcome(false, error: '这个 Cookie 无效或已过期。');
      }
      _adoptSession(
        profile,
        AuthMethod.cookie,
        _cookieDetail(gateway.sessionCookie ?? cookie),
      );
      return const AuthOutcome(true);
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> signInWithPhonePassword(
    String phone,
    String password,
  ) async {
    try {
      if (isNavidrome) await _musicPlatforms.selectNetease();
      final GatewayLoginResult result = await gateway.loginWithPhonePassword(
        phone,
        password,
      );
      return _adoptLoginResult(result, AuthMethod.password, _maskPhone(phone));
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> signInWithPhoneCaptcha(
    String phone,
    String captcha,
  ) async {
    try {
      if (isNavidrome) await _musicPlatforms.selectNetease();
      final GatewayLoginResult result = await gateway.loginWithPhoneCaptcha(
        phone,
        captcha,
      );
      return _adoptLoginResult(result, AuthMethod.sms, _maskPhone(phone));
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> sendSmsCode(String phone) async {
    try {
      await gateway.sendCaptcha(phone);
      return const AuthOutcome(true);
    } catch (error) {
      return _failure(error);
    }
  }

  /// Starts a QR session and returns the scan URL, or null on failure.
  Future<String?> beginQrLogin() async {
    _qrConfirmed = false;
    qrPollError = null;
    try {
      if (isNavidrome) await _musicPlatforms.selectNetease();
      final String key = await gateway.createQrKey();
      if (key.isEmpty) return null;
      final String url = await gateway.createQrCodeUrl(key);
      return url.isEmpty ? null : url;
    } catch (_) {
      return null;
    }
  }

  /// Set once a poll answered 803. The account endpoint can trail the key
  /// confirmation by a moment, so later polls re-check the account before
  /// asking the key again (the key itself is spent after a confirmation).
  bool _qrConfirmed = false;

  /// Last transport/gateway failure while polling the scan key, for the
  /// sign-in card. Cleared as soon as a poll answers again — a silent 801
  /// fallback used to hide server rejections completely.
  String? qrPollError;

  /// Polls a QR key: 800 expired, 801 waiting, 802 scanned, 803 confirmed,
  /// 8821 needs a security check on the phone.
  ///
  /// Only 803 means "this session is signed in": the scan URL was rejected by
  /// the phone when the poll never leaves 801, and a not-yet-ready account
  /// after 803 must not be mistaken for an expired key either.
  Future<int> pollQrLogin(String url) async {
    final Uri? uri = Uri.tryParse(url);
    final String? key = uri?.queryParameters['codekey'];
    if (key == null || key.isEmpty) return 800;
    try {
      if (_qrConfirmed && await _adoptQrSession()) return 803;
      final GatewayQrCheck check = await gateway.checkQrCode(key);
      qrPollError = null;
      if (check.code == 803) {
        _qrConfirmed = true;
        if (await _adoptQrSession()) return 803;
        // Confirmed, account still syncing: stay on the "scanned" state and
        // let the next poll retry the account instead of dropping the login.
        return 802;
      }
      if (check.code == 800 && _qrConfirmed) {
        // A confirmed key is spent: later polls answer "expired" even though
        // the login succeeded. Give the account one more chance first.
        if (await _adoptQrSession()) return 803;
      }
      return check.code;
    } catch (error) {
      qrPollError = _friendly(error);
      return 801;
    }
  }

  /// Reads the account behind the confirmed QR cookie, retrying briefly:
  /// `MUSIC_U` is already installed by [pollQrLogin], but `/login/status`
  /// can answer "not signed in" for a beat after the confirmation.
  Future<bool> _adoptQrSession() async {
    final connection = activeConnectionKey;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      try {
        final GatewayLoginStatus status = await gateway.loginStatus();
        final GatewayUserProfile? profile = status.profile;
        if (status.signedIn &&
            profile != null &&
            activeConnectionKey == connection &&
            !isNavidrome) {
          _qrConfirmed = false;
          _adoptSession(profile, AuthMethod.qrcode, '扫码登录');
          return true;
        }
      } catch (_) {
        // Keep retrying — the account endpoint lags the confirmation.
      }
    }
    return false;
  }

  AuthOutcome _adoptLoginResult(
    GatewayLoginResult result,
    AuthMethod method,
    String detail,
  ) {
    final GatewayUserProfile? profile = result.profile;
    if (!result.ok || profile == null) {
      final String message = result.message ?? '';
      return AuthOutcome(
        false,
        error: message.isEmpty ? '登录失败，请稍后再试。' : message,
      );
    }
    _adoptSession(profile, method, detail);
    return const AuthOutcome(true);
  }

  void _adoptSession(
    GatewayUserProfile profile,
    AuthMethod method,
    String detail,
  ) {
    if (_user.userId != profile.userId) {
      collections = UserCollections.empty;
      _likedSongIds = <int>{};
    }
    _user = SessionUser.fromProfile(profile, method: method, detail: detail);
    _persistSession(gateway.sessionCookie);
    unawaited(refreshHome());
    unawaited(_refreshLikedSongs());
    notifyListeners();
  }

  /// Back to the guest session — stay in the shell, drop the credentials.
  Future<void> signOut() async {
    _musicPlatforms.cancelPending();
    collections = UserCollections.empty;
    collectionsLoading = false;
    collectionsError = null;
    _finishPlaySession();
    await _flushPlayUploads();
    _playUploads.clear();
    unawaited(_persistPlayUploads());
    unawaited(listenTogether.leave());
    pause();
    _stationLoader = null;
    _stationLoading = false;
    _stationSeen.clear();
    _queue = <Track>[];
    _markQueueChanged();
    _queueIndex = 0;
    _position = Duration.zero;
    lyrics = const <LyricLine>[];
    ++_lyricGeneration;
    _lyricsTrackId = null;
    lyricsLoading = false;
    lyricsPureMusic = false;
    lyricsImported = false;
    lyricsError = null;
    ++_generation;
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    unawaited(_saveQueue());
    _user = SessionUser.guest;
    _likedSongIds = <int>{};
    likeError = null;
    _qrConfirmed = false;
    playStats = const <TrackPlayStat>[];
    playStatsError = null;
    _playStatsUid = null;
    if (isNavidrome) {
      catalog.activeGateway.clearSession();
      _musicPlatforms.liked.clear();
    } else {
      gateway.clearSession();
      _musicPlatforms.neteaseUser = SessionUser.guest;
      unawaited(_forgetSession());
    }
    unawaited(refreshHome());
    notifyListeners();
  }

  Future<void> _persistSession(String? cookie) async {
    if (cookie == null || cookie.trim().isEmpty) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, cookie);
    } catch (_) {}
  }

  Future<void> _forgetSession() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    } catch (_) {}
  }

  // -- catalogue actions ----------------------------------------------------

  Future<SearchResults> search(String query) => catalog.search(query);

  /// The signed-in user's collections for the "我" page. Errors propagate.
  Future<UserCollections> userCollections() =>
      catalog.userCollections(_user.userId);

  Future<void> playPlaylist(String playlistId) async {
    final List<Track> tracks = await catalog.playlistTracks(playlistId);
    playQueue(tracks);
  }

  Future<void> playAlbum(String albumId) async {
    final List<Track> tracks = MusicId.tryParse(albumId) != null
        ? await catalog.albumTracksFor(albumId)
        : await catalog.albumTracks(int.tryParse(albumId) ?? 0);
    playQueue(tracks);
  }

  /// Creates a playlist on the signed-in account ("上传到云端"): it is stored
  /// by the service and shows up in the library on every device.
  ///
  /// [privacy] mirrors the official client's 仅自己可见 option. The returned
  /// playlist carries the server id, so a caller can add the current song
  /// immediately; [refreshCollections] then brings the library up to date.
  Future<Playlist?> createCloudPlaylist(
    String name, {
    bool privacy = false,
  }) async {
    if (!signedIn) throw StateError('Sign in to create a playlist.');
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('name cannot be blank.');
    if (isNavidrome) return _musicPlatforms.createPlaylist(trimmed, privacy);
    final GatewayPlaylist? created = await gateway.createPlaylist(
      trimmed,
      privacy: privacy,
    );
    if (created == null) return null;
    final Playlist playlist = Catalog.playlistFromGateway(created);
    // Insert optimistically: the picker closes as soon as the song is added,
    // and the refreshed list can arrive a moment later or fail offline.
    if (!collections.created.any((Playlist item) => item.id == playlist.id)) {
      collections = UserCollections(
        liked: collections.liked,
        created: <Playlist>[playlist, ...collections.created],
        subscribed: collections.subscribed,
      );
      notifyListeners();
    }
    await _invalidateLibraryCollections();
    return playlist;
  }

  /// Adds [trackId] to one of the account's cloud playlists.
  ///
  /// Adding to 我喜欢的音乐 is the service's "like" action, so the local heart
  /// state follows immediately; every playlist's cached track list is
  /// invalidated so opening it shows the new song.
  Future<void> addSongToCloudPlaylist(String playlistId, String trackId) async {
    if (!signedIn) throw StateError('Sign in to add songs to a playlist.');
    if (MusicId.tryParse(playlistId) != null ||
        MusicId.tryParse(trackId) != null) {
      await _musicPlatforms.addSong(playlistId, trackId);
      return;
    }
    final int pid = int.tryParse(playlistId) ?? 0;
    final int sid = int.tryParse(trackId) ?? 0;
    if (pid <= 0 || sid <= 0) {
      throw ArgumentError('Invalid playlist or song.');
    }
    if (int.tryParse(collections.liked?.id ?? '') == pid) {
      // 我喜欢的音乐 is not manipulated through the playlist endpoints.
      final int uid = _user.userId;
      if (uid <= 0) throw StateError('Sign in to add songs to a playlist.');
      await gateway.setSongLiked(sid, uid, true);
      _likedSongIds.add(sid);
      final Playlist? liked = collections.liked;
      if (liked != null && !liked.trackIds.contains(trackId)) {
        collections = UserCollections(
          liked: Playlist(
            id: liked.id,
            name: liked.name,
            trackIds: <String>[...liked.trackIds, trackId],
            coverSeed: liked.coverSeed,
            description: liked.description,
            coverUrl: liked.coverUrl,
            trackCount: liked.trackCount + 1,
          ),
          created: collections.created,
          subscribed: collections.subscribed,
        );
      }
    } else {
      await gateway.addTracksToPlaylist(pid, <int>[sid]);
    }
    await _invalidateLibraryCollections(playlistId: playlistId);
    notifyListeners();
  }

  /// Drops cached copies touched by a playlist mutation and reloads the
  /// library shelves in the background.
  Future<void> _invalidateLibraryCollections({String? playlistId}) async {
    if (playlistId != null) await catalog.invalidatePlaylist(playlistId);
    final int uid = _user.userId;
    if (uid > 0) await catalog.invalidateCollections(uid);
    unawaited(refreshCollections(force: true));
  }

  // -- transport ------------------------------------------------------------
  //
  // Two notification lanes. `notifyListeners()` fires only on structural
  // changes (session, queue, play state); position ticks and buffer progress go
  // through the private [ticks] lane so leaf transport widgets update
  // without rebuilding whole screens. This keeps the semantics tree stable
  // while playing — the churn behind the Windows UIA log storm and the
  // perceived freezes.

  final _TickNotifier _tickNotifier = _TickNotifier();

  /// Position/progress updates (100 ms while playing, buffer changes while paused).
  Listenable get ticks => _tickNotifier;

  /// Structural changes AND ticks — for the transport widgets that mirror
  /// both (the dark player bar, the Now Playing transport).
  late final Listenable all = Listenable.merge(<Listenable>[
    this,
    _tickNotifier,
  ]);

  Timer? _ticker;
  List<Track> _queue = <Track>[];
  int _queueRevision = 0;
  List<Track>? _queueSnapshot;
  final PlaybackQueueStore _queueStore;
  int _queueActivity = 0;
  List<Track> _recentTracks = <Track>[];
  int _queueIndex = 0;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _shuffle = false;
  LoopMode _repeat = LoopMode.off;
  bool _realActive = false;
  int _generation = 0;
  int trackChangeDirection = 1;

  /// The current play-report session.
  ///
  /// A play is uploaded once, when the session ends (track change, stop or
  /// completion), and only if it was listened to for the qualification time.
  /// [played] is measured from position deltas, so buffering pauses and seeks
  /// never inflate the listening time.
  Track? _playSessionTrack;
  Duration _playSessionTime = Duration.zero;
  Duration _playSessionPosition = Duration.zero;
  bool _playSessionQualified = false;
  bool _playSessionSent = false;
  final List<_PlayReport> _playUploads = <_PlayReport>[];
  bool _playUploadInFlight = false;

  /// App queue index of the track already appended to the engine's queue.
  ///
  /// Non-null means the engine can cross into [that track] by itself; the
  /// platform's index change is then adopted instead of loading a URL again.
  int? _queuedNextIndex;

  /// Identifier of the engine queue the appends belong to.
  int? _queueId;

  Future<List<Track>> Function()? _stationLoader;
  bool _stationLoading = false;
  final Set<String> _stationSeen = <String>{};

  List<Track> get queue => _queueSnapshot ??= List<Track>.unmodifiable(_queue);

  /// Changes whenever the queue's contents or order change.
  int get queueRevision => _queueRevision;

  void _markQueueChanged() {
    _queueRevision++;
    _queueSnapshot = null;
  }

  List<Track> get recentTracks => List<Track>.unmodifiable(
    _recentTracks.where((track) {
      final reference = MusicId.tryParse(track.id);
      return reference == null
          ? !isNavidrome
          : reference.connection == catalog.activeGateway.connectionId;
    }),
  );

  /// Counts without allocating an immutable snapshot of the queue.
  int get queueLength => _queue.length;
  Track? get current =>
      _queue.isEmpty ? null : _queue[_queueIndex.clamp(0, _queue.length - 1)];
  Duration get position => _position;
  Duration? _optimisticSeek;
  int _optimisticSeekGeneration = 0;
  int _seekRequest = 0;
  final Stopwatch _optimisticSeekClock = Stopwatch();
  Duration get precisePosition {
    final bool active = _realActive && audioEngine?.active == true;
    final actual = active ? audioEngine!.position : _position;
    final pending = _optimisticSeek;
    if (pending != null) {
      final acknowledged =
          active &&
          (actual - pending).abs() <= const Duration(milliseconds: 500);
      if (_optimisticSeekGeneration == _generation &&
          !acknowledged &&
          _optimisticSeekClock.elapsed < const Duration(seconds: 3)) {
        return pending;
      }
      _optimisticSeek = null;
      _optimisticSeekClock.stop();
    }
    return actual;
  }

  bool get playing => _playing;
  bool get audioReady => _realActive && (audioEngine?.active ?? false);
  int get queueIndex => _queueIndex;
  bool get shuffle => _shuffle;
  LoopMode get repeat => _repeat;

  /// Whether the lyric request for the current track has finished (or failed).
  ///
  /// The now-playing page uses this instead of [lyricsLoading] alone so an
  /// empty list before the request starts cannot open the artwork by mistake.
  bool get currentLyricsSettled =>
      current != null && _lyricsTrackId == current!.id && !lyricsLoading;

  double get progress {
    final Track? t = current;
    if (t == null || t.duration.inMilliseconds == 0) return 0;
    // The seek rail and its time label read this on every tick, so it has to
    // be the engine's live position. [_position] is only copied across on the
    // tick itself and lags the audio by up to one interval.
    return (precisePosition.inMilliseconds / t.duration.inMilliseconds).clamp(
      0,
      1,
    );
  }

  /// How much of the current track the engine has buffered, 0…1.
  ///
  /// The now-playing seek rail paints this behind the played fraction. The
  /// plain [AudioEngine] contract carries no buffer information, so engines
  /// without [BufferedAudioEngine] fall back to the playhead.
  double get bufferedFraction {
    final Track? t = current;
    final int duration = t?.duration.inMilliseconds ?? 0;
    if (duration <= 0) return 0;
    if (audioEngine == null) return 0;
    if (!_seekLimitedByBuffer) return 1;
    final AudioEngine? engine = audioEngine;
    final Duration playhead = precisePosition;
    final Duration buffered = engine is BufferedAudioEngine
        ? (engine as BufferedAudioEngine).bufferedPosition
        : playhead;
    final Duration available = buffered > playhead ? buffered : playhead;
    return (available.inMilliseconds / duration).clamp(0.0, 1.0);
  }

  /// Seeking can move through buffered audio, but never past it.
  /// Keep the current playhead reachable if a backend reports a shorter buffer.
  double get seekLimitFraction {
    if (!_seekLimitedByBuffer) return 1;
    final double buffered = bufferedFraction;
    final double played = progress;
    return buffered > played ? buffered : played;
  }

  double clampSeekFraction(double fraction) =>
      fraction.clamp(0.0, seekLimitFraction).toDouble();

  bool get _seekLimitedByBuffer {
    final AudioEngine? engine = audioEngine;
    return engine is SeekBoundaryReportingAudioEngine &&
        (engine as SeekBoundaryReportingAudioEngine).seekIsLimitedByBuffer;
  }

  void playQueue(List<Track> tracks, {int startIndex = 0}) {
    _stationLoader = null;
    _stationLoading = false;
    _stationSeen.clear();
    _replaceQueue(tracks, startIndex: startIndex);
  }

  /// Starts a radio queue which keeps asking [loadMore] for fresh songs as the
  /// listener approaches its tail. The first batch is supplied by the caller
  /// so tapping a station still gives immediate feedback.
  void playStationQueue(
    List<Track> tracks, {
    required Future<List<Track>> Function() loadMore,
  }) {
    if (tracks.isEmpty) return;
    _stationLoader = loadMore;
    _stationLoading = false;
    _stationSeen
      ..clear()
      ..addAll(tracks.map((track) => track.id));
    _shuffle = false;
    _repeat = LoopMode.off;
    _replaceQueue(tracks);
    unawaited(_ensureStationBuffer());
  }

  /// Starts the 心动 mode: a station seeded by the playing song.
  ///
  /// The official app replaces the list with intelligence recommendations and
  /// asks for the next batch whenever the queue nears its end. The first batch
  /// is seeded by the song that is playing; each later batch continues from
  /// the last recommendation, so a refill advances the list instead of asking
  /// for the same sample again.
  Future<bool> startHeartMode() async {
    final Playlist? liked = collections.liked;
    if (liked == null) return false;
    int? seed;
    Future<List<Track>> load() async {
      final int? currentSong = int.tryParse(current?.id ?? '');
      final List<Track> batch = await catalog.heartModeTracks(
        liked,
        seedSongId: seed ?? currentSong,
      );
      if (batch.isNotEmpty) seed = int.tryParse(batch.last.id) ?? seed;
      return batch;
    }

    final List<Track> first = await load();
    if (first.isEmpty) return false;
    playStationQueue(first, loadMore: load);
    return true;
  }

  void _replaceQueue(List<Track> tracks, {int startIndex = 0}) {
    if (tracks.isEmpty) return;
    _finishPlaySession();
    trackChangeDirection = 1;
    _queue = List<Track>.of(tracks);
    _markQueueChanged();
    _queueIndex = startIndex.clamp(0, tracks.length - 1);
    unawaited(_saveQueue());
    _position = Duration.zero;
    playbackError = null;
    unawaited(_loadLyrics());
    _ensureTicker();
    _playing = true;
    unawaited(_startAudio());
    notifyListeners();
  }

  void togglePlay() {
    if (current == null) return;
    _playing = !_playing;
    if (_playing) {
      if (_realActive) {
        unawaited(_resumeAudio());
      } else {
        playbackError = null;
        unawaited(_startAudio());
        _ensureTicker();
      }
    } else {
      _ticker?.cancel();
      if (_realActive) unawaited(audioEngine!.pause());
    }
    notifyListeners();
  }

  void play() {
    if (current == null || _playing) return;
    _playing = true;
    if (_realActive) {
      unawaited(_resumeAudio());
    } else {
      playbackError = null;
      unawaited(_startAudio());
      _ensureTicker();
    }
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    _ticker?.cancel();
    if (_realActive) unawaited(audioEngine!.pause());
    _flushQualifiedSession();
    notifyListeners();
  }

  void stop() {
    _finishPlaySession();
    ++_generation;
    _playing = false;
    _realActive = false;
    _queuedNextIndex = null;
    _queueId = null;
    _position = Duration.zero;
    playbackError = null;
    _ticker?.cancel();
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    notifyListeners();
  }

  void next() {
    if (_queue.isEmpty) return;
    _finishPlaySession();
    if (_stationLoader != null && _queueIndex >= _queue.length - 1) {
      unawaited(_advanceStationFromTail());
      return;
    }
    final int target = _manualNextIndex();
    // When the following track is already in the engine's queue, jumping to it
    // keeps the decoder running instead of reloading (an audible gap).
    _moveTo(target, direction: 1, gapless: target == _queuedNextIndex);
  }

  void previous() {
    if (_queue.isEmpty) return;
    _finishPlaySession();
    playbackError = null;
    // Classic transport behavior: >3s in, "previous" restarts the track.
    if (_position.inSeconds > 3) {
      _position = Duration.zero;
      if (_realActive) unawaited(audioEngine!.seek(Duration.zero));
    } else {
      final int target = (_queueIndex - 1 + _queue.length) % _queue.length;
      _moveTo(target, direction: -1);
    }
    notifyListeners();
    if (_playing) _ensureTicker();
  }

  /// Adopts [index] as the current track and gets the engine onto it.
  ///
  /// [gapless] means the engine already holds that track next in its queue, so
  /// it only has to cross the boundary; otherwise the URL is loaded afresh.
  void _moveTo(int index, {required int direction, bool gapless = false}) {
    if (_queue.isEmpty) return;
    _finishPlaySession();
    trackChangeDirection = direction;
    playbackError = null;
    _queueIndex = index.clamp(0, _queue.length - 1);
    _queuedNextIndex = null;
    unawaited(_saveQueue());
    _position = Duration.zero;
    unawaited(_loadLyrics());
    if (_playing) {
      if (gapless && audioEngine?.active == true) {
        unawaited(_crossIntoQueuedTrack());
      } else {
        unawaited(_startAudio());
      }
      _ensureTicker();
    }
    notifyListeners();
    unawaited(_ensureStationBuffer());
  }

  Future<void> _advanceStationFromTail() async {
    final int before = _queue.length;
    await _waitForStationLoad();
    if (_queue.length <= before) await _ensureStationBuffer(force: true);
    if (!_playing || _queue.length <= before) return;
    _moveTo(before, direction: 1);
  }

  Future<void> _waitForStationLoad() async {
    // A user can hit Next while the proactive tail request is still in flight.
    // Join that work instead of treating "already loading" as an empty radio.
    for (var tick = 0; _stationLoading && tick < 400; tick++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<bool> _ensureStationBuffer({bool force = false}) async {
    final loader = _stationLoader;
    if (loader == null || _stationLoading) return false;
    if (!force && _queue.length - _queueIndex >= 6) return false;
    _stationLoading = true;
    try {
      List<Track> lastLoaded = const <Track>[];
      // Some recommendation endpoints can repeat a tiny batch. Give them a
      // second chance before deciding there is temporarily nothing new.
      for (var attempt = 0; attempt < 2; attempt++) {
        final loaded = await loader();
        lastLoaded = loaded;
        if (_stationLoader != loader) return false;
        final fresh = loaded.where((track) => _stationSeen.add(track.id));
        final additions = fresh.take(30).toList();
        if (additions.isEmpty) continue;
        _queue.addAll(additions);
        _markQueueChanged();
        unawaited(_saveQueue());
        notifyListeners();
        return true;
      }
      // A finite recommendation surface must not turn a radio into a three-
      // song loop or a stopped queue. Once every fresh result has been heard,
      // reshuffle the returned pool and keep the station flowing.
      final fallback =
          lastLoaded.where((track) => track.id != current?.id).toList()
            ..shuffle();
      if (fallback.isNotEmpty && _stationLoader == loader) {
        _queue.addAll(fallback.take(20));
        _markQueueChanged();
        unawaited(_saveQueue());
        notifyListeners();
        return true;
      }
    } catch (_) {
      // The current radio buffer remains playable; another tail event retries.
    } finally {
      _stationLoading = false;
    }
    return false;
  }

  /// Index a manual "next" moves to: never a no-op, and repeat-one still walks
  /// the queue (only playback running out honours [LoopMode.one]).
  int _manualNextIndex() {
    if (_shuffle) {
      return _queue.length == 1
          ? 0
          : _randomIndex(_queue.length, avoid: _queueIndex);
    }
    return (_queueIndex + 1) % _queue.length;
  }

  /// Index the queue advances to when the current track plays out on its own.
  ///
  /// Null means playback stops after the current track.
  int? _autoAdvanceIndex() {
    if (_repeat == LoopMode.one) return _queueIndex;
    if (_shuffle && _queue.length > 1) {
      return _randomIndex(_queue.length, avoid: _queueIndex);
    }
    if (_repeat == LoopMode.off && _queueIndex >= _queue.length - 1) {
      return null;
    }
    return (_queueIndex + 1) % _queue.length;
  }

  void seek(double fraction) {
    final Track? t = current;
    if (t == null) return;
    final Duration target = t.duration * clampSeekFraction(fraction);
    _position = target;
    if (_realActive) {
      _optimisticSeek = target;
      _optimisticSeekGeneration = _generation;
      _optimisticSeekClock
        ..reset()
        ..start();
      final request = ++_seekRequest;
      unawaited(
        Future<void>.sync(() => audioEngine!.seek(target)).catchError((
          Object error,
        ) {
          if (request == _seekRequest) {
            _optimisticSeek = null;
            _tickNotifier.pulse();
          }
          debugPrint('Seek failed: $error');
        }),
      );
    }
    // Position-only change: tick lane, not a structural rebuild.
    _tickNotifier.pulse();
  }

  /// Relative seek used by the keyboard shortcuts.
  void seekBy(Duration delta) {
    final Track? t = current;
    if (t == null) return;
    final int total = t.duration.inMilliseconds;
    if (total <= 0) return;
    final int target = (precisePosition + delta).inMilliseconds.clamp(0, total);
    seek(target / total);
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  /// The legacy single play-mode button: Sequential → ListLoop → SingleLoop →
  /// Shuffle → Sequential.
  void cyclePlayMode() {
    if (_shuffle) {
      _shuffle = false;
      _repeat = LoopMode.off;
    } else if (_repeat == LoopMode.off) {
      _repeat = LoopMode.all;
    } else if (_repeat == LoopMode.all) {
      _repeat = LoopMode.one;
    } else {
      _repeat = LoopMode.off;
      _shuffle = true;
    }
    notifyListeners();
  }

  void cycleRepeat() {
    _repeat = switch (_repeat) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    notifyListeners();
  }

  void playTrackAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    _finishPlaySession();
    trackChangeDirection = index < _queueIndex ? -1 : 1;
    playbackError = null;
    _queueIndex = index;
    unawaited(_saveQueue());
    _position = Duration.zero;
    unawaited(_loadLyrics());
    _playing = true;
    unawaited(_startAudio());
    _ensureTicker();
    notifyListeners();
  }

  /// Local files win over the network so downloads and scanned songs keep
  /// playing offline. Missing files fall through to the service.
  Future<String?> _trackUrl(
    Track track, {
    bool Function()? stillCurrent,
  }) async {
    final AudioQuality quality = playbackQuality;
    final File? local = await localLibrary.localFileFor(
      track,
      quality: quality,
    );
    if (stillCurrent != null && !stillCurrent()) return null;
    if (local != null) return local.uri.toString();
    return catalog.audioUrlFor(track, quality: quality);
  }

  /// Loads the stream URL. A locked or unavailable song stops playback and
  /// exposes a visible error instead of advancing a simulated clock.
  ///
  /// [resumeAt] is used when the stream has to be re-resolved for the same
  /// track — switching audio quality keeps the playhead where it was.
  Future<void> _startAudio({Duration? resumeAt}) async {
    unawaited(_loadCurrentArtwork());
    final AudioEngine? engine = audioEngine;
    final Track? track = current;
    if (track == null) return;
    final int generation = ++_generation;
    _realActive = false;
    _queuedNextIndex = null;
    String? url;
    try {
      url = await _trackUrl(
        track,
        stillCurrent: () => generation == _generation,
      );
    } catch (error) {
      if (generation == _generation) _failPlayback(_friendly(error));
      return;
    }
    if (generation != _generation) return;
    if (url == null || url.isEmpty) {
      _failPlayback('这首歌暂时无法播放，请换一首。');
      return;
    }
    if (engine == null) {
      _failPlayback('当前设备没有可用的音频播放器。');
      return;
    }
    final QueueAudioEngine? queueEngine = _queueEngine;
    int? queueId;
    try {
      if (queueEngine != null) {
        try {
          queueId = await queueEngine.setQueue(<String>[url]);
        } catch (_) {
          // The platform refused a queue (or cannot build one): keep playing
          // through the single-source path rather than failing the track.
          queueId = null;
        }
      }
      // Rapid next/previous presses supersede loads while the engine is still
      // opening the stream. Falling back to `setUrl` then would start a second
      // platform load alongside the newer one; just let it go.
      if (generation != _generation) return;
      if (queueId == null) await engine.setUrl(url);
      if (generation != _generation) return;
      await engine.setVolume(_volume);
      if (resumeAt != null && resumeAt > Duration.zero) {
        try {
          await engine.seek(resumeAt);
        } catch (_) {
          // A source that cannot seek still plays; only the position is lost.
        }
        if (generation != _generation) return;
        _position = resumeAt;
      }
    } catch (error) {
      if (generation == _generation) _failPlayback('音频加载失败，请重试。');
      return;
    }
    if (generation != _generation) return;
    _queueId = queueId;
    _realActive = true;
    unawaited(_recordCurrentLocally());
    unawaited(_ensureStationBuffer());
    if (_playing) unawaited(_resumeAudio());
    unawaited(_prefetchNext());
    notifyListeners();
  }

  /// Hands the track that follows the current one to the engine, so the
  /// platform can cross into it while the decoder is still running.
  ///
  /// The queue engine is optional: with a plain [AudioEngine] this is a no-op
  /// and playback keeps the load-on-completion path.
  Future<void> _prefetchNext() async {
    final QueueAudioEngine? engine = _queueEngine;
    final int? queueId = _queueId;
    if (engine == null || queueId == null || _queue.isEmpty) return;
    final int? next = _autoAdvanceIndex();
    if (next == null) {
      _queuedNextIndex = null;
      return;
    }
    String? url;
    try {
      url = await _trackUrl(
        _queue[next],
        stillCurrent: () => queueId == _queueId && _realActive,
      );
    } catch (_) {
      url = null;
    }
    // A track change or a stop while the URL was in flight invalidates this
    // prefetch: the engine may already hold a different queue.
    if (queueId != _queueId || !_realActive) return;
    if (url == null || url.isEmpty) return;
    bool appended;
    try {
      appended = await engine.appendToQueue(queueId, url);
    } catch (_) {
      appended = false;
    }
    if (!appended || queueId != _queueId) return;
    _queuedNextIndex = next;
  }

  /// Crosses into the track the engine already holds next, without reloading.
  Future<void> _crossIntoQueuedTrack() async {
    final QueueAudioEngine? engine = _queueEngine;
    if (engine == null) return;
    final int generation = _generation;
    final int targetIndex = _queueIndex;
    var crossed = false;
    try {
      crossed = await engine.playQueuedNext();
    } catch (_) {
      // A queue implementation may reject the hand-off. The normal source
      // path below still gives the requested track a chance to play.
    }
    // A newer switch, stop or pause owns the engine now. Do not let a delayed
    // queue operation restart playback or overwrite that newer choice.
    if (!_playing || generation != _generation || targetIndex != _queueIndex) {
      return;
    }
    if (!crossed) {
      unawaited(_startAudio());
      return;
    }
    // Some queue engines switch tracks by opening the prepared source again;
    // that leaves their output paused even though the app is still in the
    // playing state. Calling play is harmless for engines that preserved
    // playback and is required for engines that reopened the source.
    unawaited(_resumeAudio());
    unawaited(_prefetchNext());
  }

  /// The platform moved to the queued track on its own — the gapless hand-off.
  ///
  /// Everything the load path would have done still has to happen (index,
  /// persistence, lyrics, artwork), only the audio is already playing.
  void _onEngineAdvanced(int _) {
    _finishPlaySession();
    final int? target = _queuedNextIndex;
    if (!_realActive || !_playing || target == null) return;
    _queuedNextIndex = null;
    trackChangeDirection = 1;
    playbackError = null;
    _queueIndex = target.clamp(0, _queue.length - 1);
    _position = Duration.zero;
    unawaited(_saveQueue());
    unawaited(_loadLyrics());
    unawaited(_loadCurrentArtwork());
    unawaited(_recordCurrentLocally());
    unawaited(_ensureStationBuffer());
    _ensureTicker();
    _tickNotifier.pulse();
    notifyListeners();
    unawaited(_prefetchNext());
  }

  Future<void> _loadCurrentArtwork() async {
    unawaited(refreshArtworkSeed());
    final track = current;
    if (track == null ||
        _metadataLoaded.contains(track.id) ||
        _metadataPending.contains(track.id)) {
      return;
    }
    if (MusicId.tryParse(track.id) case final reference?) {
      await _musicPlatforms.hydrate(track, reference);
      return;
    }
    final id = int.tryParse(track.id);
    if (id == null || id <= 0) return;
    _metadataPending.add(track.id);
    try {
      final songs = await gateway.songDetails(<int>[id]);
      final song = songs.where((song) => song.id == id).firstOrNull;
      if (song == null) return;
      _metadataLoaded.add(track.id);
      // Hydrate matching entries without replacing the current queue or
      // erasing artwork and translations when a field is absent upstream.
      bool changed = false;
      _queue = _queue.map((entry) {
        if (entry.id != track.id ||
            (entry.coverUrl == song.coverUrl &&
                entry.translatedTitle == song.translatedTitle &&
                entry.albumId > 0 &&
                entry.artists.isNotEmpty)) {
          return entry;
        }
        changed = true;
        return Track(
          id: entry.id,
          title: entry.title,
          artist: entry.artist,
          artists: song.artistDetails.isNotEmpty
              ? song.artistDetails.map(Catalog.artistFromGateway).toList()
              : entry.artists,
          album: entry.album,
          duration: entry.duration,
          coverSeed: entry.coverSeed,
          accent: entry.accent,
          albumId: song.albumId > 0 ? song.albumId : entry.albumId,
          coverUrl: song.coverUrl ?? entry.coverUrl,
          translatedTitle: song.translatedTitle ?? entry.translatedTitle,
        );
      }).toList();
      if (changed) {
        _markQueueChanged();
        unawaited(refreshArtworkSeed());
        unawaited(_saveQueue());
        final Track? hydrated = current;
        if (hydrated != null) unawaited(_replaceRecentMetadata(hydrated));
        notifyListeners();
      }
    } catch (_) {
      // Keep playback available; the next playback attempt can retry metadata.
    } finally {
      _metadataPending.remove(track.id);
    }
  }

  Future<void> _restoreQueue(int initialActivity) async {
    if (_queueActivity != initialActivity) return;
    final PlaybackQueueSnapshot? snapshot = await _queueStore.load();
    // Playback or sign-out can happen while preferences or decoding are in
    // flight. Those actions own the queue and must not be overwritten.
    if (snapshot == null || _queueActivity != initialActivity) return;
    _queue = snapshot.tracks;
    _markQueueChanged();
    _queueIndex = snapshot.index;
    notifyListeners();
  }

  Future<void> _restoreRecentTracks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_recentTracksKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _recentTracks = decoded
          .whereType<Map<String, dynamic>>()
          .map(Track.fromJson)
          .where((track) => track.id.isNotEmpty)
          .take(_recentTracksLimit)
          .toList();
      notifyListeners();
    } catch (_) {
      _recentTracks = <Track>[];
    }
  }

  Future<void> _recordCurrentLocally() async {
    final Track? track = current;
    if (track == null || track.id.isEmpty) return;
    _recentTracks = <Track>[
      track,
      ..._recentTracks.where((entry) => entry.id != track.id),
    ].take(_recentTracksLimit).toList();
    notifyListeners();
    await _saveRecentTracks();
  }

  Future<void> _replaceRecentMetadata(Track track) async {
    bool changed = false;
    _recentTracks = _recentTracks.map((entry) {
      if (entry.id != track.id) return entry;
      changed = true;
      return track;
    }).toList();
    if (changed) await _saveRecentTracks();
  }

  Future<void> _saveRecentTracks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _recentTracksKey,
        jsonEncode(_recentTracks.map((track) => track.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _saveQueue() {
    _queueActivity++;
    return _queueStore.save(_queue, _queueIndex, _queueRevision);
  }

  Future<void> _resumeAudio() async {
    final generation = _generation;
    try {
      await audioEngine!.play();
    } catch (_) {
      if (generation == _generation) _failPlayback('播放中断，请重试。');
    }
  }

  Future<void> _refreshLikedSongs() async {
    if (_presentationDisposed) return;
    if (isNavidrome) {
      await refreshCollections(force: true);
      return;
    }
    final uid = _user.userId;
    if (uid <= 0) return;
    try {
      final ids = await gateway.likedSongIds(uid);
      if (_user.userId != uid) return;
      _likedSongIds = ids;
      notifyListeners();
    } catch (_) {
      // Personal likes are optional while public playback remains available.
    }
  }

  Future<void> toggleLikeCurrent() async {
    if (MusicId.tryParse(current?.id ?? '') != null) {
      await _musicPlatforms.toggleLike();
      return;
    }
    final id = int.tryParse(current?.id ?? '');
    final uid = _user.userId;
    if (id == null || uid <= 0) return;
    final liked = !_likedSongIds.contains(id);
    likeError = null;
    try {
      await gateway.setSongLiked(id, uid, liked);
      if (_user.userId != uid) return;
      if (liked) {
        _likedSongIds.add(id);
      } else {
        _likedSongIds.remove(id);
      }
      // The next entry into the liked playlist must reflect this mutation.
      final playlistId = collections.liked?.id;
      if (playlistId != null) await catalog.invalidatePlaylist(playlistId);
      await catalog.invalidateCollections(_user.userId);
    } catch (_) {
      likeError = '收藏失败，请稍后重试。';
    }
    notifyListeners();
  }

  Future<void> ensureCurrentLyrics({bool force = false}) async {
    final track = current;
    if (track == null) return;
    if (force) {
      await catalog.invalidateLyrics(track.id);
      if (current?.id != track.id) return;
    }
    if (!force &&
        _lyricsTrackId == track.id &&
        (lyricsLoading || lyrics.isNotEmpty || lyricsPureMusic)) {
      return;
    }
    await _loadLyrics();
  }

  Future<void> _loadLyrics() async {
    final track = current;
    final generation = ++_lyricGeneration;
    lyrics = const <LyricLine>[];
    lyricsError = null;
    lyricsImported = false;
    _lyricsTrackId = track?.id;
    lyricsLoading = track != null;
    lyricsPureMusic = false;
    notifyListeners();
    if (track == null) return;
    // The imported copy is read in parallel and never blocks the sheet: a slow
    // or unavailable plugin should not keep the spinner up, and the imported
    // lyrics still win whenever they arrive for this track.
    unawaited(
      importedLyrics
          .read(track)
          .then((String? imported) {
            if (imported == null || generation != _lyricGeneration) return;
            lyrics = parseLrc(imported);
            lyricsImported = true;
            lyricsPureMusic = false;
            lyricsError = null;
            lyricsLoading = false;
            notifyListeners();
          })
          .catchError((Object _) {}),
    );
    Object? failure;
    final bool localOnly =
        track.localPath != null || track.id.startsWith('local:');
    if (!localOnly) {
      try {
        final payload = await catalog.lyricsFor(track);
        if (generation != _lyricGeneration) return;
        if (!lyricsImported) {
          lyrics = payload == null ? const <LyricLine>[] : parseLyrics(payload);
          lyricsPureMusic = payload?.pureMusic ?? false;
        }
      } catch (error) {
        if (generation != _lyricGeneration) return;
        failure = error;
      }
    }
    // Cloud lyrics are authoritative, but a `.lrc` beside a downloaded or
    // scanned file is a useful offline fallback.
    if (lyrics.isEmpty && !lyricsPureMusic) {
      final File? localFile = await localLibrary.localFileFor(track);
      if (generation != _lyricGeneration) return;
      final String? localPath = localFile?.path ?? track.localPath;
      final String? sidecar = await ImportedLyricsStore.sidecarFor(localPath);
      if (generation != _lyricGeneration) return;
      if (sidecar != null &&
          lyrics.isEmpty &&
          !lyricsImported &&
          !lyricsPureMusic) {
        lyrics = parseLrc(sidecar);
      }
    }
    if (lyrics.isEmpty && failure != null) {
      lyricsError = '歌词暂时无法加载。';
    }
    lyricsLoading = false;
    notifyListeners();
  }

  /// Saves user-provided lyrics for [track] and refreshes it when current.
  Future<bool> saveImportedLyrics(Track track, String content) async {
    final bool saved = await importedLyrics.save(track, content);
    if (saved && current?.id == track.id) await _loadLyrics();
    return saved;
  }

  /// Drops the imported copy so the cloud (or the sidecar) is used again.
  Future<void> clearImportedLyrics(Track track) async {
    await importedLyrics.delete(track);
    if (current?.id == track.id) await _loadLyrics();
  }

  void _failPlayback(String message) {
    _realActive = false;
    _playing = false;
    _queuedNextIndex = null;
    _ticker?.cancel();
    playbackError = message;
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    notifyListeners();
  }

  /// The engine failed after the source was loaded.
  ///
  /// The message is shown instead of silently stopping: a lost output device and a
  /// decode error both leave the user with no audio, and both are worth naming.
  void _onEngineFailure(String message) {
    if (!_realActive) return;
    _failPlayback(message);
  }

  void _onEngineCompleted() {
    _finishPlaySession();
    if (!_realActive || !_playing) return;
    // Consume the terminal state before seeking/loading; some backends emit
    // both a completed event and a final position update for the same source.
    _realActive = false;
    // A queued track would have been crossed into by the platform; reaching
    // here means the queue really did run out on this source.
    _queuedNextIndex = null;
    final AudioEngine engine = audioEngine!;
    if (_repeat == LoopMode.one) {
      _position = Duration.zero;
      final generation = _generation;
      unawaited(() async {
        try {
          await engine.seek(Duration.zero);
          if (generation != _generation || !_playing) return;
          _realActive = true;
          unawaited(_resumeAudio());
        } catch (_) {
          if (generation == _generation) _failPlayback('播放中断，请重试。');
        }
      }());
      _tickNotifier.pulse();
      return;
    }
    final int? next = _autoAdvanceIndex();
    if (next != null) {
      _moveTo(next, direction: 1);
      return;
    }
    if (_stationLoader != null) {
      unawaited(_continueStationAfterEnd());
      return;
    }
    _position = current?.duration ?? Duration.zero;
    _playing = false;
    _realActive = false;
    _ticker?.cancel();
    engine.stop();
    notifyListeners();
  }

  Future<void> _continueStationAfterEnd() async {
    final int before = _queue.length;
    await _waitForStationLoad();
    final bool added =
        _queue.length > before || await _ensureStationBuffer(force: true);
    if (!_playing || !added || _queue.length <= before) {
      _playing = false;
      _ticker?.cancel();
      await audioEngine?.stop();
      notifyListeners();
      return;
    }
    _moveTo(before, direction: 1);
  }

  void _ensureTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(playbackInterval, (_) => _tick());
  }

  void _tick() {
    final Track? t = current;
    if (t == null || !_playing) return;
    if (_realActive) {
      _position = audioEngine!.position;
      _trackPlaySession(t);
      // A native duration/position is a second completion signal for backends
      // that omit the terminal processing-state event. Never use metadata or
      // an estimated clock here: unavailable/buffering songs must not advance.
      final duration = audioEngine!.duration;
      if (duration != null &&
          duration > Duration.zero &&
          _position >= duration &&
          // A queued track is crossed into by the platform; ending this source
          // there is the hand-off, not the end of the queue.
          _queuedNextIndex == null) {
        _onEngineCompleted();
        return;
      }
      _tickNotifier.pulse();
      return;
    }
    // The URL is still loading. Do not invent elapsed time.
  }

  void _onBufferChanged() {
    // Playback ticks already repaint the rail. While paused, coalesce buffer
    // updates into a modest refresh rate so cache progress stays visible.
    if (_playing || _bufferPulseTimer != null) return;
    _bufferPulseTimer = Timer(const Duration(milliseconds: 250), () {
      _bufferPulseTimer = null;
      _tickNotifier.pulse();
    });
  }

  /// Accumulates how much of [track] was actually heard.
  ///
  /// Position deltas are used instead of wall-clock time: a buffering stall
  /// reports the same position and a seek jumps by minutes, neither of which
  /// should count as listening. A delta above five seconds is treated as a
  /// seek and ignored for that tick.
  void _trackPlaySession(Track track) {
    if (_playSessionTrack?.id != track.id) {
      _finishPlaySession();
      _playSessionTrack = track;
      _playSessionTime = Duration.zero;
      _playSessionPosition = _position;
      _playSessionQualified = false;
      _playSessionSent = false;
      _reportPlayStart(track);
      return;
    }
    final Duration delta = _position - _playSessionPosition;
    _playSessionPosition = _position;
    if (delta <= Duration.zero || delta > const Duration(seconds: 5)) return;
    _playSessionTime += delta;
    if (!_playSessionQualified && _playSessionTime >= _qualifyTime(track)) {
      _playSessionQualified = true;
      // The official player reports the play as soon as it has been heard,
      // not when the listener pauses or changes track. Waiting for a boundary
      // meant the song on screen never reached 听歌排行 and a force-close lost
      // the report entirely.
      _flushQualifiedSession();
    }
  }

  /// The queue a play is credited to: the album when the track names one,
  /// otherwise the song itself, matching the official play-log `sourceId`.
  int _playSourceId(Track track) {
    if (track.albumId > 0) return track.albumId;
    return int.tryParse(track.id) ?? 0;
  }

  void _reportPlayStart(Track track) {
    if (MusicId.tryParse(track.id) != null) {
      unawaited(_musicPlatforms.report(track, Duration.zero, false));
      return;
    }
    final int? songId = int.tryParse(track.id);
    if (songId == null || songId <= 0 || !signedIn) return;
    _enqueuePlay(
      _PlayReport(
        songId: songId,
        kind: _PlayLogKind.start,
        sourceId: _playSourceId(track),
      ),
    );
  }

  /// The official play record qualifies a play after half the song, capped at
  /// 30 seconds. A new play starts counting immediately for very short tracks.
  Duration _qualifyTime(Track track) {
    final Duration half = track.duration ~/ 2;
    if (half <= Duration.zero) return const Duration(seconds: 30);
    return half < const Duration(seconds: 30)
        ? half
        : const Duration(seconds: 30);
  }

  void _finishPlaySession() {
    _flushQualifiedSession();
    _playSessionTrack = null;
    _playSessionTime = Duration.zero;
    _playSessionPosition = Duration.zero;
    _playSessionQualified = false;
    _playSessionSent = false;
  }

  /// Sends a qualified play without ending the session.
  ///
  /// A pause is a natural upload boundary, but resuming the same song must not
  /// count as a second play; the sent flag lives until the track changes.
  void _flushQualifiedSession() {
    final Track? track = _playSessionTrack;
    if (track == null || !_playSessionQualified || _playSessionSent) return;
    _playSessionSent = true;
    if (MusicId.tryParse(track.id) != null) {
      unawaited(_musicPlatforms.report(track, _playSessionTime, true));
      return;
    }
    final int? songId = int.tryParse(track.id);
    if (songId == null || songId <= 0 || !signedIn) return;
    final int durationSeconds = track.duration.inSeconds;
    final int seconds = _playSessionTime.inSeconds.clamp(
      1,
      durationSeconds > 0
          ? durationSeconds
          : _playSessionTime.inSeconds.clamp(1, 1 << 20),
    );
    _enqueuePlay(
      _PlayReport(
        songId: songId,
        kind: _PlayLogKind.play,
        seconds: seconds,
        sourceId: _playSourceId(track),
      ),
    );
  }

  void _enqueuePlay(_PlayReport report) {
    if (_playUploads.length >= 50) _playUploads.removeAt(0);
    _playUploads.add(report);
    unawaited(_persistPlayUploads());
    unawaited(_flushPlayUploads());
  }

  /// Restores plays that qualified while the app was offline or closing, so a
  /// crash or a normal exit never loses listening time the account earned.
  void _restorePlayUploads(SharedPreferences prefs) {
    final String? raw = prefs.getString('lazer_play_uploads');
    if (raw == null || raw.isEmpty) return;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final dynamic row in decoded) {
        if (row is! Map<String, dynamic>) continue;
        final int songId = (row['songId'] as num?)?.toInt() ?? 0;
        final int seconds = (row['seconds'] as num?)?.toInt() ?? 0;
        final int sourceId = (row['sourceId'] as num?)?.toInt() ?? songId;
        // Entries written before the split carry only seconds and are plays.
        final _PlayLogKind kind = row['kind'] == 'start'
            ? _PlayLogKind.start
            : _PlayLogKind.play;
        if (songId > 0 && (kind == _PlayLogKind.start || seconds > 0)) {
          _playUploads.add(
            _PlayReport(
              songId: songId,
              kind: kind,
              seconds: seconds,
              sourceId: sourceId,
            ),
          );
        }
      }
      while (_playUploads.length > 50) {
        _playUploads.removeAt(0);
      }
    } catch (_) {
      // A corrupt queue must not prevent startup; it is disposable data.
    }
  }

  Future<void> _persistPlayUploads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'lazer_play_uploads',
        jsonEncode(<Map<String, Object?>>[
          for (final report in _playUploads)
            <String, Object?>{
              'songId': report.songId,
              'kind': report.kind == _PlayLogKind.start ? 'start' : 'play',
              'seconds': report.seconds,
              'sourceId': report.sourceId,
            },
        ]),
      );
    } catch (_) {}
  }

  /// Drains the upload queue. A failed request stays at the head and is retried
  /// on the next track boundary or the next library refresh, so an offline
  /// spell does not silently lose plays.
  Future<void> _flushPlayUploads() async {
    if (isNavidrome) return;
    if (_playUploadInFlight || !signedIn) return;
    _playUploadInFlight = true;
    var uploaded = false;
    var uploadedPlay = false;
    try {
      while (_playUploads.isNotEmpty) {
        final _PlayReport report = _playUploads.first;
        try {
          if (report.kind == _PlayLogKind.start) {
            await catalog.reportPlayStart(
              songId: report.songId,
              sourceId: report.sourceId,
            );
          } else {
            await catalog.reportPlayback(
              songId: report.songId,
              playedSeconds: report.seconds,
              sourceId: report.sourceId,
            );
            uploadedPlay = true;
          }
          _playUploads.removeAt(0);
          uploaded = true;
        } catch (_) {
          break;
        }
      }
    } finally {
      _playUploadInFlight = false;
      final int uid = _user.userId;
      if (uploaded) {
        unawaited(_persistPlayUploads());
        if (uid > 0 && uploadedPlay) {
          await catalog.invalidatePlayStats(uid);
          // The loaded list predates this play; make the next library visit
          // fetch the updated record instead of short-circuiting on the old
          // in-memory copy.
          if (_playStatsUid == uid) _playStatsUid = null;
        }
      }
    }
  }

  final int _seedState = DateTime.now().millisecondsSinceEpoch;

  int _randomIndex(int n, {int? avoid}) {
    // Select a different queue index when shuffle is active.
    int r = (_seedState + n * 31 + (_avoidCounter++)) % n;
    if (avoid != null && r == avoid && n > 1) r = (r + 1) % n;
    return r;
  }

  int _avoidCounter = 0;

  static AuthOutcome _failure(Object error) =>
      AuthOutcome(false, error: _friendly(error));

  static String _maskPhone(String phone) {
    final String trimmed = phone.trim();
    if (trimmed.length <= 4) return trimmed;
    return '${trimmed.substring(0, 3)}****${trimmed.substring(trimmed.length - 4)}';
  }

  static String _cookieDetail(String cookie) {
    final int fields = cookie
        .split(';')
        .where((String s) => s.trim().isNotEmpty)
        .length;
    return '$fields 个字段';
  }

  static String _friendly(Object error) {
    if (error is MusicGatewayException) {
      return error.authenticationFailure
          ? '服务器拒绝了登录，请检查用户名和密码。'
          : '音乐服务器连接失败，请检查地址和网络后重试。';
    }
    if (error is GatewayHttpException) {
      return '网络请求失败（HTTP ${error.statusCode}）。';
    }
    if (error is GatewayProtocolException) return '服务返回了无法解析的数据。';
    if (error is GatewayServiceException) return '服务暂时拒绝了请求（${error.code}）。';
    if (error is ArgumentError) return error.message?.toString() ?? '输入无效。';
    return '连接失败，请检查网络后重试。';
  }

  @override
  void dispose() {
    _musicPlatforms.cancelPending();
    catalog.connections.close();
    _presentationDisposed = true;
    ++_seekRequest;
    playerPresented.dispose();
    browseTransitionActive.dispose();
    _paletteGeneration++;
    _queueActivity++;
    ++_generation;
    ++_lyricGeneration;
    // Detach the room controller before the tick lane it listens to is
    // disposed: the controller is lazy, so this may be its first access.
    listenTogether.dispose();
    _completionSubscription?.cancel();
    _bufferSubscription?.cancel();
    _indexSubscription?.cancel();
    _failureSubscription?.cancel();
    _bufferPulseTimer?.cancel();
    _ticker?.cancel();
    _tickNotifier.dispose();
    if (_ownsDownloadManager) downloadManager.dispose();
    super.dispose();
  }
}

enum LoopMode { off, all, one }

/// One queued upload for the account's play record.
enum _PlayLogKind { start, play }

class _PlayReport {
  const _PlayReport({
    required this.songId,
    required this.kind,
    this.seconds = 0,
    this.sourceId = 0,
  });

  final int songId;
  final _PlayLogKind kind;
  final int seconds;
  final int sourceId;
}

/// Transport heartbeat lane. `notifyListeners()` is @protected, so this thin
/// subclass exposes [pulse] for position and buffer updates that must not
/// rebuild whole screens (see AppState's transport note).
class _TickNotifier extends ChangeNotifier with BuildSafeNotifier {
  void pulse() => notifyListeners();
}

/// Format mm:ss.
String fmt(Duration d) {
  final int m = d.inMinutes;
  final int s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
