import '../animation/apple_spring.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/lyrics.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_palette.dart';
import '../utils/artwork.dart';
import '../utils/cover_save.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/artwork_image.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/plate_art.dart';

Future<void> showLyricImageDialog(
  BuildContext context, {
  required Track track,
  required List<LyricLine> lines,
  ui.Image? background,
}) {
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.tr('关闭'),
    barrierColor: Colors.black.withValues(alpha: context.colors.dark ? .6 : .3),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => themes.wrap(
      SafeArea(
        child: LyricImageDialog(
          track: track,
          lines: List.unmodifiable(lines),
          background: background,
        ),
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final eased = animation.drive(
        CurveTween(curve: const AppleSpringCurve()),
      );
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .035),
            end: Offset.zero,
          ).animate(eased),
          child: ScaleTransition(
            scale: Tween(begin: .96, end: 1.0).animate(eased),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Grabs the player backdrop exactly as it is painted right now. The returned
/// image is owned by the caller and must be disposed.
Future<ui.Image?> captureLyricBackdrop(GlobalKey? key) async {
  final renderObject = key?.currentContext?.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) return null;
  final Size size = renderObject.size;
  if (size.isEmpty) return null;
  try {
    await WidgetsBinding.instance.endOfFrame;
    // The card is exported at 1080 px wide; capture enough backdrop detail for
    // that final size without holding an oversized texture on desktop.
    final double ratio = (1080 / size.width).clamp(1.0, 3.0);
    return await renderObject.toImage(pixelRatio: ratio);
  } catch (_) {
    return null;
  }
}

/// The preview itself is captured, so exported text wrapping matches exactly.
Future<Uint8List> captureLyricImage(RenderRepaintBoundary boundary) async {
  final size = boundary.size;
  // Keep long selections within texture and memory limits without truncating.
  final ratio = math.min(
    3.0,
    math.min(
      16000 / math.max(size.width, size.height),
      math.sqrt(16000000 / (size.width * size.height)),
    ),
  );
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

class LyricImageDialog extends StatefulWidget {
  const LyricImageDialog({
    super.key,
    required this.track,
    required this.lines,
    this.background,
  });
  final Track track;
  final List<LyricLine> lines;

  /// A frame of the live player backdrop, used behind the exported lyrics.
  final ui.Image? background;

  @override
  State<LyricImageDialog> createState() => _LyricImageDialogState();
}

class _LyricImageDialogState extends State<LyricImageDialog> {
  final _imageKey = GlobalKey();
  final _previewScroll = ScrollController();
  ImageProvider? _artwork;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  bool _started = false;
  String? _error;

  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 240);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_loadArtwork());
    }
  }

  Future<void> _loadArtwork() async {
    final url = enlargedArtworkUrl(widget.track.coverUrl);
    if (url != null && url.isNotEmpty) {
      _artwork = ArtworkImage(url);
      await precacheImage(
        _artwork!,
        context,
        onError: (_, _) => _artwork = null,
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _imageKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final bytes = await captureLyricImage(boundary);
      if (!mounted) return;
      final saved = await saveCoverBytes(
        bytes,
        '${widget.track.title} - lyrics',
      );
      if (mounted && saved) setState(() => _saved = true);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请检查相册权限或稍后重试。'); // i18n:key
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _preview() => AnimatedSwitcher(
    duration: _motion,
    switchInCurve: const AppleSpringCurve(),
    switchOutCurve: const AppleSpringCurve(),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .025),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) => Stack(
      fit: StackFit.expand,
      children: [
        for (final old in previous)
          ExcludeSemantics(child: IgnorePointer(child: old)),
        ?current,
      ],
    ),
    child: _loading
        ? Center(
            key: const ValueKey('lyric-image-loading'),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 40,
                    color: context.colors.cloudMedium,
                  ),
                  const SizedBox(height: 20),
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(height: 12),
                  TrText('正在加载封面…', style: context.type.captionMuted),
                ],
              ),
            ),
          )
        : Scrollbar(
            key: const ValueKey('lyric-image-preview'),
            controller: _previewScroll,
            thumbVisibility: true,
            thickness: 3,
            radius: const Radius.circular(2),
            child: SingleChildScrollView(
              controller: _previewScroll,
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topCenter,
                  child: RepaintBoundary(
                    key: _imageKey,
                    child: LyricImageCard(
                      track: widget.track,
                      lines: widget.lines,
                      artwork: _artwork,
                      background: widget.background,
                    ),
                  ),
                ),
              ),
            ),
          ),
  );

  Widget _status() => AnimatedSwitcher(
    duration: _motion,
    switchInCurve: const AppleSpringCurve(),
    switchOutCurve: const AppleSpringCurve(),
    transitionBuilder: (child, animation) => SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: animation, child: child),
    ),
    child: _error == null && !_saved
        ? const SizedBox.shrink(key: ValueKey('lyric-image-status-empty'))
        : Builder(
            builder: (context) {
              final Color color = _error == null
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error;
              return Padding(
                key: ValueKey(_error ?? 'saved'),
                padding: const EdgeInsets.only(bottom: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _error == null
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        size: 18,
                        color: color,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TrText(
                          _error ?? '歌词图片已保存',
                          style: context.type.caption.copyWith(color: color),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
  );

  Widget _header() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.image_outlined, size: 22, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrText(
                  '生成歌词图片',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.subheading.copyWith(
                    fontSize: 20,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.captionMuted,
                ),
              ],
            ),
          ),
          AccessibleIconButton(
            tooltip: '关闭',
            onPressed: _saving ? null : () => Navigator.pop(context),
            style: IconButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              foregroundColor: scheme.onSurface.withValues(alpha: .72),
            ),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final back = SpringTextButton(
      onPressed: _saving
          ? null
          : feedbackAction(context, () => Navigator.pop(context)),
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        foregroundColor: scheme.onSurface.withValues(alpha: .78),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        enableFeedback: false,
      ),
      child: const TrText('返回选择', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final save = _SaveImageButton(
      saving: _saving,
      saved: _saved,
      onPressed: _loading || _saving ? null : () => unawaited(_save()),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _status(),
          if (MediaQuery.textScalerOf(context).scale(14) > 20)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [save, const SizedBox(height: 8), back],
            )
          else
            Row(
              children: [
                back,
                const SizedBox(width: 12),
                Expanded(child: save),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color divider = scheme.onSurface.withValues(alpha: .10);
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 520,
          height: math.min(
            780,
            math.max(
              0,
              MediaQuery.sizeOf(context).height -
                  MediaQuery.paddingOf(context).vertical -
                  24,
            ),
          ),
          child: Column(
            children: [
              _header(),
              Divider(height: 1, color: divider),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            TrText('图片预览', style: context.type.captionStrong),
                            TrText(
                              '已选择 ${widget.lines.length} 行',
                              style: context.type.captionMuted,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.onSurface.withValues(alpha: .04),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: divider),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: ShaderMask(
                              blendMode: BlendMode.dstIn,
                              shaderCallback: (bounds) {
                                final fade = math.min(
                                  .12,
                                  12 / math.max(1, bounds.height),
                                );
                                return LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: const [
                                    Colors.transparent,
                                    Colors.black,
                                    Colors.black,
                                    Colors.transparent,
                                  ],
                                  stops: [0, fade, 1 - fade, 1],
                                ).createShader(bounds);
                              },
                              child: _preview(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: divider),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _previewScroll.dispose();
    widget.background?.dispose();
    super.dispose();
  }
}

class _SaveImageButton extends StatefulWidget {
  const _SaveImageButton({
    required this.saving,
    required this.saved,
    required this.onPressed,
  });
  final bool saving, saved;
  final VoidCallback? onPressed;
  @override
  State<_SaveImageButton> createState() => _SaveImageButtonState();
}

class _SaveImageButtonState extends State<_SaveImageButton> {
  bool _pressed = false;

  void _press(bool value) {
    if (mounted && _pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: widget.onPressed == null ? null : (_) => _press(true),
      onPointerUp: (_) => _press(false),
      onPointerCancel: (_) => _press(false),
      child: AnimatedScale(
        scale: _pressed ? .97 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 140),
        curve: const AppleSpringCurve(),
        child: SpringFilledButton(
          onPressed: feedbackAction(context, widget.onPressed),
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            backgroundColor: widget.saved
                ? scheme.primary.withValues(alpha: .78)
                : scheme.primary,
            foregroundColor: scheme.onPrimary,
            disabledBackgroundColor: scheme.onSurface.withValues(alpha: .12),
            disabledForegroundColor: scheme.onSurface.withValues(alpha: .45),
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            enableFeedback: false,
          ),
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            switchInCurve: const AppleSpringCurve(),
            switchOutCurve: const AppleSpringCurve(),
            child: Row(
              key: ValueKey((widget.saving, widget.saved)),
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.saving
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : Icon(
                        widget.saved
                            ? Icons.check_rounded
                            : Icons.save_alt_rounded,
                        size: 18,
                      ),
                const SizedBox(width: 8),
                Flexible(
                  child: TrText(
                    widget.saving
                        ? '正在保存…'
                        : widget.saved
                        ? '再次保存'
                        : '保存图片',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A fixed-width, app-painted lyric sheet over the live player backdrop.
class LyricImageCard extends StatelessWidget {
  const LyricImageCard({
    super.key,
    required this.track,
    required this.lines,
    this.artwork,
    this.background,
  });
  final Track track;
  final List<LyricLine> lines;
  final ImageProvider? artwork;

  /// A painted frame of the player's flowing backdrop.
  final ui.Image? background;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ui.Image? image = background;
    final bool hasBackdrop = image != null;
    final Color primaryText = hasBackdrop ? Colors.white : scheme.onSurface;
    final Color mutedText = hasBackdrop
        ? Colors.white.withValues(alpha: .72)
        : scheme.onSurface.withValues(alpha: .62);
    final Color divider = hasBackdrop
        ? Colors.white.withValues(alpha: .24)
        : scheme.onSurface.withValues(alpha: .20);
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        width: 360,
        child: Stack(
          children: [
            if (image != null) ...[
              Positioned.fill(
                child: RawImage(
                  image: image,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x40000000), Color(0x99000000)],
                      stops: <double>[0, .55],
                    ),
                  ),
                ),
              ),
            ] else
              Positioned.fill(child: ColoredBox(color: scheme.surface)),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 26, 18, 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 24,
                            spreadRadius: 1,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: artwork == null
                            ? PlateArt(seed: track.coverSeed)
                            : Image(image: artwork!, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    track.title,
                    style: context.type.heading.copyWith(
                      fontSize: 28,
                      height: 1.25,
                      color: primaryText,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    track.album,
                    style: context.type.bodySm.copyWith(color: mutedText),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.artist,
                    style: context.type.bodySm.copyWith(color: mutedText),
                  ),
                  Divider(height: 20, color: divider),
                  for (var i = 0; i < lines.length; i++) ...[
                    if (i > 0) const SizedBox(height: 24),
                    Text(
                      lines[i].text.trim(),
                      style: context.type.body.copyWith(
                        fontSize: 20,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        color: primaryText,
                      ),
                    ),
                    if (lines[i].translation?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: 4),
                      Text(
                        lines[i].translation!.trim(),
                        style: context.type.bodySm.copyWith(
                          fontSize: 14,
                          height: 1.5,
                          color: mutedText,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
