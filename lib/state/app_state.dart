// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/audio_engine.dart';
import '../audio/native/lazer_audio_engine.dart' show NativeAudioEngine;
import '../animation/apple_spring.dart';
import '../audio/hifi_controller.dart';
import '../cache/playback_cache.dart';
import '../cache/current_artwork.dart';
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
import '../lyrics/imported_lyrics_store.dart';
import '../listening/listening_statistics.dart';
import '../updates/release_version.dart';
import '../updates/update_checker.dart';
import '../utils/background_image.dart';
import '../ui/background.dart' show albumSeedForCover;
import 'build_safe_notifier.dart';
import 'listen_together.dart';
import 'media_shortcuts.dart';
import 'playback_queue_store.dart';
import 'shuffle_order.dart';
import 'hifi_settings.dart';
import 'ui_preferences.dart';
import 'scheduled_pause.dart';
import '../theme/font_preferences.dart';
import '../theme/imported_font.dart';
import '../plugins/plugin_manager.dart';

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
    this.membership,
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

  /// Optional membership tier (0 = none).
  final int? vipType;
  final String? membership;

  bool get isGuest => handle == '@guest';

  /// Membership badge text for the profile header; null when not a VIP.
  String? get vipLabel {
    if (!isGuest && membership?.isNotEmpty == true) return membership;
    final int type = vipType ?? 0;
    if (isGuest || type <= 0) return null;
    return '会员';
  }

  String get methodLabel => isGuest
      ? '游客模式'
      : switch (method) {
          AuthMethod.qrcode => '二维码登录',
          AuthMethod.sms => '短信验证码登录',
          AuthMethod.password => '密码登录',
          AuthMethod.cookie => 'Cookie 登录',
        };
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
    ListeningStatisticsController? listeningStatistics,
    UpdateChecker? updateChecker,
    this.audioEngine,
    this._independentPlayback = false,
    bool autoMixEnabled = false,
    this.enableExternalCharts = false,
    this.deviceIsTelevision = false,
    this.deviceIsWatch = false,
    this.deviceIsRoundWatch = false,
    this.hifiSettings = const HifiSettings(),
    this.hifi,
    this.hifiPathNotice,
    this.artworkSeedLoader = albumSeedForCover,
    this.startupBufferTarget = startupBuffer,
    this.startupBufferDeadline = startupBufferTimeout,
    this.startupByteTarget = startupBytes,
    PluginManager? pluginManager,
    this.scheduledPauseClock = DateTime.now,
    math.Random? shuffleRandom,
  }) : catalog = catalog ?? Catalog(),
       localLibrary = localLibrary ?? LocalLibrary(),
       _queueStore = queueStore ?? PlaybackQueueStore(),
       listeningStatistics =
           listeningStatistics ?? ListeningStatisticsController(),
       updateChecker = updateChecker ?? UpdateChecker(),
       pluginManager = pluginManager ?? PluginManager(),
       _shuffleOrder = ShuffleOrder(random: shuffleRandom) {
    this.pluginManager.beforeChange = _musicPlatforms.beforePluginChange;
    this.pluginManager.afterChange = _musicPlatforms.synchronizePlugins;
    _autoMixEnabled = autoMixEnabled;
    MotionTiming.speed = animationSpeed;
    if (deviceIsWatch) {
      backgroundMode = AppBackgroundMode.nowPlayingStatic;
      playerBackground = AppBackgroundMode.nowPlayingStatic;
    }
    this.importedLyrics = importedLyrics ?? ImportedLyricsStore();
    this.downloadManager =
        downloadManager ??
        DownloadManager(catalog: this.catalog, library: this.localLibrary);
    _ownsDownloadManager = downloadManager == null;
    // Begin loading the persisted gain as soon as the state exists.  Playback
    // can then open its first source without waiting on preferences again, and
    // the gain is still applied before the engine is allowed to play.
    unawaited(_loadVolumePreferences());
    playbackCache = PlaybackCacheController(
      audioCache: this.catalog.audioCache,
      library: this.localLibrary,
    );
    _completionSubscription = audioEngine?.completed.listen(
      (_) => _onEngineCompleted(),
    );
    // An engine that can hold a queue hands the next track over without a
    // reload; that hand-off arrives as an index change, never as a completion.
    _indexSubscription = _queueEngine?.indexStream.listen(_onEngineAdvanced);
    // Terminal failures of the native engine (device lost, decode error) have no
    // throw site to reach the load path, so they arrive here instead.
    final AudioEngine? engine = audioEngine;
    final FailureReportingAudioEngine? reporter =
        engine is FailureReportingAudioEngine
        ? engine as FailureReportingAudioEngine
        : null;
    _failureSubscription = reporter?.failures.listen(_onEngineFailure);
    // A launch-time downgrade happened before this constructor could subscribe,
    // so the stream cannot deliver it: take it from the engine (or from the
    // selection the app was built with) and keep it as a standing notice.
    hifiPathNotice = reporter?.pendingFailure?.message ?? hifiPathNotice;
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

  /// Installed Lua providers and extensions. Its lifecycle follows the app,
  /// while each plugin VM remains isolated from playback and UI state.
  final PluginManager pluginManager;

  static const scheduledPauseKey = 'lazer_scheduled_pause';
  ScheduledPauseSettings scheduledPause = ScheduledPauseSettings();
  late final ScheduledPauseController _pauseSchedule = ScheduledPauseController(
    now: () => scheduledPauseClock(),
    onPause: pause,
  );
  final DateTime Function() scheduledPauseClock;
  late final _pauseScheduleWriter = CoalescingWriter(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(scheduledPauseKey, scheduledPause.encode());
  });

  Future<void> setScheduledPause(ScheduledPauseSettings value) async {
    // "Enabled" describes a schedule, and a schedule with no enabled point can
    // never fire. Normalising here covers deleting the last point as well as a
    // stale preference that says enabled with an empty list.
    final ScheduledPauseSettings next =
        value.enabled && !value.points.any((point) => point.enabled)
        ? value.copyWith(enabled: false)
        : value;
    scheduledPause = next;
    _pauseSchedule.update(next);
    notifyListeners();
    await _pauseScheduleWriter.request();
  }

  void checkScheduledPause() => _pauseSchedule.check();

  /// Reconcile the UI with audio that kept running while frames were suspended.
  void synchronizePlaybackAfterResume() {
    if (_presentationDisposed) return;
    checkScheduledPause();
    if (_realActive && audioEngine?.active == true) {
      _sampleListening();
      _position = precisePosition;
    }
    if (_playing) _ensureTicker();
    _tickNotifier.pulse();
  }

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
  final bool deviceIsWatch;
  final bool deviceIsRoundWatch;

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

  /// The release currently shown by an update dialog, if any.
  ///
  /// Two presentation paths exist (the shell's automatic prompt and the
  /// settings button); this keeps them from stacking the same card twice.
  String? updateDialogVersion;

  /// When the last successful check happened, in milliseconds since epoch.
  int updateCheckedAt = 0;

  /// Whether an automatic check is due for [now].
  bool autoUpdateCheckDue({DateTime? now}) {
    final DateTime moment = now ?? DateTime.now();
    if (updateCheckedAt <= 0) return true;
    final elapsed = moment.millisecondsSinceEpoch - updateCheckedAt;
    // A corrected device clock must not suppress checks until a future date.
    return elapsed < 0 || elapsed >= updateCheckInterval.inMilliseconds;
  }

  /// Asks GitHub for a newer release.
  ///
  /// Returns null when the build is current, when an automatic check is not
  /// due, when the newest release was skipped, or when the network failed
  /// ([updateError] then says why). A [manual] check ignores both the daily
  /// cadence and a previous skip, because the user explicitly asked.
  ///
  /// A manual call made while an automatic check is running joins that request
  /// instead of returning immediately: "null" used to mean both "no update" and
  /// "did not check", so the settings button could report "已是最新版本" for a
  /// comparison that never ran.
  Future<AppRelease?> checkForUpdates({bool manual = false}) {
    final Future<AppRelease?>? pending = _updateCheckInFlight;
    if (pending != null) {
      return manual ? pending : Future<AppRelease?>.value(null);
    }
    if (!manual && !autoUpdateCheckDue()) {
      return Future<AppRelease?>.value(null);
    }
    final Future<AppRelease?> check = _runUpdateCheck(manual: manual);
    _updateCheckInFlight = check;
    return check.whenComplete(() {
      if (identical(_updateCheckInFlight, check)) _updateCheckInFlight = null;
    });
  }

  Future<AppRelease?>? _updateCheckInFlight;

  Future<AppRelease?> _runUpdateCheck({required bool manual}) async {
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

  /// Bounded playback downloads, also exposed in the local music library.
  late final PlaybackCacheController playbackCache;

  /// Imported `.lrc` files, which take priority over cloud lyrics.
  late final ImportedLyricsStore importedLyrics;

  Future<void> setIndependentPlayback(bool value) async {
    if (_independentPlayback == value) return;
    _independentPlayback = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_independent_playback', _independentPlayback);
  }

  /// Overlaps a prepared next song in the selected audio engine.
  bool _autoMixEnabled = false;
  bool get autoMixEnabled => _autoMixEnabled;
  String? autoMixError;
  Future<void> _autoMixOperations = Future<void>.value();

  Future<void> setAutoMixEnabled(bool value) {
    final result = _autoMixOperations.then((_) async {
      if (_autoMixEnabled == value && autoMixError == null) return;
      final engine = audioEngine;
      final resumeAt = precisePosition;
      try {
        if (engine is AutoMixConfigurableAudioEngine) {
          await (engine as AutoMixConfigurableAudioEngine).setAutoMixEnabled(
            value,
          );
        }
        _autoMixEnabled = value;
        autoMixError = null;
        // Switching between passthrough/integer and mixed PCM requires the
        // native decoder to reopen, using the same engine and output device.
        if (engine is NativeAudioEngine && _realActive && current != null) {
          await _startAudio(resumeAt: resumeAt);
        }
        await (await SharedPreferences.getInstance()).setBool(
          'lazer_automix_enabled',
          value,
        );
      } catch (_) {
        autoMixError = '当前音频引擎不支持无缝混音，请更新音频引擎。';
      }
      if (!_presentationDisposed) notifyListeners();
    });
    _autoMixOperations = result.catchError((Object _) {});
    return result;
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

  static const String _recentTracksKey = 'lazer_recent_tracks_v1';
  static const int _recentTracksLimit = 60;

  final Catalog catalog;
  late final _MusicPlatformState _musicPlatforms = _MusicPlatformState(this);
  MusicProvider get musicProvider => catalog.activeGateway.provider;
  bool get isLocalPlayback => catalog.activeGateway is LocalMusicGateway;
  String get activeConnectionKey =>
      GatewayRegistry.keyOf(catalog.activeGateway);
  String get activeContentKey => catalog.activeGateway.cacheNamespace;
  List<MusicGateway> get availableMusicPlatforms => musicConnections;
  Set<String> get musicAuthenticationMethods {
    final active = catalog.activeGateway;
    if (active is MusicAccountGateway) return active.authenticationMethods;
    return const {};
  }

  String? get musicLoginHint => (catalog.activeGateway is MusicAccountGateway)
      ? (catalog.activeGateway as MusicAccountGateway).loginHint
      : null;
  String? get musicCookieHint => (catalog.activeGateway is MusicAccountGateway)
      ? (catalog.activeGateway as MusicAccountGateway).cookieHint
      : null;
  String? get musicForgotPasswordUrl =>
      (catalog.activeGateway is MusicAccountGateway)
      ? (catalog.activeGateway as MusicAccountGateway).forgotPasswordUrl
      : null;
  Future<String?> exportSessionCookie() async {
    final active = catalog.activeGateway;
    return active is MusicAccountGateway ? active.exportCookie() : null;
  }

  bool get isLuaProvider => catalog.activeGateway is MusicAccountGateway;
  bool get hasNetworkProvider => !isLocalPlayback;

  String audioQualityLabel(AudioQuality value) => value.label;
  String audioQualityDetail(AudioQuality value) => value.detail;
  String audioQualityBitrate(AudioQuality value) => value.bitrateLabel;
  List<MusicGateway> get musicConnections => catalog.connections.connections;

  /// Signed-in accounts are independent from the selected catalogue source.
  Map<String, SessionUser> get musicAccounts => _musicPlatforms.accounts;
  bool get activeMusicSignedIn =>
      musicAccounts.containsKey(activeConnectionKey);
  bool get platformChanging => _musicPlatforms.busy;
  bool supportsMusic(MusicCapability capability) =>
      catalog.activeGateway.supports(capability);
  bool supportsCurrentMusic(MusicCapability capability) {
    final id = MusicId.tryParse(current?.id ?? '');
    if (id == null) return false;
    try {
      return catalog.connections.resolve(id).supports(capability);
    } catch (_) {
      return false;
    }
  }

  Future<void> selectMusicConnection(String key) => _musicPlatforms.select(key);
  late final ListenTogetherController listenTogether = ListenTogetherController(
    state: this,
  );
  StreamSubscription<void>? _completionSubscription;
  StreamSubscription<void>? _bufferSubscription;
  StreamSubscription<int>? _indexSubscription;
  StreamSubscription<AudioFailure>? _failureSubscription;
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
  int _volumeRevision = 0;
  Future<void>? _volumePreferences;
  double get volume => _volume;

  Future<void> _loadVolumePreferences() => _volumePreferences ??= () async {
    final revision = _volumeRevision;
    if (revision != 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_presentationDisposed || revision != _volumeRevision) return;
      _volume = (prefs.getDouble('lazer_volume') ?? 1).clamp(0, 1);
      _unmutedVolume =
          (prefs.getDouble('lazer_unmuted_volume') ??
                  (_volume > 0 ? _volume : 1))
              .clamp(.01, 1);
    } catch (_) {
      // Defaults remain available when settings storage is unavailable.
    }
  }();

  Future<void> setVolume(double value) async {
    if (!value.isFinite) return;
    _volumeRevision++;
    _volume = value.clamp(0, 1);
    if (_volume > 0) _unmutedVolume = _volume;
    notifyListeners();
    final AudioEngine? engine = audioEngine;
    await engine?.setVolume(_volume);
    final VolumeConstraintAudioEngine? limited =
        engine is VolumeConstraintAudioEngine
        ? engine as VolumeConstraintAudioEngine
        : null;
    if (limited != null) {
      final double applied = limited.appliedVolume.clamp(0, 1).toDouble();
      if ((applied - _volume).abs() > .001) {
        // Direct output owns the level: show what is really playing instead of
        // persisting a software volume the engine refused.
        _volume = applied;
        if (_volume > 0) _unmutedVolume = _volume;
        volumeNotice = '独占或 DSD 输出时音量由 DAC 控制，软件音量保持 100%。';
        notifyListeners();
        return;
      }
      volumeNotice = null;
    }
    // Persist the latest value even when several drag updates are in flight.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_volume', _volume);
    await prefs.setDouble('lazer_unmuted_volume', _unmutedVolume);
  }

  /// The last software-volume refusal, consumed by the volume control.
  String? volumeNotice;

  String? takeVolumeNotice() {
    final String? notice = volumeNotice;
    volumeNotice = null;
    return notice;
  }

  /// Live volume change for a drag in progress: updates the engine and the
  /// in-memory value without notifying the whole shell or touching prefs.
  /// Callers persist once on release with [setVolume].
  void previewVolume(double value) {
    if (!value.isFinite) return;
    _volumeRevision++;
    _volume = value.clamp(0, 1);
    if (_volume > 0) _unmutedVolume = _volume;
    final AudioEngine? engine = audioEngine;
    final double requested = _volume;
    unawaited(
      (() async {
        await engine?.setVolume(requested);
        if (engine is VolumeConstraintAudioEngine && _volume == requested) {
          final VolumeConstraintAudioEngine limited =
              engine as VolumeConstraintAudioEngine;
          final double applied = limited.appliedVolume.clamp(0, 1).toDouble();
          if ((applied - requested).abs() > .001) {
            _volume = applied;
            if (_volume > 0) _unmutedVolume = _volume;
            notifyListeners();
          }
        }
      })(),
    );
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

  /// Global speed multiplier for duration-based Apple spring animations.
  double animationSpeed = MotionTiming.defaultSpeed;

  static const String animationSpeedKey = 'lazer_animation_speed';

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

  /// App shell backdrop: the album-coloured flowing canvas, the listener's
  /// own picture, or off. Fresh installs start with the theme surface only.
  AppBackgroundMode backgroundMode = AppBackgroundMode.off;

  /// Stored copy of the picture used by [AppBackgroundMode.customImage].
  /// Null until the listener picks one; the canvas still renders without it.
  String? backgroundImagePath;

  /// `内容不透明度` of the app shell — how much of the backdrop the content
  /// veil hides.
  double uiAlpha = 0.7;
  double browseBackgroundFps = 30;
  double playerBackgroundFps = 0;
  AppBackgroundMode playerBackground = AppBackgroundMode.nowPlayingDynamic;
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

  Future<void> setPlayerBackground(AppBackgroundMode mode) async {
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

  Future<void> setAppBackground(AppBackgroundMode value) async {
    if (backgroundMode == value) return;
    backgroundMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_legacy_background',
      value.name,
    );
  }

  Future<void> setAppBackgroundImage(String? path) async {
    if (backgroundImagePath == path) return;
    backgroundImagePath = path;
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

  Future<void> setAppUiAlpha(double value) async {
    if (!value.isFinite) return;
    uiAlpha = value.clamp(0.4, 1.0);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_legacy_ui_alpha',
      uiAlpha,
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

  Future<void> setAnimationSpeed(double value) async {
    final double next = MotionTiming.normalize(value);
    if (animationSpeed == next) return;
    animationSpeed = next;
    MotionTiming.speed = next;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      animationSpeedKey,
      next,
    );
  }

  Future<void> resetAnimationSpeed() =>
      setAnimationSpeed(MotionTiming.defaultSpeed);

  double lyricControlsSeconds = 1.5;
  bool lyricBlurEnabled = true;
  bool showFrameStats = const bool.fromEnvironment('LAZER_FRAME_STATS');

  double lyricFontSize = 22;
  int lyricFontWeight = 600;
  FontPreferences fontPreferences = const FontPreferences();
  int _fontGeneration = 0;
  final ValueNotifier<bool> playerPresented = BuildSafeValueNotifier(false);
  final ValueNotifier<bool> browseTransitionActive = BuildSafeValueNotifier(
    false,
  );
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
  final CurrentArtworkCache currentArtwork = CurrentArtworkCache();
  int _paletteGeneration = 0;
  (String?, String?)? _paletteIdentity;

  /// Whether the current identity already spent its one retry.
  bool _paletteRetried = false;

  Future<void> refreshArtworkSeed() async {
    final Track? track = current;
    currentArtwork.update(track);
    final identity = (track?.id, track?.coverUrl);
    if (_paletteIdentity == identity) return;
    _paletteIdentity = identity;
    _paletteRetried = false;
    final int generation = ++_paletteGeneration;
    try {
      final seed = await artworkSeedLoader(track?.coverUrl);
      if (generation != _paletteGeneration) return;
      if (current?.id == track?.id && current?.coverUrl == track?.coverUrl) {
        setAppSeed(seed);
      }
      // A cover that yielded no seed — a rejected CDN node, artwork not in the
      // cache yet — is worth exactly one more attempt on the next report.
      // Latching the identity here would strand the accent on the previous
      // song's colour even though the artwork becomes readable a moment later.
      if (seed == null) _retryArtworkSeed(identity, track);
    } catch (_) {
      if (generation != _paletteGeneration) return;
      setAppSeed(null);
      _retryArtworkSeed(identity, track);
    }
  }

  /// Reopens the identity once so a failed extraction can be attempted again.
  ///
  /// Bounded on purpose: the state reports about ten times a second, and an
  /// artwork that is genuinely unreadable must not turn into a request storm.
  void _retryArtworkSeed((String?, String?)? identity, Track? track) {
    if (_paletteRetried || track?.coverUrl == null) return;
    if (_paletteIdentity != identity) return;
    _paletteRetried = true;
    _paletteIdentity = null;
  }

  String? importedEnginePath;

  /// Whether the mobile system media controls carry the current lyric line.
  ///
  /// Android's media notification and iOS's lock screen — including the
  /// Dynamic Island's now-playing card — both render their second line from
  /// the item's *artist* slot, and neither platform exposes a lyrics key. On,
  /// that slot follows the song on Android and iOS; off — and on the desktop
  /// controls, which other applications read — it keeps the artist name.
  bool systemMediaLyrics = true;

  Future<void> setSystemMediaLyrics(bool value) async {
    if (systemMediaLyrics == value) return;
    systemMediaLyrics = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_system_media_lyrics',
      value,
    );
  }

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
    _fontGeneration++;
    fontPreferences = const FontPreferences();
    lyricFontSize = 22;
    lyricFontWeight = 600;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lazer_font_preferences');
    await prefs.remove('lazer_lyric_font_size');
    await prefs.remove('lazer_lyric_font_weight');
  }

  Future<void> setFontFamily(FontFamilyPreference value) async {
    final generation = ++_fontGeneration;
    await ImportedFont.load(value);
    if (generation != _fontGeneration) return;
    fontPreferences = fontPreferences.withFamily(value);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_font_preferences',
      fontPreferences.encode(),
    );
  }

  Future<void> importFont(Uint8List bytes, String name) async {
    final generation = ++_fontGeneration;
    final preference = await ImportedFont.importFile(bytes, name);
    if (generation != _fontGeneration) return;
    await setFontFamily(preference);
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

  /// The app shell's accent palette: the fixed Lazer scheme, one seeded
  /// from the current cover like the app's "follow the song" palette, or the
  /// listener's own colour.
  AppPaletteMode paletteMode = AppPaletteMode.fixed;

  /// The accent picked in [AppPaletteMode.custom]; null until the listener
  /// chooses one, in which case the shipped red remains in effect.
  Color? accentColor;

  /// The last artwork seed the compatibility backdrop extracted; only used while
  /// [paletteMode] is [AppPaletteMode.nowPlaying].
  Color? artworkSeed;

  /// The accent seed handed to the Apple theme builders. Null keeps the
  /// shipped Apple Music red.
  Color? get accentSeed => switch (paletteMode) {
    AppPaletteMode.fixed => null,
    AppPaletteMode.nowPlaying => artworkSeed,
    AppPaletteMode.custom => accentColor,
  };

  Future<void> setAppPalette(AppPaletteMode value) async {
    if (paletteMode == value) return;
    paletteMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_legacy_palette',
      value.name,
    );
  }

  Future<void> setAppAccent(Color value) async {
    if (accentColor == value) return;
    accentColor = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      'lazer_legacy_accent',
      value.toARGB32(),
    );
  }

  void setAppSeed(Color? value) {
    if (artworkSeed == value) return;
    artworkSeed = value;
    // The fixed palette does not consume the seed; rebuilding the whole shell
    // for it on every track change was pure work.
    if (paletteMode == AppPaletteMode.nowPlaying) notifyListeners();
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

  /// Why this session is not on the native HiFi path, or null when it is.
  ///
  /// Set at launch when the native engine could not start, and again when a
  /// running native session fails terminally. The player renders it, because a
  /// downgrade that only reached the log looks exactly like a HiFi session to
  /// the person listening.
  String? hifiPathNotice;

  /// Whether the native HiFi engine is the running playback path.
  bool get hifiPathIsNative => hifiPathNotice == null;
  UserCollections collections = UserCollections.empty;
  bool collectionsLoading = false;
  String? collectionsError;
  Future<void>? _collectionsPending;
  int _collectionsGeneration = 0;

  /// All-time play counts, joined with song durations for 听歌排行.
  List<TrackPlayStat> playStats = const <TrackPlayStat>[];
  bool playStatsLoading = false;
  String? playStatsError;
  int? _playStatsUid;

  /// Loads the play record once per account. The library asks for it lazily;
  /// a guest never issues the request.
  Future<void> loadPlayStats({bool force = false}) async {
    if (!hasNetworkProvider) return;
    final int uid = user.userId;
    final namespace = activeContentKey;
    bool stillCurrent() =>
        !_presentationDisposed &&
        user.userId == uid &&
        activeContentKey == namespace;
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
      if (!stillCurrent()) return;
      final List<TrackPlayStat> loaded = await catalog.playStats(
        uid,
        force: force,
      );
      if (!stillCurrent()) return;
      playStats = loaded;
    } catch (_) {
      if (stillCurrent()) {
        playStatsError = '播放记录加载失败，请稍后重试。'; // i18n:key
      }
    } finally {
      if (stillCurrent()) {
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
    final owner = catalog.activeGateway;
    final generation = _collectionsGeneration;
    bool stillCurrent() =>
        !_presentationDisposed &&
        generation == _collectionsGeneration &&
        user.userId == uid &&
        activeConnectionKey == connection;
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
        if (stored != null && stillCurrent()) {
          collections = stored;
          _musicPlatforms.rememberCollections(owner, stored);
          notifyListeners();
        }
      }
      if (!stillCurrent()) return;
      final loaded = await catalog.userCollections(uid);
      if (stillCurrent()) {
        collections = loaded;
        _musicPlatforms.rememberCollections(owner, loaded);
      }
    } catch (_) {
      if (stillCurrent()) {
        collectionsError = '歌单读取失败，请重试。';
      }
    } finally {
      if (stillCurrent()) {
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
  final _lyricSnapshots = <(String, String, String?), _LyricsSnapshot>{};
  ((String, String, String?), Future<void>)? _lyricRequest;
  final Set<String> _metadataLoaded = <String>{};
  final Set<String> _metadataPending = <String>{};
  String? likeError;
  bool get currentLiked =>
      current != null && _musicPlatforms.isLiked(current!.id);
  int get likedCount => collections.liked?.trackCount ?? 0;
  bool get online => catalog.online;

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
    final initialPlayModeRevision = _playModeRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_playModeRevision == initialPlayModeRevision) {
        final mode = prefs.getString(_playModeKey);
        _shuffle =
            mode == 'shuffle' || mode == 'shuffle:all' || mode == 'shuffle:one';
        _repeat = switch (mode) {
          'all' || 'shuffle:all' => LoopMode.all,
          'one' || 'shuffle:one' => LoopMode.one,
          _ => LoopMode.off,
        };
        _shuffleOrder.reset();
      }
      final storedPause = prefs.getString(scheduledPauseKey);
      scheduledPause = ScheduledPauseSettings.decode(storedPause);
      final encodedPause = scheduledPause.encode();
      if (storedPause != null && storedPause != encodedPause) {
        await prefs.setString(scheduledPauseKey, encodedPause);
      }
      _pauseSchedule.update(scheduledPause);
      _independentPlayback =
          prefs.getBool('lazer_independent_playback') ?? _independentPlayback;
      _autoMixEnabled =
          prefs.getBool('lazer_automix_enabled') ?? _autoMixEnabled;
      if (audioEngine is AutoMixConfigurableAudioEngine) {
        try {
          await (audioEngine as AutoMixConfigurableAudioEngine)
              .setAutoMixEnabled(_autoMixEnabled);
        } catch (_) {
          _autoMixEnabled = false;
          autoMixError = '当前音频引擎不支持无缝混音，请更新音频引擎。';
        }
      }
      hapticsEnabled = prefs.getBool('lazer_haptics') ?? true;
      hapticIntensity = (prefs.getDouble('lazer_haptic_intensity') ?? 0.5)
          .clamp(0, 1);
      themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == prefs.getString('lazer_theme_mode'),
        orElse: () => ThemeMode.system,
      );
      language = AppLanguage.parse(prefs.getString('lazer_language'));
      backgroundMode = AppBackgroundModeLabels.parse(
        prefs.getString('lazer_legacy_background') ??
            (deviceIsWatch ? AppBackgroundMode.nowPlayingStatic.name : null),
      );
      playerBackground = AppBackgroundModeLabels.parse(
        prefs.getString('lazer_player_background') ??
            (deviceIsWatch
                ? AppBackgroundMode.nowPlayingStatic.name
                : AppBackgroundMode.nowPlayingDynamic.name),
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
      backgroundImagePath = restoredBackgroundImage;
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
      uiAlpha = (prefs.getDouble('lazer_legacy_ui_alpha') ?? 0.7).clamp(
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
      animationSpeed = MotionTiming.normalize(
        prefs.getDouble(animationSpeedKey) ?? MotionTiming.defaultSpeed,
      );
      MotionTiming.speed = animationSpeed;
      autoDpiScale = prefs.getBool('lazer_auto_dpi_scale') ?? true;
      if (_volumeRevision == 0) {
        _volume = (prefs.getDouble('lazer_volume') ?? 1).clamp(0, 1);
        _unmutedVolume =
            (prefs.getDouble('lazer_unmuted_volume') ??
                    (_volume > 0 ? _volume : 1))
                .clamp(.01, 1);
      }
      _volumePreferences = Future<void>.value();
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
      try {
        await ImportedFont.load(fontPreferences.family);
      } catch (_) {
        fontPreferences = fontPreferences.withFamily(
          const FontFamilyPreference(),
        );
        // The imported file is gone: rewrite the preference instead of
        // retrying (and silently falling back) on every launch.
        try {
          await prefs.setString(
            'lazer_font_preferences',
            fontPreferences.encode(),
          );
        } catch (_) {
          // Preference storage is unavailable; the in-memory fallback stands.
        }
      }
      importedEnginePath = prefs.getString('lazer_native_engine_path');
      systemMediaLyrics = prefs.getBool('lazer_system_media_lyrics') ?? true;
      await prefs.remove('lazer_show_artwork_with_lyrics');
      paletteMode = AppPaletteModeLabels.parse(
        prefs.getString('lazer_legacy_palette'),
      );
      final int? accent = prefs.getInt('lazer_legacy_accent');
      accentColor = accent == null ? null : Color(accent);
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
    // These are independent startup lanes. A large local manifest, cache
    // eviction on an external drive or an audio-device round trip must not
    // postpone the home request or the restored queue. The cache itself joins
    // LocalLibrary.load(), so concurrent loading still reads its index once.
    // Keep bootstrap's completion contract: callers can await every lane.
    await Future.wait<void>(<Future<void>>[
      localLibrary.load(),
      playbackCache.load(),
      audioEngine?.setVolume(_volume) ?? Future<void>.value(),
      _restorePlaybackSnapshot(initialQueueActivity),
      _restoreCatalogSession(),
    ]);
    unawaited(_refreshMissingArtwork());
  }

  Future<void> _refreshMissingArtwork() async {
    // Start after both playback records and plugin sessions are restored.
    // Keep requests bounded and independent from playback and queue order.
    final restored = <String, Track>{
      for (final track in _recentTracks) track.id: track,
    };
    final selected = current;
    if (selected != null) restored[selected.id] = selected;
    final tracks = restored.values
        .where((track) => track.coverUrl?.trim().isNotEmpty != true)
        .toList();
    var next = 0;
    Future<void> worker() async {
      while (!_presentationDisposed && next < tracks.length) {
        final track = tracks[next++];
        if (MusicId.tryParse(track.id) case final reference?) {
          await _musicPlatforms.hydrate(track, reference);
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(4, tracks.length); i++) worker(),
    ]);
  }

  Future<void> _restorePlaybackSnapshot(int initialQueueActivity) async {
    await _restoreRecentTracks();
    await _restoreQueue(initialQueueActivity);
    if (_presentationDisposed) return;
    unawaited(_loadCurrentArtwork());
    unawaited(ensureCurrentLyrics());
  }

  Future<void> _restoreCatalogSession() async {
    await pluginManager.restore();
    if (_presentationDisposed) return;
    await _musicPlatforms.synchronizePlugins(refresh: false);
    if (_presentationDisposed) return;
    await _musicPlatforms.restore();
    if (_presentationDisposed) return;
    if (signedIn) unawaited(_flushPlayUploads());
    unawaited(_refreshMissingArtwork());
    await refreshHome();
  }

  Future<void> refreshHome({bool force = false}) async {
    if (_presentationDisposed) return;
    if (force) {
      await catalog.invalidateHome(userId: signedIn ? _user.userId : null);
    }
    if (_presentationDisposed) return;
    unawaited(refreshCollections());
    await catalog.loadHome(userId: _user.userId);
    if (_presentationDisposed) return;
    notifyListeners();
    if (enableExternalCharts) {
      unawaited(refreshDiscoveryCharts(force: force));
    }
  }

  Future<void> refreshDiscoveryCharts({bool force = false}) async {
    if (!hasNetworkProvider) {
      discoveryCharts = const [];
      discoveryChartsError = null;
      return;
    }
    if (discoveryChartsLoading) {
      // A platform switch during a slow chart load used to be dropped, leaving
      // the new provider with no charts until the next manual retry.
      _discoveryRefreshQueued = true;
      return;
    }
    final String connection = activeContentKey;
    discoveryChartsLoading = true;
    discoveryChartsError = null;
    notifyListeners();
    try {
      if (force) await catalog.invalidateDiscoveryCharts();
      final externalFuture = catalog.discoveryCharts().catchError(
        (_) => const <MusicChart>[],
      );
      try {
        final provider = await catalog.providerCharts();
        if (connection != activeContentKey) {
          _discoveryRefreshQueued = true;
          return;
        }
        if (provider.isNotEmpty) {
          discoveryCharts = _sortDiscoveryCharts(provider);
          notifyListeners();
        }
      } catch (_) {
        // External charts remain available when the music provider is offline.
      }

      final external = await externalFuture;
      if (connection != activeContentKey) {
        _discoveryRefreshQueued = true;
        return;
      }
      if (external.isNotEmpty) {
        final ids = discoveryCharts.map((chart) => chart.id).toSet();
        discoveryCharts = _sortDiscoveryCharts(<MusicChart>[
          ...discoveryCharts,
          ...external.where((chart) => ids.add(chart.id)),
        ]);
      }
      if (discoveryCharts.isEmpty) discoveryChartsError = '暂无榜单数据';
    } catch (_) {
      if (connection == activeContentKey && discoveryCharts.isEmpty) {
        discoveryChartsError = '榜单暂时连接不上';
      }
    } finally {
      discoveryChartsLoading = false;
      notifyListeners();
      if (_discoveryRefreshQueued) {
        _discoveryRefreshQueued = false;
        unawaited(refreshDiscoveryCharts());
      }
    }
  }

  bool _discoveryRefreshQueued = false;

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

  Future<AuthOutcome> signInWithCookie(String cookie) async {
    try {
      final active = catalog.activeGateway;
      if (active is MusicAccountGateway) {
        final user = await active.loginWithCookie(cookie);
        if (user == null) {
          return const AuthOutcome(false, error: '这个 Cookie 无效或已过期。');
        }
        return _adoptAccountLogin(
          user,
          AuthMethod.cookie,
          active.provider.name,
          owner: active,
        );
      }
      return const AuthOutcome(false, error: '请先安装并启用音乐平台插件。');
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> signInWithPhonePassword(
    String phone,
    String password, {
    String countryCode = '86',
  }) async {
    try {
      final active = catalog.activeGateway;
      if (active is MusicAccountGateway) {
        return _adoptAccountLogin(
          await active.loginWithPassword(phone, password),
          AuthMethod.password,
          _maskPhone(phone),
          owner: active,
        );
      }
      return const AuthOutcome(false, error: '请先安装并启用音乐平台插件。');
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> signInWithEmail(String email, String password) async {
    try {
      final active = catalog.activeGateway;
      if (active is MusicAccountGateway) {
        return _adoptAccountLogin(
          await active.loginWithPassword(email, password),
          AuthMethod.password,
          _maskEmail(email),
          owner: active,
        );
      }
      return const AuthOutcome(false, error: '请先安装并启用音乐平台插件。');
    } catch (error) {
      return _failure(error);
    }
  }

  /// Password sign-in with one account field: an address containing `@` is an
  /// email/passport account, everything else is treated as a phone number.
  Future<AuthOutcome> signInWithPassword(
    String account,
    String password, {
    String countryCode = '86',
  }) {
    final String trimmed = account.trim();
    if (trimmed.isEmpty) {
      return Future<AuthOutcome>.value(
        const AuthOutcome(false, error: '请输入手机号或邮箱。'),
      );
    }
    if (password.isEmpty) {
      return Future<AuthOutcome>.value(
        const AuthOutcome(false, error: '请输入密码。'),
      );
    }
    return trimmed.contains('@')
        ? signInWithEmail(trimmed, password)
        : signInWithPhonePassword(trimmed, password, countryCode: countryCode);
  }

  Future<AuthOutcome> signInWithPhoneCaptcha(
    String phone,
    String captcha,
  ) async {
    try {
      final active = catalog.activeGateway;
      if (active is MusicAccountGateway) {
        return _adoptAccountLogin(
          await active.loginWithCaptcha(phone, captcha),
          AuthMethod.sms,
          _maskPhone(phone),
          owner: active,
        );
      }
      return const AuthOutcome(false, error: '请先安装并启用音乐平台插件。');
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> sendSmsCode(String phone) async {
    try {
      final active = catalog.activeGateway;
      if (active is MusicAccountGateway) {
        await active.sendCaptcha(phone);
        return const AuthOutcome(true);
      }
      return const AuthOutcome(false, error: '请先安装并启用音乐平台插件。');
    } catch (error) {
      return _failure(error);
    }
  }

  AuthOutcome _adoptAccountLogin(
    MusicUser? user,
    AuthMethod method,
    String detail, {
    required MusicAccountGateway owner,
  }) {
    if (user == null) return const AuthOutcome(false, error: '登录失败，请稍后再试。');
    if (_presentationDisposed ||
        !musicConnections.contains(owner) ||
        owner.user?.id != user.id) {
      return const AuthOutcome(false, error: '连接已切换。');
    }
    final account = SessionUser(
      name: user.name,
      handle: user.id.cacheKey,
      method: method,
      detail: detail,
      userId: int.tryParse(user.id.value) ?? 1,
      avatarUrl: user.avatarUrl,
      signature: user.signature,
      membership: user.membership,
    );
    _musicPlatforms.adoptLogin(owner, account);
    return const AuthOutcome(true);
  }

  /// Starts a QR session and returns the scan URL, or null on failure.
  Future<String?> beginQrLogin() async {
    _qrConfirmed = false;
    qrPollError = null;
    qrStartError = null;
    try {
      final active = catalog.activeGateway;
      if (active is MusicAccountGateway) {
        final key = await active.qrKey();
        if (key == null || key.isEmpty) return null;
        final url = await active.qrUrl(key);
        return url.isEmpty ? null : url;
      }
      qrStartError = '请先安装并启用支持扫码登录的插件。';
      return null;
    } catch (error) {
      qrStartError = _friendly(error);
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
  String? qrStartError;

  /// Polls a QR key: 800 expired, 801 waiting, 802 scanned, 803 confirmed,
  /// 8821 needs a security check on the phone.
  ///
  /// Only 803 means "this session is signed in": the scan URL was rejected by
  /// the phone when the poll never leaves 801, and a not-yet-ready account
  /// after 803 must not be mistaken for an expired key either.
  Future<int> pollQrLogin(String url) async {
    final owner = catalog.activeGateway;
    if (owner is MusicAccountGateway) {
      try {
        if (_qrConfirmed) {
          final user = await owner.checkSession();
          if (!identical(owner, catalog.activeGateway) ||
              _presentationDisposed) {
            return 800;
          }
          if (user != null) {
            _adoptAccountLogin(
              user,
              AuthMethod.qrcode,
              owner.provider.name,
              owner: owner,
            );
            return 803;
          }
          return 802;
        }
        final code = await owner.qrCheck(url);
        if (!identical(owner, catalog.activeGateway) || _presentationDisposed) {
          return 800;
        }
        qrPollError = null;
        if (code == 803) {
          _qrConfirmed = true;
          final user = await owner.checkSession();
          if (!identical(owner, catalog.activeGateway) ||
              _presentationDisposed) {
            return 800;
          }
          if (user == null) return 802;
          _adoptAccountLogin(
            user,
            AuthMethod.qrcode,
            owner.provider.name,
            owner: owner,
          );
        }
        return code;
      } catch (error) {
        qrPollError = _friendly(error);
        return 801;
      }
    }
    return 800;
  }

  /// Back to the guest session — stay in the shell, drop the credentials.
  Future<void> signOut({String? connectionKey}) async {
    final selected = connectionKey == null
        ? catalog.activeGateway
        : musicConnections.firstWhere(
            (gateway) => GatewayRegistry.keyOf(gateway) == connectionKey,
          );
    final owner = selected is LocalMusicGateway
        ? _musicPlatforms.lastSessionGateway
        : selected;
    if (owner != null) await _musicPlatforms.signOut(owner);
  }

  // -- catalogue actions ----------------------------------------------------

  Future<SearchResults> search(String query) async {
    if (!isLocalPlayback) return catalog.search(query);
    await localLibrary.load();
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return SearchResults.empty;
    return SearchResults(
      tracks: localLibrary.playableTracks.where((track) {
        final text =
            '${track.title} ${track.translatedTitle ?? ''} ${track.artist} ${track.album}'
                .toLowerCase();
        return terms.every(text.contains);
      }).toList(),
    );
  }

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
    if (!hasNetworkProvider) {
      throw StateError('请先切换到已登录的音乐平台。');
    }
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('name cannot be blank.');
    return _musicPlatforms.createPlaylist(trimmed, privacy);
  }

  /// Adds [trackId] to one of the account's cloud playlists.
  ///
  /// Adding to 我喜欢的音乐 is the service's "like" action, so the local heart
  /// state follows immediately; every playlist's cached track list is
  /// invalidated so opening it shows the new song.
  Future<void> addSongToCloudPlaylist(String playlistId, String trackId) =>
      _musicPlatforms.addSong(playlistId, trackId);

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
  final ListeningStatisticsController listeningStatistics;
  int _listeningRevision = 0;
  int? _pendingListeningSeek;
  int _queueActivity = 0;
  List<Track> _recentTracks = <Track>[];
  int _queueIndex = 0;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _shuffle = false;
  LoopMode _repeat = LoopMode.off;
  static const _playModeKey = 'lazer_play_mode_v1';
  int _playModeRevision = 0;
  Future<void> _playModeWrites = Future<void>.value();
  final ShuffleOrder _shuffleOrder;
  (bool, LoopMode)? _stationPlayMode;
  bool _realActive = false;

  /// Whether the source was closed with a usable position still on the rail.
  ///
  /// [suspendForInterruption] and [suspendForRouteLoss] stop the engine but keep
  /// the playhead, and a failed open stops it too. Play must reopen at that
  /// position instead of starting the song from zero; a track that ran to its
  /// end clears the flag because the rail there is a full-length artifact.
  bool _resumePositionOnOpen = false;
  Future<void>? _audioOpening;
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

  /// The URL that was handed to the engine for [_queuedNextIndex].
  ///
  /// The engine reports the URL it actually crossed into, and comparing the two
  /// is what proves the mixed-in song is the one this queue scripted instead of a
  /// successor a racing preparation replaced.
  String? _queuedNextUrl;

  /// Serialises successor preparations: only the newest one may bind the index.
  int _prefetchGeneration = 0;

  /// The queue index an audible overlap was mixed out of, so a rollback can
  /// return to exactly that song (shuffle is not `index - 1`).
  int? _mixFromIndex;

  /// Forgets the successor the app believes the engine holds.
  void _clearQueuedNext() {
    _queuedNextIndex = null;
    _queuedNextUrl = null;
  }

  /// Whether the engine really has a successor prepared to cross into.
  ///
  /// An engine that cannot answer (a plain single-source backend) keeps the
  /// app's own belief, which is all it had before.
  bool get _engineHoldsSuccessor {
    final QueueAudioEngine? engine = _queueEngine;
    if (engine is! QueuedSourceReportingAudioEngine) {
      return _queuedNextIndex != null;
    }
    final String? held =
        (engine as QueuedSourceReportingAudioEngine).queuedSourceUrl;
    if (held == null) return false;
    return _queuedNextUrl == null || held == _queuedNextUrl;
  }

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

  List<Track> get recentTracks {
    if (isLocalPlayback) {
      final available = {
        for (final track in localLibrary.playableTracks) track.id: track,
      };
      return List.unmodifiable(
        _recentTracks.map((track) => available[track.id]).whereType<Track>(),
      );
    }
    return List<Track>.unmodifiable(
      _recentTracks.where((track) {
        if (track.localPath != null) return true;
        final reference = MusicId.tryParse(track.id);
        if (reference == null) return false;
        try {
          catalog.connections.resolve(reference);
          return true;
        } catch (_) {
          return false;
        }
      }),
    );
  }

  /// Counts without allocating an immutable snapshot of the queue.
  int get queueLength => _queue.length;
  Track? get current =>
      _queue.isEmpty ? null : _queue[_queueIndex.clamp(0, _queue.length - 1)];
  Duration get position => _position;
  Duration? _optimisticSeek;
  int _optimisticSeekGeneration = 0;
  int _seekRequest = 0;
  final Stopwatch _optimisticSeekClock = Stopwatch();

  /// Longest a seek target is published before the engine's own clock wins.
  ///
  /// The hold normally ends when the engine reports a position that agrees with
  /// the target. This is the backstop for a seek the demuxer never applies (a
  /// dead download, a source that cannot seek) so the rail cannot be pinned
  /// forever by a stale request.
  static const Duration _optimisticSeekCeiling = Duration(seconds: 20);

  /// Whether a seek has been requested and not yet seen in the engine's clock.
  bool get seekInFlight => _optimisticSeek != null;

  /// The position the rail is showing, which for a seek being applied is the
  /// target rather than where the engine's clock still is.
  Duration get precisePosition {
    final bool active = _realActive && audioEngine?.active == true;
    final Duration actual = active ? audioEngine!.position : _position;
    final Duration? pending = _optimisticSeek;
    if (pending == null) return actual;
    if (_optimisticSeekGeneration != _generation) {
      _clearOptimisticSeek();
      return actual;
    }
    // Until the demuxer applies the seek the engine keeps reporting the position
    // it had *before* the jump. Publishing that value snaps the rail back, and
    // when the seek ran from near the start of the track it reads as "从头开始".
    // The target is therefore published until the engine's clock agrees with it,
    // or the ceiling expires.
    final bool landed =
        active && (actual - pending).abs() <= const Duration(milliseconds: 500);
    if (!landed && _optimisticSeekClock.elapsed < _optimisticSeekCeiling) {
      return pending;
    }
    _clearOptimisticSeek();
    return actual;
  }

  void _clearOptimisticSeek() {
    _optimisticSeek = null;
    _optimisticSeekClock
      ..reset()
      ..stop();
  }

  bool get playing => _playing;

  /// Whether the engine is ready to make sound for the current track.
  ///
  /// A track still filling its startup buffer is not ready: the system media
  /// controls read this to report `loading` instead of a track that looks
  /// playing while the playhead stands at zero. A stream whose download died
  /// underneath the decoder reports the same thing, because from the listener's
  /// side nothing is moving either.
  bool get audioReady =>
      _realActive && !buffering && (audioEngine?.active ?? false);
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

  /// The lyric being sung at [precisePosition], or null when there is none.
  ///
  /// The same binary search the lyric viewport uses, with two differences the
  /// system media controls need: an instrumental or blank line falls back to
  /// the last line that had words, and a sheet that has not started yet yields
  /// nothing rather than its first line.
  LyricLine? get currentLyricLine {
    final List<LyricLine> lines = lyrics;
    if (lines.isEmpty) return null;
    final Duration position = precisePosition;
    var low = 0;
    var high = lines.length;
    while (low < high) {
      final int middle = (low + high) ~/ 2;
      if (lines[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (var index = low - 1; index >= 0; index--) {
      if (lines[index].text.trim().isNotEmpty) return lines[index];
    }
    return null;
  }

  /// How much of the current track the engine has buffered, 0…1.
  ///
  /// The now-playing seek rail paints this behind the played fraction. The
  /// plain [AudioEngine] contract carries no buffer information, so engines
  /// without [BufferedAudioEngine] fall back to the playhead.
  ///
  /// The playhead is always included: a backend whose reported buffer trails
  /// the position (a source that ran out of its local file, say) must not make
  /// the region already played look unbuffered.
  double get bufferedFraction {
    final Track? t = current;
    final int duration = t?.duration.inMilliseconds ?? 0;
    if (duration <= 0) return 0;
    if (audioEngine == null) return 0;
    if (!_seekLimitedByBuffer) return 1;
    final AudioEngine engine = audioEngine!;
    final Duration playhead = precisePosition;
    final Duration buffered = engine is BufferedAudioEngine
        ? (engine as BufferedAudioEngine).bufferedPosition
        : playhead;
    final Duration available = buffered > playhead ? buffered : playhead;
    return (available.inMilliseconds / duration).clamp(0.0, 1.0);
  }

  /// Seeking can move through buffered audio, but never past it.
  /// Keep the current playhead reachable if a backend reports a shorter buffer.
  ///
  /// The download is the only source of bytes, so the part of a streaming track
  /// that has not landed is not reachable: the rail stops at it and the buffer bar
  /// shows how far that is. A local file, or a fully downloaded stream, is open
  /// end to end.
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
    if (_stationPlayMode case final saved?) {
      _shuffle = saved.$1;
      _repeat = saved.$2;
      _stationPlayMode = null;
    }
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
    _stationPlayMode ??= (_shuffle, _repeat);
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
    checkScheduledPause();
    if (tracks.isEmpty) return;
    _finishListening(
      manualTarget: tracks[startIndex.clamp(0, tracks.length - 1)],
    );
    _finishPlaySession();
    trackChangeDirection = 1;
    _queue = List<Track>.of(tracks);
    _shuffleOrder.reset();
    _markQueueChanged();
    _queueIndex = startIndex.clamp(0, tracks.length - 1);
    unawaited(_saveQueue());
    _position = Duration.zero;
    _resumePositionOnOpen = false;
    playbackError = null;
    unawaited(_loadLyrics());
    _ensureTicker();
    _playing = true;
    unawaited(_startAudio());
    notifyListeners();
  }

  void togglePlay() {
    final shouldPlay = !_playing;
    checkScheduledPause();
    if (current == null) return;
    if (!shouldPlay) {
      _sampleListening();
      listeningStatistics.suspend();
      unawaited(listeningStatistics.flush());
    }
    _playing = shouldPlay;
    if (_playing) {
      _ensureTicker();
      if (_realActive) {
        unawaited(_resumeAudio());
      } else {
        _openForPlayback();
      }
    } else {
      _ticker?.cancel();
      if (_realActive) unawaited(audioEngine!.pause());
    }
    notifyListeners();
  }

  void play() {
    checkScheduledPause();
    if (current == null || _playing) return;
    _playing = true;
    _ensureTicker();
    if (_realActive) {
      unawaited(_resumeAudio());
    } else {
      _openForPlayback();
    }
    notifyListeners();
  }

  /// Opens the output for a play request.
  ///
  /// When the source was closed underneath the listener (audio focus went to
  /// another app, the route was lost, the open failed) the rail still shows where
  /// they were. Reopening at that position is what makes Play continue the song;
  /// opening at zero and letting the first tick overwrite the rail is the
  /// "pressing play restarts my track" report.
  void _openForPlayback() {
    playbackError = null;
    final Duration? resumeAt =
        _resumePositionOnOpen && _position > Duration.zero ? _position : null;
    _resumePositionOnOpen = false;
    unawaited(_startAudio(resumeAt: resumeAt));
  }

  void pause() {
    if (!_playing) return;
    _sampleListening();
    listeningStatistics.suspend();
    unawaited(listeningStatistics.flush());
    _playing = false;
    _ticker?.cancel();
    if (_realActive) unawaited(audioEngine!.pause());
    _flushQualifiedSession();
    notifyListeners();
  }

  /// Gives the output device back to the platform, keeping the place in the track.
  ///
  /// Audio focus loss, a phone call, another application starting playback or an
  /// unplugged route all mean the platform has handed the endpoint to someone
  /// else. Pausing alone would leave the engine holding it — a shared-mode AAudio
  /// stream parked in PAUSED still owns the device, and the platform reclaims it,
  /// which is the disconnect the app then fails on. The source is dropped here
  /// and opened again by [resumeAfterInterruption] (or by the next play) at the
  /// position below, so the output is only held while it may be played.
  Future<void> suspendForInterruption() async {
    if (!_realActive) return;
    final Duration at = precisePosition;
    _playing = false;
    _ticker?.cancel();
    _realActive = false;
    _position = at;
    _resumePositionOnOpen = at > Duration.zero;
    // The engine's queue went with the output; the next open builds a fresh one.
    _clearQueuedNext();
    _queueId = null;
    _flushQualifiedSession();
    notifyListeners();
    final AudioEngine? engine = audioEngine;
    if (engine != null) await engine.stop();
  }

  /// Opens the output again and continues where [suspendForInterruption] stopped.
  ///
  /// Only meaningful for an engine that yielded the device: it is a fresh open at
  /// the interrupted position, not a resume of a stream that was parked.
  Future<void> resumeAfterInterruption() async {
    if (current == null || _playing) return;
    playbackError = null;
    _playing = true;
    _ensureTicker();
    notifyListeners();
    await _reopenOutput(_position, '播放中断，请重试。');
  }

  void stop() {
    _finishListening();
    _finishPlaySession();
    ++_generation;
    _playing = false;
    _realActive = false;
    _clearQueuedNext();
    _queueId = null;
    _position = Duration.zero;
    _resumePositionOnOpen = false;
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
    _finishListening(manualTarget: _queue[target]);
    // When the following track is already in the engine's queue, jumping to it
    // keeps the decoder running instead of reloading (an audible gap).
    _moveTo(target, direction: 1, gapless: target == _queuedNextIndex);
  }

  void previous() {
    if (_queue.isEmpty) return;
    final bool restart = _position.inSeconds > 3;
    final int target = restart
        ? _queueIndex
        : _shuffle
        ? _shuffleOrder.previous(_queue.length, _queueIndex)
        : (_queueIndex - 1 + _queue.length) % _queue.length;
    if (restart) {
      _sampleListening();
      listeningStatistics.suspend();
    } else {
      _finishListening(manualTarget: _queue[target]);
    }
    _finishPlaySession();
    playbackError = null;
    // Classic transport behavior: >3s in, "previous" restarts the track.
    if (restart) {
      _position = Duration.zero;
      if (_realActive) {
        final generation = _generation;
        final listeningRevision = ++_listeningRevision;
        _pendingListeningSeek = listeningRevision;
        unawaited(
          audioEngine!
              .seek(Duration.zero)
              .then((_) {
                if (_presentationDisposed ||
                    generation != _generation ||
                    listeningRevision != _listeningRevision) {
                  return;
                }
                _pendingListeningSeek = null;
                listeningStatistics.end();
                if (_playing && current != null) {
                  listeningStatistics.begin(current!, audioEngine!.position);
                }
              })
              .catchError((Object error) {
                if (!_presentationDisposed &&
                    generation == _generation &&
                    listeningRevision == _listeningRevision) {
                  _pendingListeningSeek = null;
                  if (_playing && current != null) {
                    listeningStatistics.begin(current!, audioEngine!.position);
                  }
                }
                debugPrint('Seek failed: $error');
              }),
        );
      }
    } else {
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
    _shuffleOrder.visit(index);
    _finishListening();
    _finishPlaySession();
    trackChangeDirection = direction;
    playbackError = null;
    _queueIndex = index.clamp(0, _queue.length - 1);
    _clearQueuedNext();
    // A stall belongs to the source that produced it, never to the next track.
    _lastStreamUrl = null;
    _streamRetries = 0;
    _streamRetryTrack = -1;
    _clearStreamStall(quiet: true);
    // A pending seek belonged to the previous source: keeping it would publish
    // that track's position on the new one.
    _clearOptimisticSeek();
    unawaited(_saveQueue());
    _position = Duration.zero;
    _resumePositionOnOpen = false;
    unawaited(_loadLyrics());
    // Artwork follows the selection even while paused or when the engine
    // crosses directly into its prepared source without calling _startAudio.
    unawaited(_loadCurrentArtwork());
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
    _finishListening(manualTarget: _queue[before]);
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
          : _shuffleOrder.peek(_queue.length, _queueIndex);
    }
    return (_queueIndex + 1) % _queue.length;
  }

  /// Index the queue advances to when the current track plays out on its own.
  ///
  /// Null means playback stops after the current track.
  int? _autoAdvanceIndex() {
    if (_repeat == LoopMode.one) return _queueIndex;
    if (_shuffle && _queue.length > 1) {
      return _shuffleOrder.peek(_queue.length, _queueIndex);
    }
    if (_repeat == LoopMode.off && _queueIndex >= _queue.length - 1) {
      return null;
    }
    return (_queueIndex + 1) % _queue.length;
  }

  void seek(double fraction) {
    final Track? t = current;
    if (t == null) return;
    _sampleListening();
    listeningStatistics.suspend();
    final Duration target = t.duration * clampSeekFraction(fraction);
    // The engine cancels an audible overlap when it seeks. Going back first keeps
    // the queue position, the shown metadata and the position on the song that is
    // about to be heard.
    _leavePresentedMix();
    _position = target;
    _notePlayheadMoved();
    if (_realActive) {
      _optimisticSeek = target;
      _optimisticSeekGeneration = _generation;
      _optimisticSeekClock
        ..reset()
        ..start();
      final request = ++_seekRequest;
      final generation = _generation;
      final listeningRevision = ++_listeningRevision;
      _pendingListeningSeek = listeningRevision;
      unawaited(
        Future<void>.sync(() => audioEngine!.seek(target))
            .then((_) {
              if (!_presentationDisposed &&
                  request == _seekRequest &&
                  generation == _generation &&
                  listeningRevision == _listeningRevision) {
                _pendingListeningSeek = null;
                if (_playing) listeningStatistics.rebase(audioEngine!.position);
              }
            })
            .catchError((Object error) {
              if (request == _seekRequest) {
                // The engine refused the seek: publishing its real position again
                // is the honest answer, even if that is the pre-seek position.
                _clearOptimisticSeek();
                if (!_presentationDisposed &&
                    generation == _generation &&
                    listeningRevision == _listeningRevision) {
                  _pendingListeningSeek = null;
                  if (_playing) {
                    listeningStatistics.rebase(audioEngine!.position);
                  }
                }
                _tickNotifier.pulse();
              }
              debugPrint('Seek failed: $error');
            }),
      );
    }
    // Position-only change: tick lane, not a structural rebuild.
    _tickNotifier.pulse();
  }

  /// Applies a system or remote seek even when a new source is still opening.
  /// The synchronous [seek] keeps the UI responsive; this variant waits for
  /// the decoder hand-off and repeats the engine seek once the new source is
  /// active so callers can safely await the command.
  Future<void> seekAsync(double fraction) async {
    final trackId = current?.id;
    seek(fraction);
    final opening = _audioOpening;
    if (opening == null || _realActive) return;
    try {
      await opening;
    } catch (_) {
      return;
    }
    if (_presentationDisposed || current?.id != trackId || !_realActive) return;
    seek(fraction);
  }

  /// Follows the engine back to the song an audible overlap was mixed out of.
  ///
  /// A seek (and any other cancellation) drops the incoming side of a mix while
  /// the successor stays queued, so the outgoing song is what the listener hears
  /// again. Without this the queue index would describe a song that is not
  /// playing, and the next preparation would build a successor for the wrong
  /// position in the queue.
  void _leavePresentedMix() {
    final AudioEngine? engine = audioEngine;
    if (engine is! MixPresentingAudioEngine ||
        !(engine as MixPresentingAudioEngine).mixPresented) {
      return;
    }
    final int incoming = _queueIndex;
    final int? outgoing = _mixFromIndex;
    _mixFromIndex = null;
    if (outgoing == null || _queue.length < 2) return;
    _queueIndex = outgoing.clamp(0, _queue.length - 1);
    if (_shuffle) _shuffleOrder.revisitNext(incoming);
    // The song that was being mixed in is still the engine's successor.
    _queuedNextIndex = incoming.clamp(0, _queue.length - 1);
    trackChangeDirection = -1;
    playbackError = null;
    unawaited(_saveQueue());
    unawaited(_loadLyrics());
    unawaited(_loadCurrentArtwork());
    notifyListeners();
  }

  /// How long a resume waits for the download to reach its position.
  ///
  /// A streaming source can only be seeked inside what has landed, so resuming at
  /// a position (after a device reopen or a recovered download) means waiting for
  /// the download to cover it. The bound keeps a download that never gets there
  /// from holding the resume open forever.
  static const Duration resumeBufferWait = Duration(seconds: 25);

  /// Seeks to [target] once the engine can reach it, waiting for the buffer when
  /// the source is still downloading.
  ///
  /// Returns false when the position never became reachable (the download failed,
  /// stopped, or the wait expired), so the caller can report that the resume was
  /// dropped instead of pretending the position was kept.
  Future<bool> _seekWhenReachable(Duration target, int generation) async {
    final AudioEngine? engine = audioEngine;
    if (engine == null) return false;
    if (target <= Duration.zero) return true;
    final SeekRangeReportingAudioEngine? range =
        engine is SeekRangeReportingAudioEngine
        ? engine as SeekRangeReportingAudioEngine
        : null;
    if (range == null || range.canSeekTo(target)) {
      await engine.seek(target);
      return true;
    }
    final DateTime deadline = DateTime.now().add(resumeBufferWait);
    // Every caller is opening a source, so playback has not started yet and `_realActive` is still
    // false: waiting on it would skip the loop entirely and drop the resume. What bounds the wait is
    // the load being superseded, which is what `generation` reports.
    while (generation == _generation && !DateTime.now().isAfter(deadline)) {
      final StreamingBufferHealthAudioEngine? health =
          engine is StreamingBufferHealthAudioEngine
          ? engine as StreamingBufferHealthAudioEngine
          : null;
      if (health != null && health.streamFailed) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (generation != _generation) return false;
      if (range.canSeekTo(target)) {
        await engine.seek(target);
        return true;
      }
    }
    return false;
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
    _shuffleOrder.reset();
    _savePlayMode();
    _refreshAutoMixQueue();
    notifyListeners();
  }

  /// The single play-mode button: Sequential → ListLoop → SingleLoop →
  /// Shuffle → Sequential.
  void cyclePlayMode() {
    _shuffleOrder.reset();
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
    _savePlayMode();
    _refreshAutoMixQueue();
    notifyListeners();
  }

  void cycleRepeat() {
    _repeat = switch (_repeat) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    _savePlayMode();
    _refreshAutoMixQueue();
    notifyListeners();
  }

  void _refreshAutoMixQueue() {
    // A prepared decoder belongs to the old play mode. Rebuild from the current
    // playhead so repeat/shuffle changes cannot mix the wrong successor.
    if (_realActive && current != null && _queueEngine != null) {
      unawaited(_startAudio(resumeAt: precisePosition));
    }
  }

  void playTrackAt(int index) {
    checkScheduledPause();
    if (index < 0 || index >= _queue.length) return;
    _shuffleOrder.visit(index);
    _finishListening(manualTarget: _queue[index]);
    _finishPlaySession();
    trackChangeDirection = index < _queueIndex ? -1 : 1;
    playbackError = null;
    _queueIndex = index;
    unawaited(_saveQueue());
    _position = Duration.zero;
    _resumePositionOnOpen = false;
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
  ///
  /// [recovering] marks a reload this app started because the output was lost:
  /// it keeps the retry budgets already spent on this source, so a device that
  /// fails every open cannot loop.
  Future<void> _startAudio({Duration? resumeAt, bool recovering = false}) {
    final future = _startAudioImpl(resumeAt: resumeAt, recovering: recovering);
    _audioOpening = future;
    unawaited(
      future.then<void>((_) {
        _finishAudioOpening(future);
      }, onError: (error, stack) => _finishAudioOpening(future, error, stack)),
    );
    return future;
  }

  void _finishAudioOpening(
    Future<void> future, [
    Object? error,
    StackTrace? stack,
  ]) {
    if (identical(_audioOpening, future)) _audioOpening = null;
  }

  Future<void> _startAudioImpl({
    Duration? resumeAt,
    bool recovering = false,
  }) async {
    _sampleListening();
    ++_listeningRevision;
    _pendingListeningSeek = null;
    listeningStatistics.suspend();
    unawaited(_loadCurrentArtwork());
    final AudioEngine? engine = audioEngine;
    final Track? track = current;
    if (track == null) return;
    final int generation = ++_generation;
    _realActive = false;
    _clearQueuedNext();
    // A seek that was still being applied belonged to the previous source.
    _clearOptimisticSeek();
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
      await _loadVolumePreferences();
      if (generation != _generation) return;
      await engine.setVolume(_volume);
      if (generation != _generation || _presentationDisposed) return;
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
        bool reached = false;
        try {
          // Waits for the download to cover the position: a streaming source is
          // not seekable past what has landed.
          reached = await _seekWhenReachable(resumeAt, generation);
        } catch (_) {
          // A source that cannot seek still plays; only the position is lost.
        }
        if (generation != _generation) return;
        // Publishing a resume position the engine never took leaves the rail on a
        // place the decoder never reached, so the position follows the outcome.
        _position = reached ? resumeAt : Duration.zero;
      }
    } catch (error) {
      if (generation == _generation) _failPlayback('音频加载失败，请重试。');
      return;
    }
    if (generation != _generation) return;
    _queueId = queueId;
    _realActive = true;
    _resumePositionOnOpen = false;
    // Remembered so a dead download can be reloaded from the position the
    // listener was at, instead of leaving a parked player on screen.
    _lastStreamUrl = _isNetworkStream(url) ? url : null;
    if (!recovering) {
      // A load the listener asked for starts the recovery budgets over. A
      // recovery reload does not: the budget it already spent is what keeps a
      // device that fails every open from looping forever.
      _streamRetries = 0;
      _streamRetryTrack = _queueIndex;
      _deviceRetries = 0;
    }
    _clearStreamStall(quiet: true);
    // A fresh source opens a fresh no-progress window: without a running clock
    // the watchdog would never reach its threshold while the playhead stands.
    _resetStallClock();
    unawaited(_recordCurrentLocally());
    unawaited(_ensureStationBuffer());
    if (_playing) unawaited(_startWhenBuffered(generation, url));
    if (engine is! SerialQueueAudioEngine) unawaited(_prefetchNext());
    notifyListeners();
  }

  /// How much of an uncached track is buffered before it starts playing.
  ///
  /// A cached or downloaded track opens from a local file and starts at once.
  /// A track still coming off the CDN is a different animal: the decoder
  /// reaches the end of what has arrived within the first seconds and the song
  /// stutters while it waits for more. Ten seconds of lead time covers the
  /// startup burst, and the wait is what a listener reads as "loading".
  static const Duration startupBuffer = Duration(seconds: 10);

  /// Wall-clock ceiling on that wait. A CDN that cannot fill the buffer must
  /// not hold the track hostage: after this the engine is started regardless
  /// and the ordinary streaming path takes over.
  static const Duration startupBufferTimeout = Duration(seconds: 25);

  /// Bytes that must have landed before an unmeasurable stream is started.
  ///
  /// A CDN that never announces a length has no fraction to wait for, but it
  /// still has bytes. Starting on zero of them hands the decoder an empty file
  /// and parks it in a read that only the reader's own stall deadline ends,
  /// which is the "切歌之后卡住不动" report. This is the byte equivalent of
  /// [startupBuffer]: about ten seconds of 320 kbps audio.
  static const int startupBytes = 256 * 1024;

  /// How often the startup buffer is polled while waiting for it.
  static const Duration _startupBufferPoll = Duration(milliseconds: 120);

  /// How often a playing stream is checked for a stalled download.
  ///
  /// The engine owns the threshold itself: it watches the downloader's byte
  /// counter and reports `streamStalled` once no byte has landed for long
  /// enough. This is only the poll rate.
  static const Duration _stallPoll = Duration(seconds: 1);

  /// Overridable in tests, which cannot wait out the shipped ten seconds.
  final Duration startupBufferTarget;
  final Duration startupBufferDeadline;

  /// Byte target for a stream whose length the server never announces.
  final int startupByteTarget;

  /// The load whose opening seconds are still being downloaded, if any.
  ///
  /// Keyed by generation on purpose: a newer load that supersedes the wait
  /// clears it implicitly instead of racing the older wait's cleanup.
  int? _bufferingGeneration;

  /// Whether the current track is held back while its opening seconds arrive.
  bool get startupBuffering =>
      _bufferingGeneration != null && _bufferingGeneration == _generation;

  /// Whether playback is parked on a stream that stopped delivering bytes.
  ///
  /// Distinct from [startupBuffering]: the source is open and the transport
  /// says "playing", but no data is arriving, so the UI has to say so instead
  /// of showing a playhead that never moves.
  bool get streamStalled =>
      _stalledGeneration != null && _stalledGeneration == _generation;

  bool get buffering => startupBuffering || streamStalled;

  int? _stalledGeneration;
  final Stopwatch _positionClock = Stopwatch();
  int _streamRetries = 0;
  int _streamRetryTrack = -1;

  /// Whether [url] is a stream this launch has not cached yet.
  ///
  /// Downloaded and cached tracks are handed to the engine as `file:` URIs, so
  /// the scheme is the answer; nothing here needs to poll the cache again.
  static bool _isNetworkStream(String url) {
    final String scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    return scheme == 'http' || scheme == 'https';
  }

  /// Starts [generation] once enough of an uncached stream has arrived.
  ///
  /// Writes into `_position` are deliberately left to the engine: the loading
  /// state is visible through [audioReady] and [startupBuffering], and the
  /// media controls report `loading` for it.
  Future<void> _startWhenBuffered(int generation, String url) async {
    final AudioEngine? engine = audioEngine;
    if (engine == null || !_isNetworkStream(url)) {
      await _resumeAudio();
      return;
    }
    // The buffer capability is a separate interface on purpose, so the test
    // doubles that only implement transport keep working: ask, do not assume.
    final BufferedAudioEngine? buffer = engine is BufferedAudioEngine
        ? engine as BufferedAudioEngine
        : null;
    if (buffer == null) {
      await _resumeAudio();
      return;
    }
    final Duration? reported = _bufferedAhead(buffer);
    final int? landed = _streamedBytes(engine);
    if (_startupBufferReady(engine, reported, landed)) {
      await _resumeAudio();
      return;
    }
    _bufferingGeneration = generation;
    notifyListeners();
    final Stopwatch clock = Stopwatch()..start();
    try {
      while (true) {
        if (_presentationDisposed || generation != _generation) return;
        // A pause during the wait is a decision, not a hiccup: park the track
        // where it is and let play resume it when the listener asks again.
        checkScheduledPause();
        if (!_playing) return;
        final Duration? buffered = _bufferedAhead(buffer);
        final int? bytes = _streamedBytes(engine);
        if (buffered == null && bytes == null) {
          // A backend that can answer neither question is started at once:
          // waiting on silence is worse than the stutter this lead time exists
          // to avoid.
          break;
        }
        if (_startupBufferReady(engine, buffered, bytes) ||
            clock.elapsed >= startupBufferDeadline) {
          break;
        }
        await Future<void>.delayed(_startupBufferPoll);
      }
    } finally {
      if (_bufferingGeneration == generation) {
        _bufferingGeneration = null;
        if (!_presentationDisposed) notifyListeners();
      }
    }
    if (_presentationDisposed || generation != _generation) return;
    if (_playing) await _resumeAudio();
  }

  /// Whether the startup wait is satisfied.
  ///
  /// Two independent questions, because a stream may answer only one of them:
  /// a time-based lead when the engine can measure it, and a byte lead when it
  /// cannot. A stream that cannot be measured *and* has delivered nothing is
  /// the one case that must not start.
  bool _startupBufferReady(
    AudioEngine engine,
    Duration? buffered,
    int? landed,
  ) {
    // The byte target is matched exactly: a caller that sets it to zero (or a
    // build with no byte signal at all) keeps the historical behaviour of
    // starting as soon as the fraction is known to be sufficient.
    if (landed != null && landed >= startupByteTarget) return true;
    if (buffered == null) return false;
    if (buffered >= startupBufferTarget) return true;
    final Duration? total = engine.duration ?? current?.duration;
    if (total != null && total > Duration.zero && buffered >= total) {
      return true;
    }
    // Bytes are the only signal left when the fraction is unmeasurable, so an
    // unmeasurable stream waits for them instead of starting on an empty file.
    return false;
  }

  /// Bytes of the current network source that have landed, when the engine can
  /// report them.
  static int? _streamedBytes(AudioEngine engine) {
    try {
      if (engine is StreamingBufferHealthAudioEngine) {
        return (engine as StreamingBufferHealthAudioEngine).streamedBytes;
      }
    } catch (_) {
      // A test double that only answers transport is not a streaming engine.
    }
    return null;
  }

  /// How much [engine] has buffered ahead of the playhead, or null when it
  /// cannot say — including the small injected players that answer transport
  /// calls through [NoSuchMethodError].
  static Duration? _bufferedAhead(BufferedAudioEngine engine) {
    try {
      if (engine is StartupBufferReportingAudioEngine) {
        return (engine as StartupBufferReportingAudioEngine)
            .startupBufferedPosition;
      }
      return engine.bufferedPosition;
    } catch (_) {
      return null;
    }
  }

  /// Watches a playing stream for a download that stopped delivering.
  ///
  /// A parked decode thread cannot report progress, and the app's own position
  /// clock simply stops with it — which is exactly the "播放器没法播放" state.
  /// Two signals are checked, both from the downloader rather than the audio
  /// clock: an already-failed download, and the engine's own no-byte stall flag
  /// ([StreamingBufferHealthAudioEngine.streamStalled]). Either one ends the
  /// parked read through the engine's restart path and reloads the source from
  /// the position the listener was at, instead of leaving a dead player on
  /// screen.
  void _checkStreamStall() {
    if (!_playing || !_realActive) return;
    final AudioEngine? engine = audioEngine;
    if (engine is! StreamingBufferHealthAudioEngine) return;
    final int track = _streamRetryTrack;
    if (track != _queueIndex) {
      // A different track: this stream has not failed yet.
      _streamRetryTrack = _queueIndex;
      _streamRetries = 0;
    }
    final StreamingBufferHealthAudioEngine health =
        engine as StreamingBufferHealthAudioEngine;
    final bool failed = health.streamFailed;
    final bool stalled = health.streamStalled;
    final bool wasStalled = _stalledGeneration == _generation;
    if (!failed && !stalled) {
      _clearStreamStall();
      return;
    }
    // A finite number of recoveries per track: a CDN that is genuinely down must
    // end in a named error, not an endless reload loop.
    if (_streamRetries >= maxStreamRetries) {
      _clearStreamStall(quiet: true);
      _failPlayback('网络不佳，无法继续播放这首歌曲。');
      return;
    }
    if (!wasStalled) {
      _stalledGeneration = _generation;
      notifyListeners();
    }
    if (!health.restartStream()) {
      // Nothing to restart (a local source, or a download that is still alive):
      // the next check re-reads the state instead of reloading the track.
      return;
    }
    final String? streamUrl = _lastStreamUrl;
    if (streamUrl == null) return;
    // Counted before the reload starts so the next check cannot overlap it.
    _streamRetries++;
    // Held at the position the rail is showing — for a seek still being applied,
    // the target — so the reload resumes where the listener was, not where the
    // decode thread had got to.
    final Duration resumeAt = precisePosition;
    _resetStallClock();
    _realActive = false;
    playbackError = null;
    _position = resumeAt;
    unawaited(() async {
      if (!await _reloadStream(streamUrl) &&
          _playing &&
          !_presentationDisposed) {
        _failPlayback('网络不佳，播放已中断。');
      }
    }());
  }

  /// Drops the stalled flag. [quiet] skips the notification when the caller is
  /// already about to notify (a reload path), so one state change repaints once.
  ///
  /// The "no progress" window is restarted by [notePlayheadMoved] or by an
  /// explicit [_resetStallClock] where the playhead cannot be the yardstick
  /// (a fresh source, or a seek), never here: clearing the flag while the
  /// playhead is standing still is exactly the state the watchdog must keep
  /// measuring.
  void _clearStreamStall({bool quiet = false}) {
    if (_stalledGeneration != null) {
      _stalledGeneration = null;
      if (!quiet && !_presentationDisposed) notifyListeners();
    }
  }

  /// Restarts the "no progress" window without touching the stalled flag.
  void _resetStallClock() {
    _positionClock
      ..reset()
      ..start();
  }

  /// The playhead advanced, so this source is delivering: a stall state is
  /// stale and the window starts again.
  void _notePlayheadMoved() {
    _resetStallClock();
    _clearStreamStall(quiet: true);
  }

  /// The URL the current source was opened with, for a stall recovery reload.
  String? _lastStreamUrl;

  /// How many times one track may be recovered from a dead download before the
  /// failure is reported instead.
  static const int maxStreamRetries = 2;

  /// How many times one track may be reopened after the platform reclaimed the
  /// output before the failure is reported instead. Mirrors [maxStreamRetries]:
  /// a device that refuses every open must end in a named error, not a loop. A
  /// recovery reload does not reset the budget it spent — only a load the
  /// listener asked for does.
  static const int maxDeviceRetries = 2;

  /// Device reopens spent on the current source; cleared by a requested load.
  int _deviceRetries = 0;

  /// Hands the track that follows the current one to the engine, so the
  /// platform can cross into it while the decoder is still running.
  ///
  /// The queue engine is optional: with a plain [AudioEngine] this is a no-op
  /// and playback keeps the load-on-completion path.
  Future<void> _prefetchNext() async {
    final QueueAudioEngine? engine = _queueEngine;
    final int? queueId = _queueId;
    if (engine == null || queueId == null || _queue.isEmpty) return;
    // While an overlap is audible the engine's successor is the song being mixed
    // in. Preparing the one after it now would replace it: the engine refuses a
    // second successor, and the losing preparation clears the queued reader,
    // which fades the incoming song back out and leaves the queue a song ahead of
    // what is heard. The hand-off asks again.
    if (engine is MixPresentingAudioEngine &&
        (engine as MixPresentingAudioEngine).mixPresented) {
      return;
    }
    final int generation = ++_prefetchGeneration;
    final int? next = _autoAdvanceIndex();
    if (next == null) {
      _clearQueuedNext();
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
    // A newer preparation, a track change or a stop while the URL was in flight
    // invalidates this one: the engine may already hold a different successor.
    if (generation != _prefetchGeneration ||
        queueId != _queueId ||
        !_realActive) {
      return;
    }
    if (url == null || url.isEmpty) return;
    bool appended;
    try {
      appended = await engine.appendToQueue(queueId, url);
    } catch (_) {
      appended = false;
    }
    if (generation != _prefetchGeneration) {
      // Superseded while appending: it must not claim the engine's successor.
      return;
    }
    if (!appended || queueId != _queueId) return;
    _queuedNextIndex = next;
    _queuedNextUrl = url;
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
    _lastStreamUrl = null;
    _streamRetries = 0;
    _streamRetryTrack = -1;
    _clearStreamStall(quiet: true);
    unawaited(_resumeAudio());
    if (engine is! SerialQueueAudioEngine) unawaited(_prefetchNext());
  }

  /// The platform moved to the queued track on its own — the gapless hand-off.
  ///
  /// Everything the load path would have done still has to happen (index,
  /// persistence, lyrics, artwork), only the audio is already playing.
  void _onEngineAdvanced(int _) {
    _finishPlaySession();
    final int? target = _queuedNextIndex;
    if (!_realActive || !_playing || target == null) return;
    // The engine reports which URL it crossed into. It must be the URL this app
    // appended for [target]; anything else means the audible song and the queue
    // position disagree, which is the "the mix is not what the queue scripted"
    // report. With one preparation in flight and no replacement during an
    // overlap this cannot happen, so the log is the assertion that keeps it true.
    final QueueAudioEngine? queueEngine = _queueEngine;
    final String? engineUrl = queueEngine is QueuedSourceReportingAudioEngine
        ? (queueEngine as QueuedSourceReportingAudioEngine).queuedSourceUrl
        : null;
    final String? expectedUrl = _queuedNextUrl;
    if (engineUrl != null && expectedUrl != null && engineUrl != expectedUrl) {
      debugPrint(
        'lazer-audio: automix crossed into $engineUrl while the queue scripted '
        '$expectedUrl for index $target',
      );
    }
    ++_listeningRevision;
    _pendingListeningSeek = null;
    listeningStatistics.end();
    // `_queuedNextIndex` is deliberately left alone: it is this method's own entry
    // guard, and the hand-off arrives as a *second* index event once the overlap
    // ends. Clearing it here would make that second event return early and skip the
    // `_prefetchNext()` at the tail, so the song after the mixed-in one would never
    // be prepared. `_prefetchNext` overwrites both fields as soon as it lands.
    trackChangeDirection = 1;
    playbackError = null;
    // A mix is presented before the hand-off: the audible song is a blend and
    // the outgoing track is still the engine's active decoder, which is what a
    // rollback returns to.
    final AudioEngine? audio = audioEngine;
    if (audio is MixPresentingAudioEngine &&
        (audio as MixPresentingAudioEngine).mixPresented) {
      _mixFromIndex = _queueIndex;
    } else {
      _mixFromIndex = null;
    }
    _queueIndex = target.clamp(0, _queue.length - 1);
    _shuffleOrder.visit(_queueIndex);
    // The hand-off opens a different source; its URL is resolved again by the
    // next prefetch, so a stale one must not be used for a stall recovery.
    _lastStreamUrl = null;
    _streamRetries = 0;
    _streamRetryTrack = -1;
    _clearStreamStall(quiet: true);
    _clearOptimisticSeek();
    // The engine has already moved on, so a seek still in flight for the
    // outgoing track must not land on the incoming one.
    _position = audioEngine?.position ?? Duration.zero;
    if (current != null) listeningStatistics.begin(current!, _position);
    ++_seekRequest;
    // AutoMix hands off while the incoming track is already audible, so the
    // engine's position — not zero — is what the listener is hearing.
    _position = audioEngine?.position ?? Duration.zero;
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
    currentArtwork.update(current);
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
    unawaited(playbackCache.recordPlayed(track, quality: playbackQuality));
    _recentTracks = <Track>[
      track,
      ..._recentTracks.where((entry) => entry.id != track.id),
    ].take(_recentTracksLimit).toList();
    notifyListeners();
    await _saveRecentTracks();
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

  /// Writes the state the next launch restores before the app is backgrounded
  /// or closed.
  ///
  /// Queue and listening writes are fire-and-forget during playback, so the last
  /// track change can still be in flight when the process goes away. The
  /// lifecycle hooks await this; [dispose] cannot await, but starting the writes
  /// there is still better than dropping them.
  Future<void> flushPersistence() async {
    if (_presentationDisposed) return;
    try {
      await _saveQueue();
    } catch (_) {
      // Preferences can be unavailable; the in-memory queue still plays.
    }
    try {
      await listeningStatistics.flush();
    } catch (_) {
      // Statistics are best-effort, like the queue.
    }
    try {
      await playbackCache.flushHistory();
    } catch (_) {
      // Play history is best-effort too.
    }
  }

  Future<void> _resumeAudio() async {
    if (_presentationDisposed) return;
    checkScheduledPause();
    if (!_playing) return;
    final generation = _generation;
    if (_realActive && current != null && _pendingListeningSeek == null) {
      listeningStatistics.begin(current!, audioEngine!.position);
    }
    try {
      await _loadVolumePreferences();
      if (_presentationDisposed || !_playing || generation != _generation) {
        return;
      }
      await audioEngine!.setVolume(_volume);
      await audioEngine!.play();
      if (_presentationDisposed) return;
      // A pending native play may finish after the pause boundary.
      checkScheduledPause();
      if (!_playing) {
        await audioEngine!.pause();
      } else if (audioEngine is SerialQueueAudioEngine &&
          generation == _generation &&
          _queuedNextIndex == null) {
        // Native queue preparation shares the transport worker. A slow next
        // source must never get in front of this source's first play command.
        unawaited(_prefetchNext());
      }
    } catch (_) {
      if (generation == _generation) _failPlayback('播放中断，请重试。');
    }
  }

  Future<void> toggleLikeCurrent() => _musicPlatforms.toggleLike();

  Future<void> ensureCurrentLyrics({bool force = false}) async {
    final track = current;
    if (track == null || _presentationDisposed) return;
    if (force) {
      _lyricSnapshots.remove(_lyricsKey(track));
      await catalog.invalidateLyrics(track.id);
      if (current?.id != track.id) return;
    }
    if (!force &&
        _lyricsTrackId == track.id &&
        (lyricsLoading || lyricsError == null)) {
      if (lyricsLoading) await _lyricRequest?.$2;
      return;
    }
    await _loadLyrics(refresh: force);
  }

  (String, String, String?) _lyricsKey(Track track) =>
      (activeConnectionKey, track.id, track.localPath);

  void _rememberLyrics((String, String, String?) key) {
    if (_presentationDisposed) return;
    _lyricSnapshots
      ..remove(key)
      ..[key] = _LyricsSnapshot(lyrics, lyricsPureMusic, lyricsImported);
    while (_lyricSnapshots.length > 8) {
      _lyricSnapshots.remove(_lyricSnapshots.keys.first);
    }
  }

  Future<void> _loadLyrics({bool refresh = false}) {
    if (_presentationDisposed) return Future<void>.value();
    final track = current;
    final key = track == null ? null : _lyricsKey(track);
    final request = _lyricRequest;
    if (!refresh && key != null && request?.$1 == key) return request!.$2;
    _lyricRequest = null;
    final generation = ++_lyricGeneration;
    final snapshot = _lyricSnapshots.remove(key);
    final cached =
        !refresh &&
            snapshot != null &&
            DateTime.now().difference(snapshot.savedAt) <
                const Duration(days: 7)
        ? snapshot
        : null;
    lyrics = cached?.lines ?? const <LyricLine>[];
    lyricsError = null;
    lyricsImported = cached?.imported ?? false;
    _lyricsTrackId = track?.id;
    lyricsLoading = track != null && cached == null;
    lyricsPureMusic = cached?.pureMusic ?? false;
    // Both resources start at selection time, independent of audio loading
    // and of whether the player page has ever been mounted.
    currentArtwork.update(track);
    notifyListeners();
    if (track == null || key == null) return Future<void>.value();
    if (cached != null) {
      _lyricSnapshots[key] = cached;
      _checkImportedLyrics(track, key, generation);
      return Future<void>.value();
    }
    late final Future<void> loading;
    loading = _readLyrics(track, key, generation).whenComplete(() {
      if (identical(_lyricRequest?.$2, loading)) _lyricRequest = null;
    });
    _lyricRequest = (key, loading);
    return loading;
  }

  Future<void> _readLyrics(
    Track track,
    (String, String, String?) key,
    int generation,
  ) async {
    _checkImportedLyrics(track, key, generation);
    Object? failure;
    bool cacheable = false;
    final localOnly = track.localPath != null || track.id.startsWith('local:');
    bool currentRequest() =>
        !_presentationDisposed && generation == _lyricGeneration;
    void publish(GatewayLyrics payload) {
      if (!currentRequest()) return;
      if (!lyricsImported) {
        lyrics = List.unmodifiable(parseLyrics(payload));
        lyricsPureMusic = payload.pureMusic;
      }
      cacheable = true;
      lyricsError = null;
      lyricsLoading = false;
      _rememberLyrics(key);
      notifyListeners();
    }

    Future<(GatewayLyrics?, Object?)>? remote;
    if (!localOnly) {
      remote = () async {
        try {
          return (await catalog.lyricsFor(track), null);
        } catch (error) {
          return (null, error);
        }
      }();
    }
    final stored = catalog.lyricsCache.read(track);
    if (remote == null) {
      final payload = await stored;
      if (!currentRequest()) return;
      if (payload != null) publish(payload);
    } else {
      // Whichever usable copy arrives first can paint. Disk I/O and cache
      // writes must never delay a ready lyric response or its animation.
      final first = await Future.any<(bool, GatewayLyrics?, Object?)>([
        remote.then((value) => (true, value.$1, value.$2)),
        stored.then((value) => (false, value, null)),
      ]);
      if (!currentRequest()) return;
      if (!first.$1 && first.$2 != null) {
        publish(first.$2!);
        unawaited(
          remote.then((value) {
            final payload = value.$1;
            if (payload == null || _presentationDisposed) return;
            unawaited(catalog.lyricsCache.save(track, payload));
            publish(payload);
          }),
        );
        return;
      }
      if (first.$1) {
        final payload = first.$2;
        failure = first.$3;
        if (payload != null) {
          unawaited(catalog.lyricsCache.save(track, payload));
          publish(payload);
        } else {
          // A cache lookup may be blocked on the platform storage channel.
          // Do not keep the lyric sheet in a spinner after the provider has
          // already answered; adopt a late cache hit when it arrives.
          unawaited(
            stored.then((cached) {
              if (cached != null && currentRequest()) publish(cached);
            }),
          );
        }
      } else {
        final result = await remote;
        if (!currentRequest()) return;
        final payload = result.$1;
        failure = result.$2;
        if (payload != null) {
          unawaited(catalog.lyricsCache.save(track, payload));
          publish(payload);
        }
      }
    }
    // Cloud lyrics are authoritative, but a `.lrc` beside a downloaded or
    // scanned file is a useful offline fallback.
    if (lyrics.isEmpty &&
        !lyricsPureMusic &&
        (localOnly || track.localPath != null)) {
      final File? localFile = await localLibrary.localFileFor(track);
      if (generation != _lyricGeneration) return;
      final String? localPath = localFile?.path ?? track.localPath;
      final cached = await catalog.lyricsCache.read(
        track,
        audioPath: localPath,
      );
      if (generation != _lyricGeneration) return;
      if (cached != null && !lyricsImported) {
        lyrics = List.unmodifiable(parseLyrics(cached));
        lyricsPureMusic = cached.pureMusic;
        cacheable = true;
      }
      final String? sidecar = await ImportedLyricsStore.sidecarFor(localPath);
      if (generation != _lyricGeneration) return;
      if (sidecar != null &&
          lyrics.isEmpty &&
          !lyricsImported &&
          !lyricsPureMusic) {
        lyrics = List<LyricLine>.unmodifiable(parseLrc(sidecar));
        cacheable = true;
      }
    }
    if (lyrics.isEmpty && failure != null) {
      lyricsError = '歌词暂时无法加载。';
    }
    lyricsLoading = false;
    if (cacheable || lyricsImported || localOnly) _rememberLyrics(key);
    notifyListeners();
  }

  void _checkImportedLyrics(
    Track track,
    (String, String, String?) key,
    int generation,
  ) {
    // The imported copy is read in parallel and never blocks the sheet: a slow
    // or unavailable plugin should not keep the spinner up, and the imported
    // lyrics still win whenever they arrive for this track.
    unawaited(
      importedLyrics
          .read(track)
          .then((String? imported) {
            if (imported == null || generation != _lyricGeneration) return;
            lyrics = List<LyricLine>.unmodifiable(parseLrc(imported));
            lyricsImported = true;
            lyricsPureMusic = false;
            lyricsError = null;
            lyricsLoading = false;
            _rememberLyrics(key);
            notifyListeners();
          })
          .catchError((Object _) {}),
    );
  }

  /// Saves user-provided lyrics for [track] and refreshes it when current.
  Future<bool> saveImportedLyrics(Track track, String content) async {
    final bool saved = await importedLyrics.save(track, content);
    if (saved) {
      _lyricSnapshots.remove(_lyricsKey(track));
      if (current?.id == track.id) await _loadLyrics(refresh: true);
    }
    return saved;
  }

  /// Drops the imported copy so the cloud (or the sidecar) is used again.
  Future<void> clearImportedLyrics(Track track) async {
    await importedLyrics.delete(track);
    _lyricSnapshots.remove(_lyricsKey(track));
    if (current?.id == track.id) await _loadLyrics(refresh: true);
  }

  void _failPlayback(String message) {
    // The engine may already be stopped on a terminal error. Keep only
    // progress observed before the failure, never a final fabricated position.
    ++_listeningRevision;
    _pendingListeningSeek = null;
    listeningStatistics.end();
    _realActive = false;
    _playing = false;
    // A failed open still knows where the listener was; the next Play retries
    // from there rather than from the beginning of the track.
    _resumePositionOnOpen = _position > Duration.zero;
    _clearQueuedNext();
    _ticker?.cancel();
    playbackError = message;
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    notifyListeners();
  }

  /// The engine failed after the source was loaded.
  ///
  /// The message is shown instead of silently stopping: a lost output device and a
  /// decode error both leave the user with no audio, and both are worth naming.
  /// A terminal failure also ends the HiFi promise for this session — the output
  /// that produced it is gone — so the path notice says so.
  void _onEngineFailure(AudioFailure failure) {
    final String message = failure.message;
    final bool pathChanged =
        hifiPathNotice == null && audioEngine is FailureReportingAudioEngine;
    if (pathChanged) {
      hifiPathNotice = '音频引擎已中断：$message（当前非 HiFi 路径）';
    }
    if (!_realActive) {
      if (pathChanged) notifyListeners();
      return;
    }
    // A lost output device is not a property of the source. The platform took the
    // endpoint back — another application asked for the output, the route changed,
    // a call came in — and the same track plays again on a fresh open at the
    // position the listener was at. Opening it again here is what turns "the
    // player is stuck until the next track" into a gap of one output session.
    if (failure.kind == AudioFailureKind.device &&
        _deviceRetries < maxDeviceRetries) {
      final Duration resumeAt = precisePosition;
      _deviceRetries++;
      _finishPlaySession();
      _realActive = false;
      _clearQueuedNext();
      playbackError = null;
      _position = resumeAt;
      _resetStallClock();
      if (pathChanged) notifyListeners();
      unawaited(_reopenOutput(resumeAt, message));
      return;
    }
    // A stream whose download died reaches the app here first: the reader
    // reports the I/O error long before the app's own no-byte watchdog would
    // notice, and a network recovery is possible while the rest of the session
    // is not at fault. Everything else (device lost, decode error) keeps the
    // existing terminal behaviour.
    final AudioEngine? engine = audioEngine;
    final StreamingBufferHealthAudioEngine? health =
        engine is StreamingBufferHealthAudioEngine
        ? engine as StreamingBufferHealthAudioEngine
        : null;
    if (_realActive &&
        health != null &&
        health.streamFailed &&
        _lastStreamUrl != null &&
        _streamRetries < maxStreamRetries) {
      final int resumeAt = _position.inMilliseconds;
      _finishPlaySession();
      _realActive = false;
      _clearQueuedNext();
      playbackError = null;
      _position = Duration(milliseconds: resumeAt);
      if (pathChanged) notifyListeners();
      unawaited(_recoverFailedStream(message));
      return;
    }
    _failPlayback(message);
  }

  /// Opens the output again after the platform reclaimed it, at [resumeAt].
  ///
  /// The load path is the same one a quality switch uses: the current track is
  /// resolved again and the playhead is restored through the fresh open, so a
  /// re-opened device never restarts the track from the beginning. [message] is
  /// the device failure to report when the output still does not come up and the
  /// listener still wants this track; a load that fails reports its own text, and
  /// a track the listener replaced is left alone.
  Future<void> _reopenOutput(Duration resumeAt, String message) async {
    final String? targetId = current?.id;
    await _startAudio(resumeAt: resumeAt, recovering: true);
    if (_presentationDisposed || current?.id != targetId) return;
    if (!_realActive && _playing) _failPlayback(message);
  }

  /// Reloads the current network source after its download died, resuming at the
  /// position the listener was at. Gives up with the engine's own message when
  /// the reload itself fails.
  Future<void> _recoverFailedStream(String message) async {
    final String? url = _lastStreamUrl;
    final AudioEngine? engine = audioEngine;
    if (url == null || engine is! StreamingBufferHealthAudioEngine) {
      _failPlayback(message);
      return;
    }
    final StreamingBufferHealthAudioEngine health =
        engine as StreamingBufferHealthAudioEngine;
    // Unblocks the parked decode thread and restarts the download from the
    // bytes already on disk.
    health.restartStream();
    final bool reloaded = await _reloadStream(url);
    if (!reloaded) _failPlayback(message);
  }

  /// Opens [url] again at the position the rail is showing, routing through the
  /// queue engine the way the normal load path does.
  ///
  /// Returns false when the source could not be reopened (the caller decides
  /// whether that is a terminal failure). A newer generation — a track change or
  /// a stop — makes the result irrelevant and also reports true, so the caller
  /// does not fail a track the listener already replaced.
  Future<bool> _reloadStream(String url) async {
    final AudioEngine? engine = audioEngine;
    if (engine == null) return false;
    final QueueAudioEngine? queueEngine = _queueEngine;
    final int generation = ++_generation;
    // The position as the rail sees it: while a seek is being applied that is
    // the target. A source replaced at that moment stopped before it could
    // publish the new position, so resuming from the live value is what stops a
    // dead download from dropping the listener back to where the decode thread
    // had got to — which, right after a jump, is the beginning of the track.
    final Duration resume = precisePosition;
    // The reload is not a stall: the no-progress window starts again once the
    // replacement source is playing.
    _resetStallClock();
    try {
      int? queueId;
      if (queueEngine != null) {
        try {
          queueId = await queueEngine.setQueue(<String>[url]);
        } catch (_) {
          // The platform refused a queue: fall back to the single-source path.
          queueId = null;
        }
      }
      if (generation != _generation) return true;
      if (queueId == null) await engine.setUrl(url);
      if (generation != _generation) return true;
      await engine.setVolume(_volume);
      if (resume > Duration.zero) {
        try {
          // The replacement source starts its download from the beginning, so the
          // resume waits until the buffer covers where the listener was.
          await _seekWhenReachable(resume, generation);
        } catch (_) {
          // A source that cannot seek still plays; only the position is lost.
        }
      }
      if (generation != _generation) return true;
      _queueId = queueId;
      _realActive = true;
      _resumePositionOnOpen = false;
      _clearStreamStall(quiet: true);
      _clearOptimisticSeek();
      if (_playing) await _startWhenBuffered(generation, url);
      return true;
    } catch (error) {
      debugPrint('Reloading the stream failed: $error');
      return false;
    }
  }

  void _onEngineCompleted() {
    _finishPlaySession();
    if (!_realActive || !_playing) return;
    _finishListening(completed: true);
    // Consume the terminal state before seeking/loading; some backends emit
    // both a completed event and a final position update for the same source.
    _realActive = false;
    // A queued track would have been crossed into by the platform; reaching
    // here means the queue really did run out on this source.
    _clearQueuedNext();
    final AudioEngine engine = audioEngine!;
    if (_repeat == LoopMode.one) {
      final Track? track = current;
      if (track != null) {
        unawaited(playbackCache.recordPlayed(track, quality: playbackQuality));
      }
      _position = Duration.zero;
      _resumePositionOnOpen = false;
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
    _resumePositionOnOpen = false;
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
      final Duration position = audioEngine!.position;
      if (position != _position) {
        _notePlayheadMoved();
      } else if (_positionClock.elapsed >= _stallPoll) {
        _positionClock
          ..reset()
          ..start();
        _checkStreamStall();
      }
      _position = position;
      _sampleListening();
      _trackPlaySession(t);
      // A native duration/position is a second completion signal for backends
      // that omit the terminal processing-state event. Never use metadata or
      // an estimated clock here: unavailable/buffering songs must not advance.
      final duration = audioEngine!.duration;
      if (duration != null &&
          duration > Duration.zero &&
          _position >= duration &&
          // A queued track is crossed into by the platform; ending this source
          // there is the hand-off, not the end of the queue. The engine's own
          // answer decides: a preparation that lost its race leaves the app
          // believing in a hand-off that can never arrive, and waiting for it is
          // what made a track end in silence.
          !_engineHoldsSuccessor) {
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

  void _sampleListening({bool completed = false}) {
    final engine = audioEngine;
    if (_playing &&
        _realActive &&
        !startupBuffering &&
        engine != null &&
        (engine.active || completed)) {
      listeningStatistics.sample(engine.position);
    }
  }

  void _finishListening({Track? manualTarget, bool completed = false}) {
    // A completion can mark the engine inactive before delivering its final
    // real position; consume that position without estimating a missing tail.
    _sampleListening(completed: completed);
    ++_listeningRevision;
    _pendingListeningSeek = null;
    if (manualTarget != null) listeningStatistics.recordSkipTo(manualTarget);
    listeningStatistics.end();
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

  void _reportPlayStart(Track track) {
    unawaited(_musicPlatforms.report(track, Duration.zero, false));
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
    unawaited(_musicPlatforms.report(track, _playSessionTime, true));
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
        final songId = row['songId'];
        final account = row['account'];
        if (songId is! String ||
            account is! String ||
            MusicId.tryParse(songId) == null) {
          continue;
        }
        final seconds = (row['seconds'] as num?)?.toInt() ?? 0;
        _playUploads.add(
          _PlayReport(
            songId: songId,
            account: account,
            kind: row['kind'] == 'start'
                ? _PlayLogKind.start
                : _PlayLogKind.play,
            seconds: seconds,
          ),
        );
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
              'account': report.account,
              'kind': report.kind == _PlayLogKind.start ? 'start' : 'play',
              'seconds': report.seconds,
            },
        ]),
      );
    } catch (_) {}
  }

  /// Drains the upload queue. A failed request stays at the head and is retried
  /// on the next track boundary or the next library refresh, so an offline
  /// spell does not silently lose plays.
  Future<void> _flushPlayUploads() async {
    if (_playUploadInFlight) return;
    _playUploadInFlight = true;
    var changed = false;
    try {
      for (final report in List<_PlayReport>.of(_playUploads)) {
        try {
          final id = MusicId.tryParse(report.songId);
          if (id == null) {
            _playUploads.remove(report);
            changed = true;
            continue;
          }
          final owner = catalog.connections.resolve(id);
          if (owner.user == null || owner.cacheNamespace != report.account) {
            continue;
          }
          await owner.scrobble(
            id,
            played: Duration(seconds: report.seconds),
            submission: report.kind == _PlayLogKind.play,
          );
          _playUploads.remove(report);
          changed = true;
          if (report.kind == _PlayLogKind.play &&
              identical(owner, catalog.activeGateway)) {
            await catalog.invalidatePlayStats(_user.userId);
            _playStatsUid = null;
          }
        } catch (_) {
          // Keep a failed account's report without blocking other platforms.
        }
      }
    } finally {
      _playUploadInFlight = false;
      if (changed) unawaited(_persistPlayUploads());
    }
  }

  void _savePlayMode() {
    _playModeRevision++;
    _stationPlayMode = null;
    _shuffleOrder.reset();
    final mode = _shuffle
        ? (_repeat == LoopMode.off ? 'shuffle' : 'shuffle:${_repeat.name}')
        : switch (_repeat) {
            LoopMode.all => 'all',
            LoopMode.one => 'one',
            LoopMode.off => 'sequential',
          };
    _playModeWrites = _playModeWrites
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_playModeKey, mode);
        })
        .catchError((Object _) {});
  }

  static AuthOutcome _failure(Object error) =>
      AuthOutcome(false, error: _friendly(error));

  static String _maskPhone(String phone) {
    final String trimmed = phone.trim();
    if (trimmed.length <= 4) return trimmed;
    return '${trimmed.substring(0, 3)}****${trimmed.substring(trimmed.length - 4)}';
  }

  static String _maskEmail(String email) {
    final String trimmed = email.trim();
    final int at = trimmed.indexOf('@');
    if (at <= 0) return trimmed;
    final String name = trimmed.substring(0, at);
    final String visible = name.length <= 2 ? name : name.substring(0, 2);
    return '$visible***${trimmed.substring(at)}';
  }

  static String _friendly(Object error) {
    if (Catalog.isRateLimited(error)) return '操作过于频繁，请稍后再试。';
    if (error is MusicGatewayException) {
      return error.authenticationFailure
          ? '服务器拒绝了登录，请检查用户名和密码。'
          : '音乐服务器连接失败，请稍后重试。';
    }
    if (error is ArgumentError) return error.message?.toString() ?? '输入无效。';
    return '连接失败，请检查网络后重试。';
  }

  @override
  void dispose() {
    _sampleListening();
    listeningStatistics.dispose();
    _pauseSchedule.dispose();
    _musicPlatforms.cancelPending();
    pluginManager.dispose();
    catalog.connections.close();
    _presentationDisposed = true;
    _lyricSnapshots.clear();
    _lyricRequest = null;
    currentArtwork.dispose();
    ++_seekRequest;
    playerPresented.dispose();
    browseTransitionActive.dispose();
    _paletteGeneration++;
    _fontGeneration++;
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
    playbackCache.dispose();
    super.dispose();
  }
}

class _LyricsSnapshot {
  _LyricsSnapshot(this.lines, this.pureMusic, this.imported)
    : savedAt = DateTime.now();
  final List<LyricLine> lines;
  final bool pureMusic, imported;
  final DateTime savedAt;
}

enum LoopMode { off, all, one }

/// One queued upload for the account's play record.
enum _PlayLogKind { start, play }

class _PlayReport {
  const _PlayReport({
    required this.songId,
    required this.kind,
    this.seconds = 0,
    required this.account,
  });

  final String songId, account;
  final _PlayLogKind kind;
  final int seconds;
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
