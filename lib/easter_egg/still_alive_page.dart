import '../widgets/build_safe_state.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../animation/view_transitions.dart';

import '../state/app_state.dart';
import '../l10n/app_localizations.dart';
import 'still_alive_audio.dart';
import 'still_alive_score.dart';

Future<void> openStillAlive(BuildContext context, AppState state) {
  state.pause();
  return Navigator.of(context).push<void>(
    ApplePageRoute<void>(builder: (_) => StillAlivePage(appState: state)),
  );
}

/// The terminal credits, fitted to this viewport rather than a fixed DPI or
/// orientation. Audio remains the clock; no timers accumulate lyric delays.
class StillAlivePage extends StatefulWidget {
  const StillAlivePage({super.key, this.playback, this.clock, this.appState});
  final StillAlivePlayback? playback;
  final AppState? appState;
  @visibleForTesting
  final Duration Function()? clock;
  @override
  State<StillAlivePage> createState() => _StillAlivePageState();
}

class _StillAlivePageState extends State<StillAlivePage>
    with WidgetsBindingObserver, BuildSafeState<StillAlivePage> {
  static const _amber = Color(0xffffbc63);
  static const _background = Colors.black;
  final _score = StillAliveScore.original;
  late final StillAlivePlayback _audio =
      widget.playback ?? StillAliveAudio(volume: widget.appState?.volume ?? 1);
  late double _volume = widget.appState?.volume ?? 1;
  Timer? _poll;
  Duration? _pollPeriod;
  Timer? _musicStartTimer;
  bool _active = true;
  bool _tickerEnabled = true;
  bool _reduceMotion = false;
  bool _starting = true;
  bool _demo = false;
  bool _prelude = true;
  bool _musicStarted = false;
  final Stopwatch _clock = Stopwatch()..start();
  Duration _sequenceBase = Duration.zero;
  Duration? _sequenceStartedAt;
  Duration _position = Duration.zero;
  late StillAliveFrame _frame = _score.frameAt(Duration.zero);

  Duration get _now => widget.clock?.call() ?? _clock.elapsed;
  Duration get _sequenceElapsed =>
      _sequenceBase +
      (_sequenceStartedAt == null ? Duration.zero : _now - _sequenceStartedAt!);
  bool get _playing =>
      _demo || _prelude ? _sequenceStartedAt != null : _audio.playing;
  bool get _ended {
    if (_demo) return _frame.finished;
    final duration = _audio.duration;
    return !_prelude &&
        _musicStarted &&
        !_audio.playing &&
        duration != null &&
        duration > Duration.zero &&
        _audio.position >= duration;
  }

  Duration get _displayDuration => _demo || _audio.duration == null
      ? _score.duration
      : _score.musicStart + _audio.duration!;
  bool get _visualsEnabled => _active && _tickerEnabled;
  Duration get _pollInterval => _reduceMotion
      ? const Duration(seconds: 1)
      : const Duration(milliseconds: 33);
  @visibleForTesting
  Duration get debugPollInterval => _pollInterval;
  @visibleForTesting
  bool get debugIsPolling => _poll != null;

  void _freezeSequence() {
    _sequenceBase = _sequenceElapsed;
    _sequenceStartedAt = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audio.addListener(_audioChanged);
    widget.appState?.addListener(_volumeChanged);
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    await _audio.setVolume(_volume);
    await _audio.load();
    if (!mounted) return;
    if (_audio.ready && _audio.error == null) _beginPrelude();
    setState(() => _starting = false);
    _audioChanged();
  }

  void _volumeChanged() {
    final volume = widget.appState?.volume ?? 1;
    if (_volume == volume) return;
    _volume = volume;
    unawaited(_audio.setVolume(volume));
  }

  @override
  void didUpdateWidget(StillAlivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) {
      oldWidget.appState?.removeListener(_volumeChanged);
      widget.appState?.addListener(_volumeChanged);
      _volumeChanged();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_tickerEnabled == tickerEnabled && _reduceMotion == reduceMotion) {
      return;
    }
    final wasEnabled = _visualsEnabled;
    _tickerEnabled = tickerEnabled;
    _reduceMotion = reduceMotion;
    if (_visualsEnabled) {
      _readFrame();
      if (!wasEnabled) setState(() {});
    }
    _syncPolling();
  }

  void _beginPrelude() {
    _musicStartTimer?.cancel();
    _prelude = true;
    _musicStarted = false;
    _sequenceBase = Duration.zero;
    _sequenceStartedAt = _now;
    _scheduleMusic();
  }

  void _scheduleMusic() {
    _musicStartTimer?.cancel();
    if (!_prelude || _demo || _sequenceStartedAt == null) return;
    final remaining = _score.musicStart - _sequenceElapsed;
    _musicStartTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => unawaited(_startMusic()),
    );
  }

  Future<void> _startMusic() async {
    if (!mounted || !_prelude || _sequenceStartedAt == null || _demo) return;
    _freezeSequence();
    _prelude = false;
    _musicStarted = true;
    // The reference starts the recording after its terminal prelude. Restart
    // from the first audio frame here, including when replaying the credits.
    await _audio.restart();
    if (mounted) _audioChanged();
  }

  void _audioChanged() {
    if (!mounted) return;
    _readFrame();
    if (_visualsEnabled) setState(() {});
    _syncPolling();
  }

  void _readFrame() {
    _position = _demo || _prelude
        ? _sequenceElapsed
        : (_musicStarted ? _score.musicStart + _audio.position : Duration.zero);
    _frame = _score.frameAt(_position);
  }

  void _syncPolling() {
    if (!_visualsEnabled || !_playing) {
      _poll?.cancel();
      _poll = null;
      _pollPeriod = null;
      return;
    }
    final interval = _pollInterval;
    if (_poll != null && _pollPeriod == interval) return;
    _poll?.cancel();
    _pollPeriod = interval;
    _poll = Timer.periodic(interval, (_) {
      if (!mounted || !_visualsEnabled) return;
      final previous = _frame;
      _readFrame();
      if (_demo && _frame.finished) {
        _freezeSequence();
        _syncPolling();
      }
      if (_frame.text != previous.text ||
          _frame.asciiArt != previous.asciiArt ||
          _frame.creditsText != previous.creditsText ||
          _frame.cursorVisible != previous.cursorVisible ||
          _position.inSeconds != _lastSecond ||
          _frame.finished != previous.finished) {
        _lastSecond = _position.inSeconds;
        setState(() {});
      }
    });
  }

  int _lastSecond = -1;

  Future<void> _toggle() async {
    if (_demo) {
      if (_sequenceStartedAt != null) {
        _freezeSequence();
      } else {
        _sequenceStartedAt = _now;
      }
      _audioChanged();
    } else if (_prelude) {
      if (_sequenceStartedAt != null) {
        _freezeSequence();
        _musicStartTimer?.cancel();
      } else {
        _sequenceStartedAt = _now;
        _scheduleMusic();
      }
      _audioChanged();
    } else if (_playing) {
      await _audio.pause();
    } else {
      await _audio.play();
    }
  }

  Future<void> _restart() async {
    if (_demo) {
      _sequenceBase = Duration.zero;
      _sequenceStartedAt = _now;
      _audioChanged();
    } else {
      await _audio.pause();
      if (!mounted) return;
      _beginPrelude();
      _audioChanged();
    }
  }

  Future<void> _startDemo() async {
    await _audio.pause();
    if (!mounted) return;
    _demo = true;
    _musicStartTimer?.cancel();
    _sequenceBase = Duration.zero;
    _sequenceStartedAt = _now;
    _audioChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` means the view is still visible but has no input focus, which
    // on desktop is delivered as soon as another window is clicked. Suspending
    // the visuals there froze the typing, the cursor blink and the credits
    // while the terminal was on screen, and refocusing then jumped the whole
    // unfocused interval in one frame. Only real invisibility suspends the
    // visuals. Audio keeps running in every state either way.
    _active =
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
    // Keep audio and the scheduled music start running in the background.
    // Only visual polling is suspended; returning samples the live playhead.
    if (_visualsEnabled) _readFrame();
    _syncPolling();
    if (_visualsEnabled && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _musicStartTimer?.cancel();
    _clock.stop();
    _audio.removeListener(_audioChanged);
    widget.appState?.removeListener(_volumeChanged);
    _audio.dispose();
    super.dispose();
  }

  String _time(Duration position) {
    final seconds = math.max(0, position.inSeconds);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final mono = switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'Consolas',
      TargetPlatform.iOS || TargetPlatform.macOS => 'Menlo',
      _ => 'monospace',
    };
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _freezeSequence();
          _musicStartTimer?.cancel();
          unawaited(_audio.pause());
          _syncPolling();
        }
      },
      child: Theme(
        data: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: _amber,
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: _background,
          fontFamily: mono,
          iconButtonTheme: IconButtonThemeData(
            style: IconButton.styleFrom(foregroundColor: _amber),
          ),
        ),
        child: Scaffold(
          backgroundColor: _background,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final landscape = box.maxWidth > box.maxHeight * 1.15;
                final small = box.maxWidth < 300 || box.maxHeight < 300;
                final inset = small ? 6.0 : 16.0;
                final report = _TerminalPanel(
                  key: const ValueKey('still-alive-report'),
                  label: 'TEST ASSESSMENT REPORT',
                  text:
                      '${_frame.text}${_frame.cursorVisible && !_frame.finished && !_ended ? '_' : ' '}',
                  columns: _score.maxTextColumns + 1,
                  rows: _score.maxTextRows + 1,
                  mono: mono,
                  amber: _amber,
                );
                final art = _TerminalPanel(
                  key: const ValueKey('still-alive-art'),
                  label: 'APERTURE SCIENCE',
                  text: _frame.asciiArt,
                  columns: _score.maxArtColumns,
                  rows: _score.maxArtRows,
                  mono: mono,
                  amber: _amber,
                  centered: true,
                );
                final credits = _TerminalPanel(
                  key: const ValueKey('still-alive-credits'),
                  label: 'LIST PERSONNEL',
                  text: _frame.creditsText,
                  columns: _score.maxCreditsColumns,
                  rows: small ? 2 : 6,
                  mono: mono,
                  amber: _amber,
                  rolling: true,
                  showLabel: !small,
                  padding: small ? 3 : 8,
                );
                return Padding(
                  padding: EdgeInsets.all(inset),
                  child: Column(
                    children: [
                      SizedBox(
                        height: small ? 38 : 48,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                small
                                    ? 'STILL ALIVE'
                                    : 'APERTURE\nENRICHMENT CENTER',
                                maxLines: 2,
                                style: TextStyle(
                                  color: _amber,
                                  fontSize: small ? 10 : 13,
                                  height: 1.1,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('still-alive-close'),
                              tooltip: context.tr('返回'),
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: landscape
                            ? Row(
                                key: const ValueKey('still-alive-landscape'),
                                children: [
                                  Expanded(flex: 6, child: report),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 5,
                                    child: Column(
                                      children: [
                                        Expanded(flex: 4, child: credits),
                                        const SizedBox(height: 10),
                                        Expanded(flex: 7, child: art),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                key: const ValueKey('still-alive-portrait'),
                                children: [
                                  Expanded(flex: 6, child: report),
                                  const SizedBox(height: 10),
                                  Expanded(flex: 2, child: credits),
                                  const SizedBox(height: 10),
                                  Expanded(flex: 4, child: art),
                                ],
                              ),
                      ),
                      const SizedBox(height: 8),
                      if (_audio.error != null && !_demo)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            children: [
                              Text(
                                context.tr('音频暂时无法播放'),
                                style: TextStyle(
                                  color: _amber,
                                  fontSize: small ? 10 : 12,
                                ),
                              ),
                              SpringTextButton(
                                onPressed: _starting ? null : _start,
                                child: const TrText('重试'),
                              ),
                              SpringTextButton(
                                onPressed: _startDemo,
                                child: const TrText('静音演示'),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(
                        height: small ? 38 : 46,
                        child: Row(
                          children: [
                            if (!_ended)
                              IconButton(
                                key: const ValueKey('still-alive-play'),
                                tooltip: context.tr(_playing ? '暂停' : '播放'),
                                onPressed:
                                    _starting || (!_demo && !_audio.ready)
                                    ? null
                                    : _toggle,
                                icon: Icon(
                                  _playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                              ),
                            if (_ended)
                              SpringTextButton.icon(
                                key: const ValueKey('still-alive-restart'),
                                onPressed: _restart,
                                icon: const Icon(Icons.replay_rounded),
                                label: const TrText('重新播放'),
                              )
                            else
                              IconButton(
                                key: const ValueKey('still-alive-restart'),
                                tooltip: context.tr('重新播放'),
                                onPressed:
                                    _starting || (!_demo && !_audio.ready)
                                    ? null
                                    : _restart,
                                icon: const Icon(Icons.replay_rounded),
                              ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    _starting
                                        ? 'LOADING AUDIO…'
                                        : '${_time(_position)} / ${_time(_displayDuration)}',
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: _amber,
                                      fontSize: small ? 9 : 12,
                                    ),
                                  ),
                                  if (_demo || _frame.finished || _ended)
                                    Text(
                                      _demo
                                          ? context.tr('静音演示')
                                          : 'THANK YOU FOR PARTICIPATING',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _amber.withValues(alpha: .65),
                                        fontSize: small ? 8 : 10,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({
    super.key,
    required this.label,
    required this.text,
    required this.columns,
    required this.rows,
    required this.mono,
    required this.amber,
    this.centered = false,
    this.rolling = false,
    this.showLabel = true,
    this.padding = 8,
  });
  final String label, text, mono;
  final int columns, rows;
  final Color amber;
  final bool centered;
  final bool rolling;
  final bool showLabel;
  final double padding;
  static final Map<String, double> _glyphWidths = {};

  double get _glyphWidth => _glyphWidths.putIfAbsent(mono, () {
    final sample = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(fontFamily: mono, fontSize: 10, height: 1.2),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = sample.width / 10;
    sample.dispose();
    return width;
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: amber.withValues(alpha: .55)),
      color: Colors.black,
    ),
    child: Padding(
      padding: EdgeInsets.all(padding),
      child: LayoutBuilder(
        builder: (context, box) {
          final glyphWidth = _glyphWidth;
          final labelHeight = showLabel ? 19 : 0;
          final fontSize = math.max(
            1.0,
            math.min(
              (box.maxWidth - 2) / (columns * glyphWidth),
              math.max(0, box.maxHeight - labelHeight) / (rows * 1.2),
            ),
          );
          final visibleRows = rolling
              ? math.max(
                  1,
                  ((box.maxHeight - labelHeight) / (fontSize * 1.2)).floor(),
                )
              : rows;
          final lines = rolling ? text.split('\n') : const <String>[];
          final visibleText = rolling
              ? lines.skip(math.max(0, lines.length - visibleRows)).join('\n')
              : text;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showLabel)
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontFamily: mono,
                    color: amber.withValues(alpha: .6),
                    fontSize: math.min(10, math.max(5, fontSize)),
                    letterSpacing: .5,
                  ),
                ),
              if (showLabel) const SizedBox(height: 4),
              Expanded(
                child: Align(
                  alignment: rolling
                      ? Alignment.bottomLeft
                      : centered
                      ? Alignment.center
                      : Alignment.topLeft,
                  child: Text(
                    visibleText,
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontFamily: mono,
                      fontSize: fontSize,
                      height: 1.2,
                      color: amber,
                      fontFeatures: const [FontFeature.disable('liga')],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
