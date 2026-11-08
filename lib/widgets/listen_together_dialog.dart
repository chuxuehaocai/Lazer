import 'spring_buttons.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/listen_together.dart';

/// Opens the 一起听 room sheet from any platform's player header or settings.
Future<void> showListenTogetherDialog(BuildContext context, AppState state) =>
    showAppleDialog<void>(
      context: context,
      builder: (BuildContext context) => _ListenTogetherDialog(state: state),
    );

class _ListenTogetherDialog extends StatefulWidget {
  const _ListenTogetherDialog({required this.state});

  final AppState state;

  @override
  State<_ListenTogetherDialog> createState() => _ListenTogetherDialogState();
}

class _ListenTogetherDialogState extends State<_ListenTogetherDialog> {
  static const double _radius = 24;

  final TextEditingController _invite = TextEditingController();

  @override
  void dispose() {
    _invite.dispose();
    super.dispose();
  }

  Future<void> _copyInvite(ListenTogetherController room) async {
    final String invite = '${room.roomId}|${room.inviterId ?? 0}';
    await Clipboard.setData(ClipboardData(text: invite));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr('邀请信息已复制'))));
  }

  @override
  Widget build(BuildContext context) {
    final ListenTogetherController room = widget.state.listenTogether;
    return Dialog(
      elevation: 28,
      shadowColor: Colors.black.withValues(alpha: .55),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AnimatedBuilder(
          animation: room,
          builder: (BuildContext context, Widget? _) {
            final bool signedIn = widget.state.signedIn;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.group_rounded, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          context.tr('一起听'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: context.tr('关闭'),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr('和朋友同步听歌，一起发现好音乐。'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 18),
                  if (!signedIn)
                    Text(
                      context.tr('登录后可以和朋友一起听歌'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    )
                  else if (room.ready)
                    ..._roomBody(context, room)
                  else
                    ..._joinBody(context, room),
                  if (room.error != null) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      context.tr(room.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _roomBody(
    BuildContext context,
    ListenTogetherController room,
  ) => <Widget>[
    Text(
      context.tr('正在一起听'),
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 10),
    SelectableText(
      context.tr('房间号：${room.roomId}'),
      style: Theme.of(context).textTheme.bodyLarge,
    ),
    const SizedBox(height: 6),
    Text(
      context.tr('邀请人：${room.inviterId ?? ''}'),
      style: Theme.of(context).textTheme.bodyMedium,
    ),
    if (room.members.isNotEmpty) ...<Widget>[
      const SizedBox(height: 16),
      Text(
        context.tr('一起听的人'),
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      for (final ListenTogetherMember member in room.members)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: <Widget>[
              const Icon(Icons.person_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  member.name.isEmpty ? member.userId : member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ],
    const SizedBox(height: 18),
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        SpringFilledButton.icon(
          onPressed: room.loading ? null : () => unawaited(_copyInvite(room)),
          icon: const Icon(Icons.copy_rounded),
          label: Text(context.tr('复制邀请')),
        ),
        SpringOutlinedButton(
          onPressed: room.loading
              ? null
              : () async {
                  await room.leave();
                  if (context.mounted) Navigator.of(context).pop();
                },
          child: Text(context.tr('结束一起听')),
        ),
      ],
    ),
  ];

  List<Widget> _joinBody(BuildContext context, ListenTogetherController room) =>
      <Widget>[
        SizedBox(
          width: double.infinity,
          child: SpringFilledButton.icon(
            onPressed: room.loading
                ? null
                : () async {
                    final bool created = await room.create();
                    if (created && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.tr('一起听房间已创建'))),
                      );
                    }
                  },
            icon: const Icon(Icons.add_rounded),
            label: Text(context.tr('创建一起听')),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.tr('或加入朋友的房间'),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _invite,
          decoration: InputDecoration(
            labelText: context.tr('邀请码或邀请链接'),
            hintText: context.tr('例如 123456|7890'),
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(_radius)),
            ),
            isDense: true,
          ),
          onSubmitted: (_) => _join(room),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: SpringOutlinedButton.icon(
            onPressed: room.loading ? null : () => _join(room),
            icon: const Icon(Icons.login_rounded),
            label: Text(context.tr('加入一起听')),
          ),
        ),
        if (room.loading) ...<Widget>[
          const SizedBox(height: 16),
          const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ],
      ];

  Future<void> _join(ListenTogetherController room) async {
    final bool joined = await room.join(_invite.text);
    if (joined && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('已加入一起听'))));
    }
  }
}
