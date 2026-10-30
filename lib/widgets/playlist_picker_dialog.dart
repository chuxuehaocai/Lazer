import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../legacy/legacy_login.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import 'artwork_image.dart';

/// The official client's "收藏到歌单" flow: pick one of the account's cloud
/// playlists, or create a new one on the spot and add [track] to it.
///
/// The playlist lives on the service, so the same list shows up on every
/// device after [AppState.refreshCollections] runs.
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  AppState state, {
  required Track track,
}) async {
  final Brightness brightness = Theme.of(context).brightness;
  final Color accent = state.legacyAccentSeed ?? AppleColors.musicRed;
  final Object? result = await showDialog<Object>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (BuildContext context) => Theme(
      data: buildAppleTheme(
        brightness: brightness,
        seedAccent: accent,
        fonts: state.fontPreferences,
      ),
      child: _AddToPlaylistDialog(state: state, track: track),
    ),
  );
  if (!context.mounted) return;
  _showResult(context, result);
}

/// Standalone "新建歌单" from 资料库: creates the playlist on the account
/// without requiring a song to add first.
Future<void> showCreateCloudPlaylistDialog(
  BuildContext context,
  AppState state,
) async {
  final Brightness brightness = Theme.of(context).brightness;
  final Color accent = state.legacyAccentSeed ?? AppleColors.musicRed;
  final Object? result = await showDialog<Object>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (BuildContext context) => Theme(
      data: buildAppleTheme(
        brightness: brightness,
        seedAccent: accent,
        fonts: state.fontPreferences,
      ),
      child: _AddToPlaylistDialog(state: state),
    ),
  );
  if (!context.mounted) return;
  _showResult(context, result);
}

void _showResult(BuildContext context, Object? result) {
  if (result == null || !context.mounted) return;
  final String message = switch (result) {
    final Playlist playlist => '已创建「${playlist.name}」',
    final String text => text,
    _ => '',
  };
  if (message.isEmpty) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(context.tr(message)),
    ),
  );
}

class _AddToPlaylistDialog extends StatefulWidget {
  const _AddToPlaylistDialog({required this.state, this.track});

  final AppState state;

  /// `null` creates a playlist without adding anything to it.
  final Track? track;

  @override
  State<_AddToPlaylistDialog> createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<_AddToPlaylistDialog> {
  final TextEditingController _name = TextEditingController();
  bool _creating = false;
  bool _private = false;
  bool _busy = false;
  bool _loading = false;
  String? _error;
  String? _busyPlaylistId;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _creating = widget.track == null;
    if (state.signedIn && widget.track != null) {
      unawaited(_loadCollections());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadCollections() async {
    if (state.collections.created.isNotEmpty ||
        state.collections.liked != null) {
      return;
    }
    setState(() => _loading = true);
    try {
      await state.refreshCollections();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addTo(Playlist playlist) async {
    final Track? track = widget.track;
    if (_busy || track == null) return;
    setState(() {
      _busy = true;
      _busyPlaylistId = playlist.id;
      _error = null;
    });
    try {
      await state.addSongToCloudPlaylist(playlist.id, track.id);
      if (!mounted) return;
      Navigator.of(context).pop('已添加到「${playlist.name}」');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyPlaylistId = null;
        _error = '添加失败，请稍后重试。';
      });
    }
  }

  Future<void> _createAndAdd() async {
    if (_busy) return;
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入歌单名称');
      return;
    }
    if (name.characters.length > 40) {
      setState(() => _error = '歌单名称不能超过 40 个字符');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Playlist? created = await state.createCloudPlaylist(
        name,
        privacy: _private,
      );
      if (created == null) throw StateError('playlist not created');
      final Track? track = widget.track;
      if (track != null) {
        await state.addSongToCloudPlaylist(created.id, track.id);
      }
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(track == null ? created : '已创建并添加到「${created.name}」');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '创建失败，请稍后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!state.signedIn) return _guest(context);
    if (widget.track == null) return _createView(context);
    return _creating ? _createView(context) : _pickView(context);
  }

  Widget _guest(BuildContext context) => AlertDialog(
    title: const TrText('添加到歌单'),
    content: Text(
      context.tr('登录后可以把歌曲添加到云端歌单。'),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: AppleSemanticColors.of(context).secondaryLabel,
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const TrText('取消'),
      ),
      FilledButton(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(showLegacyLoginDialog(context, state));
        },
        child: const TrText('登录'),
      ),
    ],
  );

  Widget _pickView(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final List<Playlist> targets = <Playlist>[
      if (state.collections.liked != null) state.collections.liked!,
      ...state.collections.created,
    ];
    return AlertDialog(
      title: const TrText('添加到歌单'),
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _CreateTile(
              onTap: _busy ? null : () => setState(() => _creating = true),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (targets.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                child: Text(
                  context.tr('还没有创建的歌单，先新建一个吧。'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: targets.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Playlist playlist = targets[index];
                    return _PlaylistTile(
                      playlist: playlist,
                      busy: _busyPlaylistId == playlist.id,
                      enabled: !_busy,
                      onTap: () => unawaited(_addTo(playlist)),
                    );
                  },
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(
                  context.tr(_error!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const TrText('取消'),
        ),
      ],
    );
  }

  Widget _createView(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AlertDialog(
      title: const TrText('创建歌单'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_busy,
                maxLength: 40,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_createAndAdd()),
                decoration: InputDecoration(
                  labelText: context.tr('歌单名称'),
                  hintText: context.tr('例如：夜间散步'),
                  counterStyle: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: apple.tertiaryLabel),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr('谁可以看到这个歌单'),
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: apple.secondaryLabel),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    label: Text(context.tr('公开·所有人可见')),
                    icon: const Icon(Icons.public_rounded, size: 17),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text(context.tr('仅自己可见')),
                    icon: const Icon(Icons.lock_outline_rounded, size: 17),
                  ),
                ],
                selected: <bool>{_private},
                onSelectionChanged: _busy
                    ? null
                    : (Set<bool> value) =>
                          setState(() => _private = value.first),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  context.tr(_error!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  if (widget.track == null) {
                    Navigator.of(context).pop();
                  } else {
                    setState(() {
                      _creating = false;
                      _error = null;
                    });
                  }
                },
          child: const TrText('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_createAndAdd()),
          child: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const TrText('创建'),
        ),
      ],
    );
  }
}

class _CreateTile extends StatelessWidget {
  const _CreateTile({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: apple.tertiaryFill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.add_rounded, color: apple.label),
      ),
      title: const TrText('新建歌单'),
      subtitle: Text(
        context.tr('上传到云端，多设备同步'),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final Playlist playlist;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return ListTile(
      onTap: enabled ? onTap : null,
      leading: SizedBox.square(
        dimension: 40,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _PlaylistCover(url: playlist.coverUrl),
        ),
      ),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        context.tr('${playlist.trackCount} 首'),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
      ),
      trailing: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    );
  }
}

class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Widget fallback = ColoredBox(
      color: apple.tertiaryFill,
      child: Icon(
        Icons.queue_music_rounded,
        size: 19,
        color: apple.tertiaryLabel,
      ),
    );
    final String? resolved = url?.trim();
    if (resolved == null || resolved.isEmpty) return fallback;
    return Image(
      image: ArtworkImage(resolved),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (BuildContext context, Object? error, StackTrace? _) =>
          fallback,
    );
  }
}
