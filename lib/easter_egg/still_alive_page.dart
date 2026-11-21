import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../animation/view_transitions.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../widgets/window_chrome.dart';
import 'frums_credits.dart';
import 'still_alive_audio.dart';

Future<void> openStillAlive(BuildContext context, AppState state) {
  state.pause();
  return Navigator.of(context).push<void>(
    ApplePageRoute<void>(builder: (_) => StillAlivePage(appState: state)),
  );
}

/// The centered Frums credits easter egg.
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
    with SingleTickerProviderStateMixin {
  static const Color _foreground = Colors.white;
  static const Color _background = Colors.black;

  late final StillAlivePlayback _audio =
      widget.playback ?? StillAliveAudio(volume: widget.appState?.volume ?? 1);
  late final Ticker _ticker = createTicker(_tick);
  FrumsCreditsScore? _score;
  Object? _loadError;
  String _frame = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadCredits());
    unawaited(_startAudio());
  }

  Future<void> _startAudio() async {
    try {
      await _audio.load();
      if (!mounted) return;
      await _audio.play();
    } catch (_) {
      // The animation remains usable when a platform decoder cannot open the
      // bundled soundtrack.
    }
  }

  Future<void> _loadCredits() async {
    try {
      final score = await FrumsCreditsScore.load();
      if (!mounted) return;
      setState(() {
        _score = score;
        _frame = score.frameAt(Duration.zero);
      });
      _ticker.start();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  void _tick(Duration elapsed) {
    final score = _score;
    if (!mounted || score == null) return;
    final frame = score.frameAt(elapsed);
    if (frame == _frame) return;
    setState(() => _frame = frame);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): close,
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) unawaited(_audio.pause());
          },
          child: Theme(
            data: ThemeData(
              brightness: Brightness.dark,
              colorScheme: ColorScheme.fromSeed(
                seedColor: _foreground,
                brightness: Brightness.dark,
              ),
              scaffoldBackgroundColor: _background,
              fontFamily: 'LazerMono',
              fontFamilyFallback: const <String>[
                'MiSans',
                'Consolas',
                'Menlo',
                'monospace',
              ],
              iconButtonTheme: IconButtonThemeData(
                style: IconButton.styleFrom(foregroundColor: _foreground),
              ),
            ),
            child: Scaffold(
              backgroundColor: _background,
              body: SafeArea(
                child: WindowChromeHeader(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Positioned(
                        top: 0,
                        right: 8,
                        child: IconButton(
                          key: const ValueKey('still-alive-close'),
                          tooltip: context.tr('返回'),
                          onPressed: close,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: 620,
                              maxHeight: 680,
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              height: double.infinity,
                              child: Padding(
                                key: const ValueKey('still-alive-report'),
                                padding: const EdgeInsets.fromLTRB(
                                  28,
                                  24,
                                  28,
                                  16,
                                ),
                                child: Column(
                                  children: <Widget>[
                                    const Text(
                                      'FRUMS CREDITS',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _foreground,
                                        fontSize: 28,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 2.4,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: _FrumsCreditsViewport(
                                        frame: _frame,
                                        error: _loadError,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FrumsCreditsViewport extends StatelessWidget {
  const _FrumsCreditsViewport({required this.frame, required this.error});

  final String frame;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Text(
          'FRUMS CREDITS',
          key: const ValueKey('frums-credits-animation'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      );
    }
    if (frame.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey('frums-credits-animation'),
          color: Colors.white,
          strokeWidth: 2,
        ),
      );
    }
    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: Text(
          frame,
          key: const ValueKey('frums-credits-animation'),
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'LazerMono',
            fontFeatures: [FontFeature.disable('liga')],
            fontSize: 20,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}
