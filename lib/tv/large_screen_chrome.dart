// i18n:data — interface strings declared here are translated at their render sites.
/// The chrome of the large-screen presentation: the floating destination
/// capsule and the transport shelf.
///
/// Both sit outside the page content so a remote can always reach them with a
/// single vertical press, and both are built from the same focus target as the
/// content cards, so Select, the focus ring and Back behave identically
/// everywhere on the screen.
library;

import '../animation/apple_spring.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/copyable_song_title.dart';
import '../widgets/apple_ui.dart';
import '../widgets/interaction_feedback.dart';
import 'large_screen_widgets.dart';
import '../ui/player_bar.dart';

/// The destinations reachable from the capsule.
enum LargeScreenTab { home, library, likes, settings }

extension LargeScreenTabLabels on LargeScreenTab {
  /// Chinese source string, translated through `context.tr` at the render site.
  String get label => switch (this) {
    LargeScreenTab.home => '现在就听',
    LargeScreenTab.library => '资料库',
    LargeScreenTab.likes => '我喜欢',
    LargeScreenTab.settings => '设置',
  };

  IconData get icon => switch (this) {
    LargeScreenTab.home => Icons.play_circle_fill_rounded,
    LargeScreenTab.library => Icons.library_music_rounded,
    LargeScreenTab.likes => Icons.favorite_rounded,
    LargeScreenTab.settings => Icons.settings_rounded,
  };
}

/// The Apple Music television destination bar: avatar, floating capsule,
/// magnifier. The selected chip is inverted (light on dark, dark on light) so
/// the current place is legible from across a room.
class LargeScreenNavBar extends StatelessWidget {
  const LargeScreenNavBar({
    super.key,
    required this.selected,
    required this.searchActive,
    required this.canGoBack,
    required this.onBack,
    required this.onTab,
    required this.onSearch,
    required this.onNowPlaying,
    required this.account,
    this.playing = false,
  });

  final LargeScreenTab selected;
  final bool searchActive;
  final bool canGoBack;
  final VoidCallback onBack;
  final ValueChanged<LargeScreenTab> onTab;
  final VoidCallback onSearch;
  final VoidCallback onNowPlaying;
  final Widget account;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    return SizedBox(
      height: LargeScreenMetrics.navBarHeight + 10,
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, 0, inset, 0),
        child: Row(
          children: <Widget>[
            if (canGoBack) ...<Widget>[
              _NavBackButton(onTap: onBack),
              const SizedBox(width: 12),
            ],
            account,
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Container(
                    height: LargeScreenMetrics.navBarHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: apple.fill.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(
                        LargeScreenMetrics.navBarHeight / 2,
                      ),
                      border: Border.all(
                        color: apple.separator.withValues(alpha: .55),
                        width: .5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final LargeScreenTab tab in LargeScreenTab.values)
                          _NavChip(
                            key: ValueKey<String>(
                              'large-screen-tab-${tab.name}',
                            ),
                            label: tab.label,
                            icon: tab.icon,
                            selected: !searchActive && tab == selected,
                            onTap: () => onTab(tab),
                          ),
                        Container(
                          width: .5,
                          height: 24,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          color: apple.separator,
                        ),
                        _NavChip(
                          key: const ValueKey<String>(
                            'large-screen-now-playing',
                          ),
                          label: '正在播放',
                          icon: playing
                              ? Icons.graphic_eq_rounded
                              : Icons.play_circle_outline_rounded,
                          selected: false,
                          onTap: onNowPlaying,
                        ),
                        _NavChip(
                          key: const ValueKey<String>('large-screen-search'),
                          icon: Icons.search_rounded,
                          selected: searchActive,
                          onTap: onSearch,
                          iconOnly: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Balances the avatar so the capsule stays optically centred.
            const SizedBox(width: 40),
          ],
        ),
      ),
    );
  }
}

class _NavChip extends StatefulWidget {
  const _NavChip({
    super.key,
    this.label,
    this.icon,
    required this.selected,
    required this.onTap,
    this.iconOnly = false,
  });

  final String? label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final bool iconOnly;

  @override
  State<_NavChip> createState() => _NavChipState();
}

class _NavChipState extends State<_NavChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Color foreground = widget.selected
        ? apple.background
        : apple.label.withValues(alpha: .82);
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, widget.onTap),
      onFocusChange: (bool value) => setState(() => _focused = value),
      borderRadius: BorderRadius.circular(24),
      focusScale: 1.06,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppleSpring.responsive.duration,
        curve: const AppleSpringCurve(),
        height: 46,
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        padding: EdgeInsets.symmetric(horizontal: widget.iconOnly ? 13 : 20),
        decoration: BoxDecoration(
          color: widget.selected
              ? apple.label
              : _focused
              ? apple.fill
              : Colors.transparent,
          borderRadius: BorderRadius.circular(23),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.icon != null)
              Icon(
                widget.icon,
                size: widget.iconOnly ? 23 : 18,
                color: foreground,
              ),
            if (widget.label != null) ...<Widget>[
              if (widget.icon != null) const SizedBox(width: 8),
              Text(
                context.tr(widget.label!),
                style: LargeScreenType.button(
                  context,
                ).copyWith(fontSize: 18, color: foreground),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NavBackButton extends StatelessWidget {
  const _NavBackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, onTap),
      borderRadius: BorderRadius.circular(22),
      focusScale: 1.08,
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(8, 0, 18, 0),
        decoration: BoxDecoration(
          color: apple.fill,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.chevron_left_rounded, size: 26, color: apple.label),
            Text(
              context.tr('返回'),
              style: LargeScreenType.button(
                context,
              ).copyWith(color: apple.label),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating transport card.
///
/// It keeps the things a listener reaches for from a sofa: what is playing
/// (open the player), previous/play/next in the centre, and like / queue /
/// expand on the right. The strip itself is a rounded translucent card with a
/// soft shadow: it floats over the page, so the artwork scrolled underneath
/// stays part of the canvas. The seek rail lives in the player.
class LargeScreenTransport extends StatelessWidget {
  const LargeScreenTransport({
    super.key,
    required this.state,
    required this.onOpen,
  });

  final AppState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    final BorderRadius radius = BorderRadius.circular(26);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: .34),
              blurRadius: 26,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: .16),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: AppleGlass(
          borderRadius: radius,
          blurSigma: 16,
          color: apple.glassStrong,
          border: Border.all(
            color: apple.separator.withValues(alpha: .6),
            width: .5,
          ),
          child: SizedBox(
            height: LargeScreenMetrics.transportHeight,
            child: AnimatedBuilder(
              animation: state,
              builder: (BuildContext context, Widget? _) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      // Equal flex on both sides keeps the transport controls
                      // on the screen's centre line, not merely in the gap the
                      // artwork and actions happen to leave.
                      Expanded(
                        child: _TransportMeta(state: state, onOpen: onOpen),
                      ),
                      _TransportControls(state: state),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _TransportActions(
                            state: state,
                            onOpen: onOpen,
                          ),
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

class _TransportMeta extends StatelessWidget {
  const _TransportMeta({required this.state, required this.onOpen});

  final AppState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String title = state.current?.title ?? context.tr('未选择曲目');
    final String artist = state.current?.artist ?? context.tr('从任何一张封面开始播放');
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, state.current == null ? null : onOpen),
      borderRadius: BorderRadius.circular(14),
      focusScale: 1.01,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: <Widget>[
            LargeScreenArtwork(
              url: state.current?.coverUrl,
              size: 56,
              radius: 10,
              iconScale: .34,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  state.current == null
                      ? Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LargeScreenType.rowTitle(context),
                        )
                      : CopyableSongTitle(
                          title: title,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: LargeScreenType.rowTitle(context),
                          ),
                        ),
                  const SizedBox(height: 2),
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LargeScreenType.rowMeta(context).copyWith(
                      color: state.playing
                          ? apple.accent
                          : LargeScreenType.rowMeta(context).color,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _TransportGlyph(
          icon: Icons.skip_previous_rounded,
          tooltip: '上一首',
          size: 48,
          onTap: state.current == null ? null : state.previous,
        ),
        const SizedBox(width: 4),
        _TransportGlyph(
          icon: state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: state.playing ? '暂停' : '播放',
          size: 58,
          filled: true,
          onTap: state.current == null ? null : state.togglePlay,
        ),
        const SizedBox(width: 4),
        _TransportGlyph(
          icon: Icons.skip_next_rounded,
          tooltip: '下一首',
          size: 48,
          onTap: state.current == null ? null : state.next,
        ),
      ],
    );
  }
}

class _TransportGlyph extends StatefulWidget {
  const _TransportGlyph({
    required this.icon,
    required this.tooltip,
    required this.size,
    this.filled = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final double size;
  final bool filled;
  final VoidCallback? onTap;

  @override
  State<_TransportGlyph> createState() => _TransportGlyphState();
}

class _TransportGlyphState extends State<_TransportGlyph> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool enabled = widget.onTap != null;
    final Color background = widget.filled ? apple.label : Colors.transparent;
    final Color foreground = widget.filled ? apple.background : apple.label;
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, widget.onTap),
      onFocusChange: (bool value) => setState(() => _focused = value),
      borderRadius: BorderRadius.circular(widget.size / 2),
      focusScale: 1.1,
      child: AnimatedContainer(
        curve: const AppleSpringCurve(),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppleSpring.responsive.duration,
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.filled
              ? background
              : _focused
              ? apple.fill
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          widget.icon,
          size: widget.size * (widget.filled ? .5 : .55),
          color: foreground.withValues(alpha: enabled ? 1 : .35),
        ),
      ),
    );
  }
}

class _TransportActions extends StatelessWidget {
  const _TransportActions({required this.state, required this.onOpen});

  final AppState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _TransportGlyph(
          icon: state.currentLiked
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          tooltip: state.currentLiked ? '取消喜欢' : '喜欢',
          size: 44,
          onTap: state.current == null
              ? null
              : () => unawaited(state.toggleLikeCurrent()),
        ),
        const SizedBox(width: 2),
        SizedBox(
          width: 40,
          height: 44,
          child: Center(
            child: Transform.scale(
              scale: 1.15,
              child: AppQueueButton(state: state),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _TransportGlyph(
          icon: Icons.open_in_full_rounded,
          tooltip: '正在播放',
          size: 44,
          onTap: state.current == null ? null : onOpen,
        ),
      ],
    );
  }
}
