import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../updates/open_external.dart';

/// Builds the official beatmap search URL from the track's original metadata.
Uri? osuBeatmapSearchUri(Track? track) {
  if (track == null) return null;

  final String title = track.title.trim();
  final String artist = track.artist.trim();
  final bool hasArtist =
      artist.isNotEmpty && artist != '未知歌手' && artist != '未知艺术家';
  final String query = <String>[
    if (hasArtist) artist,
    if (title.isNotEmpty) title,
  ].join(' ');
  if (query.isEmpty) return null;

  return Uri.https('osu.ppy.sh', '/beatmapsets', <String, String>{'q': query});
}

/// Opens the search in the system browser, with a copyable link as a fallback.
Future<void> searchInOsu(BuildContext context, Track? track) async {
  final Uri? uri = osuBeatmapSearchUri(track);
  if (uri == null) return;

  final String url = uri.toString();
  final bool opened = await openExternalUrl(url);
  if (opened || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const TrText('无法打开浏览器'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const TrText('请复制链接并在浏览器中打开。'),
          const SizedBox(height: 12),
          SelectableText(url),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const TrText('关闭'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (!dialogContext.mounted) return;
            Navigator.of(dialogContext).pop();
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(const SnackBar(content: TrText('链接已复制')));
          },
          child: const TrText('复制'),
        ),
      ],
    ),
  );
}
