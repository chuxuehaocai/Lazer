import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import 'legacy_widgets.dart';

/// Shared card sizing for the library and search result grids.
class LegacyPlaylistGridLayout {
  LegacyPlaylistGridLayout(double width)
    : columns = switch (width) {
        >= 1100 => 6,
        >= 860 => 5,
        >= 660 => 4,
        >= 430 => 3,
        >= 242 => 2,
        _ => 1,
      },
      width = width;

  final int columns;
  final double width;
  static const double gap = 18;
  double get cell => columns == 1
      ? width.clamp(0.0, 180.0)
      : ((width - gap * (columns - 1)) / columns).clamp(112.0, 180.0);
}

/// Lazily mounts a row at a time while retaining natural card heights.
class LegacyPlaylistRowsSliver extends StatelessWidget {
  const LegacyPlaylistRowsSliver({
    super.key,
    required this.playlists,
    required this.layout,
    required this.onOpen,
  });
  final List<Playlist> playlists;
  final LegacyPlaylistGridLayout layout;
  final ValueChanged<Playlist> onOpen;

  @override
  Widget build(BuildContext context) {
    final int count = (playlists.length + layout.columns - 1) ~/ layout.columns;
    return SliverList.builder(
      itemCount: count,
      itemBuilder: (context, row) {
        final int start = row * layout.columns;
        final int end = math.min(start + layout.columns, playlists.length);
        return Padding(
          padding: EdgeInsets.only(bottom: row == count - 1 ? 0 : 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = start; i < end; i++) ...[
                if (i > start)
                  const SizedBox(width: LegacyPlaylistGridLayout.gap),
                LegacyPlaylistCard(
                  playlist: playlists[i],
                  width: layout.cell,
                  onTap: () => onOpen(playlists[i]),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A box-grid variant for non-scrolling hosts.
class LegacyPlaylistGrid extends StatelessWidget {
  const LegacyPlaylistGrid({
    super.key,
    required this.playlists,
    required this.onOpen,
  });
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = LegacyPlaylistGridLayout(constraints.maxWidth);
      return Wrap(
        spacing: LegacyPlaylistGridLayout.gap,
        runSpacing: 24,
        children: [
          for (final playlist in playlists)
            LegacyPlaylistCard(
              playlist: playlist,
              width: layout.cell,
              onTap: () => onOpen(playlist),
            ),
        ],
      );
    },
  );
}
