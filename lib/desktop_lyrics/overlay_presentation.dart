part of 'lyrics_overlay.dart';

// Rendering and hit-region measurement share the same bounded visible rows.
extension _OverlayPresentation on _LyricsOverlayAppState {
  TextStyle _textStyle(double scale) {
    final theme = _theme;
    return lyricTextStyle(
      TextStyle(
        fontFamily: _settings.fontFamily,
        fontFamilyFallback: const <String>[
          'MiSans',
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans CJK SC',
        ],
        fontSize: _settings.fontSize * scale * theme.lyricFontScale,
        fontWeight: theme.lyricFontWeight(_settings.fontWeight),
        height: theme.lyricLineHeight,
        color: Colors.white,
        letterSpacing: 0,
        decoration: TextDecoration.none,
        shadows: const <Shadow>[
          Shadow(
            color: Color(0x38000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
          Shadow(color: Color(0x20000000), blurRadius: 3),
        ],
      ),
      _settings.fontSize * scale,
      _settings.fontWeight,
      theme: theme,
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final bool desktop = _mode == LyricsOverlayMode.desktop;
    final double slot = _slotHeight;
    final int count = _settings.lineCount.clamp(1, 5);
    final Size window = MediaQuery.sizeOf(context);
    final double inset = _horizontalPadding;
    final bool hasText = _lines.any(
      (LyricLine line) => line.text.trim().isNotEmpty,
    );
    final List<Rect> regions = lyricsOverlayInteractiveRegions(
      window,
      desktop: desktop,
      locked: _settings.locked,
      lyricBounds: desktop ? const <Rect>[] : _lyricHitBounds(window),
    );
    _syncInteractionRegions(regions);
    final Widget block = Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        if (!hasText) _notice(desktop),
        if (hasText)
          for (
            var offset = -(count ~/ 2);
            offset < count - count ~/ 2;
            offset++
          )
            if (_focus + offset >= 0 && _focus + offset < _lines.length)
              _row(_focus + offset, slot, inset),
      ],
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(child: block),
          for (final Rect rect in regions.skip(1))
            Positioned.fromRect(
              rect: rect,
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => unawaited(_startDrag()),
                ),
              ),
            ),
          if (regions.isNotEmpty) _desktopDragHandle(window.height),
        ],
      ),
    );
  }

  List<Rect> _lyricHitBounds(Size size) {
    if (_lines.isEmpty) {
      return <Rect>[
        Rect.fromCenter(
          center: size.center(Offset.zero),
          width: math.max(0, size.width - _horizontalPadding * 2),
          height: math.min(size.height - _verticalPadding * 2, _slotHeight),
        ),
      ];
    }
    final theme = _theme;
    final int count = _settings.lineCount.clamp(1, 5);
    final double slot = _slotHeight;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
      ellipsis: '…',
    );
    final bounds = <Rect>[];
    try {
      for (int offset = -(count ~/ 2); offset < count - count ~/ 2; offset++) {
        final int index = _focus + offset;
        if (index < 0 || index >= _lines.length) continue;
        final line = _lines[index];
        if (line.text.trim().isEmpty) continue;
        double width = 0;
        double height = 0;
        final texts = <String>[
          line.text,
          if (_settings.showRomanization && line.romanization != null)
            line.romanization!,
          if (line.translation != null) line.translation!,
        ];
        for (int i = 0; i < texts.length; i++) {
          painter.text = TextSpan(
            text: texts[i],
            style: i == 0
                ? _lyricStyle
                : _lyricStyle.copyWith(
                    fontSize: (_settings.fontSize * theme.lyricTranslationScale)
                        .clamp(12, 30),
                    height: theme.lyricTranslationLineHeight,
                  ),
          );
          painter.layout(
            maxWidth: math.max(0, size.width - _horizontalPadding * 2),
          );
          width = math.max(width, painter.width);
          height += painter.height + (i == 0 ? 0 : theme.lyricTranslationGap);
        }
        bounds.add(
          Rect.fromLTWH(
            _horizontalPadding - 6,
            _verticalPadding +
                (offset + count ~/ 2) * slot +
                (slot - height) / 2 -
                6,
            width + 12,
            height + 12,
          ),
        );
      }
    } finally {
      painter.dispose();
    }
    return bounds;
  }

  Widget _row(int index, double slot, double inset) {
    final OverlayLineMotion? motion = _motions[index];
    if (motion == null) return const SizedBox.shrink();
    final bool active = index == _focus;
    if (_lines[index].text.trim().isEmpty) {
      return _interludeRow(index, motion, slot, inset, active);
    }
    final theme = _theme;
    double emphasis() =>
        ((motion.scale.value - (100 - theme.lyricFocusScaleDelta)) /
                theme.lyricFocusScaleDelta)
            .clamp(0.0, 1.0);
    final line = _lines[index];
    final Widget text = Semantics(
      container: true,
      excludeSemantics: true,
      label: lyricSemanticLabel(
        line,
        showRomanization: _settings.showRomanization,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LyricLineContent(
            line: line,
            style: _lyricStyle,
            active: active,
            position: () =>
                Duration(microseconds: (_currentPositionMs * 1000).round()),
            repaint: _frames,
            emphasis: emphasis,
            maxLines: 1,
          ),
          for (final secondary in <String?>[
            if (_settings.showRomanization) line.romanization,
            line.translation,
          ].whereType<String>()) ...[
            SizedBox(height: theme.lyricTranslationGap),
            Text(
              secondary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _lyricStyle.copyWith(
                fontSize: (_settings.fontSize * theme.lyricTranslationScale)
                    .clamp(12, 30),
                height: theme.lyricTranslationLineHeight,
                fontWeight: theme.lyricTranslationFontWeight(
                  _settings.fontWeight,
                ),
                color: Colors.white.withValues(
                  alpha: theme.lyricTranslationAlpha,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    final double activeY = _verticalPadding + (_settings.lineCount ~/ 2) * slot;
    return Positioned(
      key: ValueKey<int>(index),
      top: 0,
      left: inset,
      right: inset,
      height: slot,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _frames,
          child: text,
          builder: (BuildContext context, Widget? child) {
            final double emphasis =
                ((motion.scale.value - (100 - theme.lyricFocusScaleDelta)) /
                        theme.lyricFocusScaleDelta)
                    .clamp(0.0, 1.0);
            final double opacity =
                theme.lyricDimAlpha + (1 - theme.lyricDimAlpha) * emphasis;
            // The overlay only ever shows a handful of rows, so a blur that
            // starts at the neighbouring line leaves every line above and
            // below the current one unreadable. Keeping the first row of
            // slack sharp — and capping the far end — keeps the depth cue
            // without turning the panel into a smudge.
            final double distance =
                (((motion.y.value - activeY).abs() / slot) - 0.8).clamp(
                  0.0,
                  4.0,
                );
            final double sigma = _settings.blurEnabled
                ? (distance * 1.25 * _settings.blurIntensity).clamp(0.0, 3.5)
                : 0.0;
            return Transform.translate(
              offset: Offset(0, motion.y.value),
              child: ImageFiltered(
                enabled: sigma > .03,
                imageFilter: _blur(sigma),
                child: Opacity(
                  opacity: opacity,
                  child: RepaintBoundary(child: child!),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _interludeRow(
    int index,
    OverlayLineMotion motion,
    double slot,
    double inset,
    bool active,
  ) {
    return Positioned(
      key: ValueKey<int>(index),
      top: 0,
      left: inset,
      right: inset,
      height: slot,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _frames,
          child: LyricInterludeDots(
            line: _lines[index],
            position: () => Duration(milliseconds: _currentPositionMs.round()),
            repaint: _frames,
            diameter: _settings.fontSize * _theme.lyricFontScale * .3,
            presence: () =>
                ((motion.scale.value - (100 - _theme.lyricFocusScaleDelta)) /
                        _theme.lyricFocusScaleDelta)
                    .clamp(0.0, 1.0),
          ),
          builder: (BuildContext context, Widget? child) {
            return Transform.translate(
              offset: Offset(0, motion.y.value),
              child: child,
            );
          },
        ),
      ),
    );
  }

  Widget _desktopDragHandle(double height) {
    return Positioned(
      left: 0,
      top: (height - _dragHandleHeight) / 2,
      width: _dragHandleWidth,
      height: _dragHandleHeight,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        onEnter: (PointerEnterEvent event) {
          _setDragHovered(true);
        },
        onExit: (PointerExitEvent event) {
          _setDragHovered(false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (DragStartDetails details) {
            unawaited(_startDrag());
          },
          child: AnimatedOpacity(
            opacity: _dragHovered ? 1 : .45,
            duration: MotionTiming.scale(const Duration(milliseconds: 140)),
            child: Center(
              child: Container(
                width: 20,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: _dragHovered ? .18 : .06,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(bool desktop) {
    final payload = _payload;
    final String title = payload?.title ?? '';
    final String artist = payload?.artist ?? '';
    final String notice = payload?.notice ?? '';
    return Positioned.fill(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title.isEmpty ? 'Lazer' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: _textStyle(.82).copyWith(fontWeight: FontWeight.w600),
              ),
              if (artist.isNotEmpty)
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: _textStyle(
                    .62,
                  ).copyWith(color: Colors.white.withValues(alpha: .72)),
                ),
              if (notice.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  notice,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: _textStyle(
                    .58,
                  ).copyWith(color: Colors.white.withValues(alpha: .58)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
