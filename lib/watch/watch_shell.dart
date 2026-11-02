import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../local/local_music_import.dart';
import '../local/local_music_page.dart' show runLocalImport;
import '../state/app_state.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/plate_art.dart';
import 'watch_shape_list.dart';

/// A dedicated, low-motion surface for ordinary Android watches.
/// Playback, accounts and storage continue to use the normal Android APIs.
class WatchShell extends StatefulWidget {
  const WatchShell({super.key, required this.state, required this.round});
  final AppState state;
  final bool round;

  @override
  State<WatchShell> createState() => _WatchShellState();
}

class _WatchShellState extends State<WatchShell> {
  int _tab = 0;
  List<Track>? _openedTracks;
  String _title = '';
  bool _titleIsData = false;
  final TextEditingController _query = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _captcha = TextEditingController();
  Timer? _smsTimer;
  int _smsSeconds = 0;
  String? _accountMessage;
  bool _loading = false;
  String? _error;
  int _request = 0;
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(state.localLibrary.load());
  }

  @override
  void dispose() {
    _request++;
    _query.dispose();
    _phone.dispose();
    _captcha.dispose();
    _smsTimer?.cancel();
    super.dispose();
  }

  void _navigate(int tab) => setState(() {
    _request++;
    _loading = false;
    _tab = tab;
    _openedTracks = null;
    _error = null;
  });

  void _back() {
    if (_openedTracks != null) {
      setState(() {
        _request++;
        _loading = false;
        _openedTracks = null;
      });
    } else {
      _navigate(0);
    }
  }

  void _openWatchTracks(
    String title,
    List<Track> tracks, {
    bool fromRequest = false,
    bool titleIsData = false,
  }) => setState(() {
    if (!fromRequest) {
      _request++;
      _loading = false;
      _error = null;
    }
    _openedTracks = tracks;
    _title = title;
    _titleIsData = titleIsData;
  });

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    final request = ++_request;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await state.search(query.trim());
      if (!mounted || request != _request) return;
      _openWatchTracks('搜索结果', result.tracks, fromRequest: true);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '搜索失败，请重试'); // i18n:key
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tracks = await state.catalog.playlistTracks(playlist.id);
      if (!mounted || request != _request) return;
      _openWatchTracks(
        playlist.name,
        tracks,
        fromRequest: true,
        titleIsData: true,
      );
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '歌单加载失败，请重试'); // i18n:key
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _sendCode() async {
    if (_loading || _smsSeconds > 0) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _accountMessage = null;
    });
    final result = await state.sendSmsCode(_phone.text.trim());
    if (!mounted || request != _request) return;
    setState(() {
      _loading = false;
      _accountMessage = result.ok ? '验证码已发送' : result.error; // i18n:key
      if (result.ok) _smsSeconds = 60;
    });
    if (result.ok) {
      _smsTimer?.cancel();
      _smsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _smsSeconds <= 1) timer.cancel();
        if (mounted) setState(() => _smsSeconds = math.max(0, _smsSeconds - 1));
      });
    }
  }

  Future<void> _signIn() async {
    if (_loading) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _accountMessage = null;
    });
    final result = await state.signInWithPhoneCaptcha(
      _phone.text.trim(),
      _captcha.text.trim(),
    );
    if (!mounted || request != _request) return;
    setState(() {
      _loading = false;
      _accountMessage = result.ok ? '登录成功' : result.error; // i18n:key
      if (result.ok) _captcha.clear();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([state, state.localLibrary]),
    builder: (context, _) => PopScope(
      canPop: _openedTracks == null && _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final size = Size(box.maxWidth, box.maxHeight);
              final content = _content(size);
              return widget.round
                  ? ClipOval(
                      key: const ValueKey('watch-round-display'),
                      child: content,
                    )
                  : content;
            },
          ),
        ),
      ),
    ),
  );

  Widget _content(Size size) {
    if (_openedTracks case final tracks?) {
      final showLyric = _title == '歌词与状态' && state.lyrics.isNotEmpty;
      return _watchPage(
        size,
        _title,
        tracks.length + (showLyric ? 1 : 0),
        (context, index) {
          if (showLyric && index == 0) {
            return ListenableBuilder(
              listenable: state.ticks,
              builder: (context, _) {
                final line = state.currentLyricLine;
                return line == null
                    ? _watchMessage('音乐正在继续')
                    : _watchMessage(line.text, isData: true);
              },
            );
          }
          final trackIndex = index - (showLyric ? 1 : 0);
          final track = tracks[trackIndex];
          return _watchEntry(
            track.title,
            () {
              state.playQueue(tracks, startIndex: trackIndex);
              _navigate(0);
            },
            subtitle: track.artist,
            titleIsData: true,
            subtitleIsData: true,
            icon: state.current?.id == track.id
                ? Icons.equalizer_rounded
                : Icons.music_note_rounded,
            selected: state.current?.id == track.id,
            key: ValueKey('watch-track-${track.id}'),
          );
        },
        empty: '暂无歌曲',
        titleIsData: _titleIsData,
      );
    }
    if (_tab == 1) return _library(size);
    if (_tab == 2) return _searchPage(size);
    if (_tab == 3) return _settings(size);
    if (state.current == null) {
      return _watchPage(
        size,
        'Lazer',
        2,
        (context, index) => index == 0
            ? _watchEntry(
                '选择音乐',
                () => _navigate(1),
                subtitle: '从曲库开始播放',
                icon: Icons.library_music_rounded,
              )
            : _watchEntry(
                '设置',
                () => _navigate(3),
                subtitle: '账号与音量',
                icon: Icons.tune_rounded,
              ),
      );
    }
    if (MediaQuery.textScalerOf(context).scale(14) > 18) {
      return _largeTextPlayer(size);
    }
    return widget.round ? _roundPlayer(size) : _squarePlayer(size);
  }

  Widget _watchPage(
    Size size,
    String title,
    int count,
    IndexedWidgetBuilder builder, {
    String? empty,
    bool titleIsData = false,
  }) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final top = keyboard > 0
        ? math.min(
            widget.round ? 16.0 : 4.0,
            math.max(0.0, size.height - keyboard),
          )
        : (widget.round ? size.height * .31 : 44.0);
    final headerTop = widget.round ? size.height * .115 : 4.0;
    final headerWidth = widget.round
        ? WatchDisplayGeometry(size).widthForBand(headerTop, headerTop + 32)
        : size.width - 16;
    final status =
        _error ??
        (_title == '歌词与状态' && _openedTracks != null
            ? state.playbackError
            : null) ??
        (_loading ? '正在加载…' : null); // i18n:key
    final extra = status == null ? 0 : 1;
    final emptyCount = count == 0 && empty != null ? 1 : 0;
    return Stack(
      key: ValueKey(
        'watch-page-$_tab-${_openedTracks == null ? 'root' : _title}',
      ),
      children: [
        if (keyboard == 0)
          Positioned(
            top: headerTop,
            left: (size.width - headerWidth) / 2,
            width: headerWidth,
            height: 32,
            child: Row(
              children: [
                _watchButton('返回', Icons.arrow_back_rounded, _back, side: 32),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    titleIsData ? title : context.tr(title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Positioned.fill(
          top: top,
          bottom: keyboard.clamp(0.0, math.max(0.0, size.height - top)),
          child: WatchShapeList(
            key: ValueKey(
              'watch-list-$_tab-${_openedTracks == null ? 'root' : _title}',
            ),
            round: widget.round,
            displaySize: size,
            top: top,
            storageKey:
                'watch-$_tab-${_openedTracks == null ? 'root' : _title}',
            itemExtent: math.max(
              56,
              MediaQuery.textScalerOf(context).scale(42),
            ),
            itemCount: count + extra + emptyCount,
            itemBuilder: (context, index) {
              if (index < extra) return _watchMessage(status!);
              if (emptyCount != 0) return _watchMessage(empty!);
              return builder(context, index - extra);
            },
          ),
        ),
      ],
    );
  }

  Widget _artwork(Track track, double side) => RepaintBoundary(
    child: Tooltip(
      message: context.tr('播放队列'),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(widget.round ? side / 2 : 12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openWatchTracks('播放队列', state.queue),
          child: Semantics(
            button: true,
            label: context.tr('播放队列'),
            child: SizedBox.square(
              dimension: side,
              child: PlateArt(
                seed: track.coverSeed,
                coverUrl: track.coverUrl,
                size: side,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _roundPlayer(Size size) {
    final track = state.current!;
    final edge = math.min(size.width, size.height);
    final navSide = math.min(40.0, edge * .18);
    final artSide = edge * .27;
    Widget at(double x, double y, double side, Widget child) => Positioned(
      left: x - side / 2,
      top: y - side / 2,
      width: side,
      height: side,
      child: child,
    );
    Widget band(double top, double height, Widget child) {
      final width = WatchDisplayGeometry(size).widthForBand(top, top + height);
      return Positioned(
        left: (size.width - width) / 2,
        top: top,
        width: width,
        height: height,
        child: child,
      );
    }

    return Stack(
      key: const ValueKey('watch-player'),
      children: [
        at(
          size.width * .25,
          size.height * .26,
          navSide,
          _watchButton(
            '音乐',
            Icons.library_music_outlined,
            () => _navigate(1),
            side: navSide,
          ),
        ),
        at(
          size.width * .75,
          size.height * .26,
          navSide,
          _watchButton(
            '设置',
            Icons.tune_rounded,
            () => _navigate(3),
            side: navSide,
          ),
        ),
        at(
          size.width / 2,
          size.height * .24,
          artSide,
          _artwork(track, artSide),
        ),
        band(
          size.height * .405,
          size.height * .12,
          _trackText(track.title, title: true, centered: true),
        ),
        band(
          size.height * .535,
          size.height * .085,
          _trackText(
            state.playbackError == null
                ? track.artist
                : context.tr('播放异常 · 点击歌名'),
            centered: true,
          ),
        ),
        band(
          size.height * .60,
          size.height * .10,
          _WatchProgress(state: state, compact: true),
        ),
        at(
          size.width * .28,
          size.height * .78,
          edge * .17,
          _watchButton(
            '上一首',
            Icons.skip_previous_rounded,
            state.previous,
            side: edge * .17,
          ),
        ),
        at(
          size.width / 2,
          size.height * .825,
          edge * .255,
          _playButton(edge * .255),
        ),
        at(
          size.width * .72,
          size.height * .78,
          edge * .17,
          _watchButton(
            '下一首',
            Icons.skip_next_rounded,
            state.next,
            side: edge * .17,
          ),
        ),
      ],
    );
  }

  Widget _squarePlayer(Size size) {
    final track = state.current!;
    final edge = math.min(size.width, size.height);
    final artSide = math.min(edge * .32, size.height * .32);
    final controlSide = math.min(60.0, edge * .27);
    return Padding(
      key: const ValueKey('watch-player'),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Stack(
        children: [
          Positioned(
            top: 2,
            left: 0,
            right: 0,
            height: 34,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('正在播放'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: edge < 180 ? 10 : 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _watchButton(
                  '音乐',
                  Icons.library_music_outlined,
                  () => _navigate(1),
                  side: 30,
                ),
                _watchButton(
                  '搜索',
                  Icons.search_rounded,
                  () => _navigate(2),
                  side: 30,
                ),
                _watchButton(
                  '设置',
                  Icons.tune_rounded,
                  () => _navigate(3),
                  side: 30,
                ),
              ],
            ),
          ),
          Positioned(
            top: size.height * .24,
            left: 0,
            right: 0,
            height: artSide,
            child: Row(
              children: [
                SizedBox.square(
                  dimension: artSide,
                  child: _artwork(track, artSide),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _trackText(track.title, title: true, lines: 2),
                      const SizedBox(height: 3),
                      _trackText(
                        state.playbackError == null
                            ? track.artist
                            : context.tr('播放异常 · 点击歌名'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: size.height * .55,
            left: 0,
            right: 0,
            height: 20,
            child: _WatchProgress(state: state),
          ),
          Positioned(
            bottom: size.height * .035,
            left: 8,
            right: 8,
            height: controlSide,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _watchButton(
                  '上一首',
                  Icons.skip_previous_rounded,
                  state.previous,
                  side: controlSide * .8,
                ),
                _playButton(controlSide),
                _watchButton(
                  '下一首',
                  Icons.skip_next_rounded,
                  state.next,
                  side: controlSide * .8,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _largeTextPlayer(Size size) {
    final track = state.current!;
    return _watchPage(
      size,
      '正在播放',
      6,
      (context, index) => switch (index) {
        0 => Center(child: _artwork(track, 46)),
        1 => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _trackText(track.title, title: true),
            _trackText(track.artist),
          ],
        ),
        2 => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _watchButton(
              '上一首',
              Icons.skip_previous_rounded,
              state.previous,
              side: 32,
            ),
            _playButton(42),
            _watchButton('下一首', Icons.skip_next_rounded, state.next, side: 32),
          ],
        ),
        3 => _WatchProgress(state: state),
        4 => _watchEntry(
          '音乐',
          () => _navigate(1),
          icon: Icons.library_music_outlined,
        ),
        _ => _watchEntry('设置', () => _navigate(3), icon: Icons.tune_rounded),
      },
    );
  }

  Widget _playButton(double side) => _watchButton(
    state.playing ? '暂停' : '播放',
    state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
    state.togglePlay,
    side: side,
    prominent: true,
  );

  Widget _trackText(
    String text, {
    bool title = false,
    bool centered = false,
    int lines = 1,
  }) {
    final child = Text(
      text,
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
      textAlign: centered ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        fontSize: title ? 15 : 11,
        height: 1.15,
        fontWeight: title ? FontWeight.w700 : FontWeight.w400,
        color: title ? null : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return !title
        ? child
        : Tooltip(
            message: context.tr('歌词与状态'),
            child: Semantics(
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openWatchTracks('歌词与状态', state.queue),
                child: child,
              ),
            ),
          );
  }

  Widget _watchButton(
    String label,
    IconData icon,
    VoidCallback onPressed, {
    required double side,
    bool prominent = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: side,
      child: IconButton(
        tooltip: context.tr(label),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: side, height: side),
        style: IconButton.styleFrom(
          minimumSize: Size.square(side),
          maximumSize: Size.square(side),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: prominent
              ? scheme.primary
              : scheme.surfaceContainerHighest,
          foregroundColor: prominent ? scheme.onPrimary : scheme.onSurface,
          shape: const CircleBorder(),
        ),
        iconSize: prominent ? side * .58 : math.min(23, side * .6),
        icon: Icon(icon),
      ),
    );
  }

  Widget _library(Size size) {
    final local = state.localLibrary.tracks
        .where((entry) => !entry.missing)
        .map((entry) => entry.track)
        .toList();
    final feed = state.home;
    final playlists = [
      if (feed != null) ...feed.recommended,
      ...state.collections.created,
      ...state.collections.subscribed,
    ];
    final basic = <(String, String, IconData, VoidCallback)>[
      ('搜索音乐', '歌曲 / 歌手', Icons.search_rounded, () => _navigate(2)), // i18n:key
      (
        '本地音乐 · ${local.length}', // i18n:key
        '下载与缓存', // i18n:key
        Icons.offline_pin_outlined,
        () => _openWatchTracks('本地音乐', local),
      ),
      (
        '最近播放', // i18n:key
        '再听一遍', // i18n:key
        Icons.history_rounded,
        () => _openWatchTracks('最近播放', state.recentTracks),
      ),
      if (feed != null)
        (
          '每日推荐', // i18n:key
          '${feed.daily.length} 首歌曲', // i18n:key
          Icons.auto_awesome_outlined,
          () => _openWatchTracks('每日推荐', feed.daily),
        ),
    ];
    return _watchPage(size, '音乐', basic.length + playlists.length, (
      context,
      index,
    ) {
      if (index < basic.length) {
        final (title, subtitle, icon, action) = basic[index];
        return _watchEntry(title, action, subtitle: subtitle, icon: icon);
      }
      final playlist = playlists[index - basic.length];
      return _watchEntry(
        playlist.name,
        () => _openPlaylist(playlist),
        subtitle: '${playlist.trackCount} 首歌曲',
        titleIsData: true,
        icon: Icons.queue_music_rounded,
      );
    });
  }

  Widget _searchPage(Size size) => _watchPage(
    size,
    '搜索',
    2,
    (context, index) => index == 0
        ? _watchInput(
            _query,
            hint: '歌曲 / 歌手',
            action: TextInputAction.search,
            onSubmitted: _search,
            key: const ValueKey('watch-search-query'),
          )
        : _watchEntry(
            '搜索',
            () => _search(_query.text),
            subtitle: '在音乐库中查找',
            icon: Icons.search_rounded,
          ),
  );

  Widget _settings(Size size) {
    final rows = <Widget Function()>[
      if (!state.signedIn) ...[
        () => _watchInput(
          _phone,
          hint: '手机号',
          type: TextInputType.phone,
          key: const ValueKey('watch-login-phone'),
        ),
        () => _watchEntry(
          _smsSeconds > 0 ? '$_smsSeconds 秒后重试' : '发送验证码',
          _sendCode,
          icon: Icons.sms_outlined,
          enabled: !_loading && _smsSeconds == 0,
        ),
        () => _watchInput(
          _captcha,
          hint: '验证码',
          type: TextInputType.number,
          action: TextInputAction.done,
          onSubmitted: (_) => _signIn(),
          key: const ValueKey('watch-login-captcha'),
        ),
        () => _watchEntry(
          '登录',
          _signIn,
          icon: Icons.login_rounded,
          enabled: !_loading,
        ),
      ] else ...[
        () => _watchMessage(state.user.name, isData: true),
        () => _watchEntry(
          '退出登录',
          () => unawaited(state.signOut()),
          icon: Icons.logout_rounded,
        ),
      ],
      if (_accountMessage != null) () => _watchMessage(_accountMessage!),
      () => _watchEntry(
        '导入本地歌曲',
        () => unawaited(
          runLocalImport(context, state, const LocalMusicImporter()),
        ),
        icon: Icons.download_rounded,
      ),
      () => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const TrText('音量', style: TextStyle(fontSize: 11)),
          SizedBox(
            height: 28,
            child: _sliderTheme(
              AccessibleSlider(
                semanticLabel: '音量',
                value: state.volume,
                onChanged: (value) => unawaited(state.setVolume(value)),
              ),
            ),
          ),
        ],
      ),
      () => _watchEntry(
        state.themeMode == ThemeMode.dark ? '浅色外观' : '深色外观',
        () => unawaited(
          state.setThemeMode(
            state.themeMode == ThemeMode.dark
                ? ThemeMode.light
                : ThemeMode.dark,
          ),
        ),
        icon: Icons.contrast_rounded,
      ),
      () => _watchMessage('手表默认使用静态背景'),
    ];
    return _watchPage(
      size,
      state.signedIn ? '设置' : '账号与设置',
      rows.length,
      (context, index) => rows[index](),
    );
  }

  Widget _watchInput(
    TextEditingController controller, {
    required String hint,
    TextInputType? type,
    TextInputAction? action,
    ValueChanged<String>? onSubmitted,
    Key? key,
  }) => TextField(
    key: key,
    controller: controller,
    keyboardType: type,
    textInputAction: action,
    onSubmitted: onSubmitted,
    style: const TextStyle(fontSize: 13),
    scrollPadding: const EdgeInsets.all(28),
    decoration: InputDecoration(
      hintText: context.tr(hint),
      labelText: context.tr(hint),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );

  Widget _watchMessage(String text, {bool isData = false}) => Center(
    child: Text(
      isData ? text : context.tr(text),
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12),
    ),
  );

  Widget _watchEntry(
    String title,
    VoidCallback onTap, {
    String? subtitle,
    IconData icon = Icons.chevron_right_rounded,
    bool selected = false,
    bool enabled = true,
    bool titleIsData = false,
    bool subtitleIsData = false,
    Key? key,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: key,
      color: selected ? scheme.primaryContainer : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: enabled ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      titleIsData ? title : context.tr(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitleIsData ? subtitle : context.tr(subtitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sliderTheme(Widget child) => SliderTheme(
    data: SliderTheme.of(context).copyWith(
      trackHeight: 2,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
      trackShape: const RectangularSliderTrackShape(),
    ),
    child: child,
  );
}

/// Progress alone follows the 10 Hz transport lane. Artwork, navigation and
/// long libraries never rebuild because the playhead advanced.
class _WatchProgress extends StatefulWidget {
  const _WatchProgress({required this.state, this.compact = false});
  final AppState state;
  final bool compact;

  @override
  State<_WatchProgress> createState() => _WatchProgressState();
}

class _WatchProgressState extends State<_WatchProgress> {
  double? _scrubbing;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state.ticks,
    builder: (context, _) => SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 3),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 7),
        trackShape: const RectangularSliderTrackShape(),
      ),
      child: AccessibleSlider(
        semanticLabel: '播放进度',
        value: (_scrubbing ?? widget.state.progress).clamp(0, 1),
        semanticFormatterCallback: (value) {
          final seconds =
              ((widget.state.current?.duration.inSeconds ?? 0) * value).round();
          return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
        },
        onChangeStart: (value) => setState(() => _scrubbing = value),
        onChanged: (value) => setState(() => _scrubbing = value),
        onChangeEnd: (value) {
          widget.state.seek(value);
          setState(() => _scrubbing = null);
        },
      ),
    ),
  );
}
