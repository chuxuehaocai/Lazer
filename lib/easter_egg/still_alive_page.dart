import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../animation/view_transitions.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../updates/open_external.dart';
import '../widgets/spring_buttons.dart';
import '../widgets/window_chrome.dart';
import 'still_alive_audio.dart';

const String frumsCreditsRepository =
    'https://github.com/sititou70/frums-credits-cli-nosound';

Future<void> openStillAlive(BuildContext context, AppState state) {
  state.pause();
  return Navigator.of(context).push<void>(
    ApplePageRoute<void>(builder: (_) => StillAlivePage(appState: state)),
  );
}

/// The centered, silent Frums credits easter egg.
class StillAlivePage extends StatefulWidget {
  const StillAlivePage({super.key, this.playback, this.clock, this.appState});

  final StillAlivePlayback? playback;
  final AppState? appState;

  @visibleForTesting
  final Duration Function()? clock;

  @override
  State<StillAlivePage> createState() => _StillAlivePageState();
}

class _StillAlivePageState extends State<StillAlivePage> {
  static const Color _amber = Color(0xffffbc63);
  static const Color _background = Colors.black;

  late final StillAlivePlayback _audio =
      widget.playback ?? StillAliveAudio(volume: widget.appState?.volume ?? 1);

  @override
  void dispose() {
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
                seedColor: _amber,
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
                style: IconButton.styleFrom(foregroundColor: _amber),
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
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: DecoratedBox(
                              key: const ValueKey('still-alive-report'),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _amber.withValues(alpha: .65),
                                ),
                                borderRadius: BorderRadius.circular(12),
                                color: _amber.withValues(alpha: .04),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                  vertical: 32,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    const Text(
                                      'FRUMS CREDITS',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _amber,
                                        fontSize: 28,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 2.4,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'Credits / Frums BGA on Linux tty',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _amber.withValues(alpha: .8),
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 22),
                                    const SelectableText(
                                      frumsCreditsRepository,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _amber,
                                        fontSize: 14,
                                        height: 1.45,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    SpringTextButton(
                                      onPressed: () => unawaited(
                                        openExternalUrl(frumsCreditsRepository),
                                      ),
                                      child: const TrText('打开仓库'),
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
