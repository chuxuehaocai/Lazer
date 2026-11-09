import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../theme/apple_design.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/spring_buttons.dart';
import 'network_source.dart';
import 'network_sources_controller.dart';
import 'network_widgets.dart';
import 'remote_source.dart';

/// Add/edit sheet for one network source.
///
/// The dialog owns the draft because the password is not part of the model; the
/// caller gets `true` once the controller has persisted the result.
Future<bool> showNetworkSourceEditor(
  BuildContext context, {
  required NetworkSourcesController controller,
  NetworkSource? source,
}) async {
  final bool? saved = await showAppleDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _NetworkSourceEditor(controller: controller, source: source),
  );
  return saved == true;
}

class _NetworkSourceEditor extends StatefulWidget {
  const _NetworkSourceEditor({required this.controller, this.source});

  final NetworkSourcesController controller;
  final NetworkSource? source;

  @override
  State<_NetworkSourceEditor> createState() => _NetworkSourceEditorState();
}

class _NetworkSourceEditorState extends State<_NetworkSourceEditor>
    with BuildSafeState<_NetworkSourceEditor> {
  late final NetworkSourceDraft _draft = widget.source == null
      ? NetworkSourceDraft(kind: NetworkSourceKind.webdav, port: 80)
      : NetworkSourceDraft.fromSource(widget.source!);
  late final TextEditingController _name = TextEditingController(
    text: _draft.name,
  );
  late final TextEditingController _host = TextEditingController(
    text: _draft.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: _draft.effectivePort.toString(),
  );
  late final TextEditingController _path = TextEditingController(
    text: _draft.path,
  );
  late final TextEditingController _username = TextEditingController(
    text: _draft.username,
  );
  late final TextEditingController _password = TextEditingController();
  late final TextEditingController _domain = TextEditingController(
    text: _draft.domain,
  );

  bool _busy = false;
  bool _obscure = true;
  Object? _error;
  String? _success;

  bool get _editing => widget.source != null;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _username.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  NetworkSourceDraft _collect() {
    final NetworkSourceDraft draft = NetworkSourceDraft(
      kind: _draft.kind,
      name: _name.text,
      host: _host.text,
      port: int.tryParse(_port.text.trim()) ?? 0,
      secure: _draft.secure,
      path: _path.text.trim().isEmpty ? '/' : _path.text.trim(),
      username: _username.text,
      password: _password.text,
      domain: _domain.text,
      allowSelfSignedCertificate: _draft.allowSelfSignedCertificate,
    );
    return draft;
  }

  void _switchKind(NetworkSourceKind kind) {
    if (kind == _draft.kind) return;
    setState(() {
      final int previousDefault = _draft.secure
          ? networkSourceDefaultSecurePort(_draft.kind)
          : networkSourceDefaultPort(_draft.kind);
      final int current = int.tryParse(_port.text.trim()) ?? 0;
      _draft.kind = kind;
      _draft.secure = kind == NetworkSourceKind.webdav ? _draft.secure : false;
      if (current == 0 || current == previousDefault) {
        _draft.port = _draft.secure
            ? networkSourceDefaultSecurePort(kind)
            : networkSourceDefaultPort(kind);
        _port.text = _draft.port.toString();
      }
      if (_path.text.trim().isEmpty) {
        _path.text = '/';
      }
      _error = null;
      _success = null;
    });
  }

  Future<void> _test() async {
    if (_busy) return;
    final NetworkSourceDraft draft = _collect();
    final String? invalid = draft.invalidReason;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final RemoteListing listing = await widget.controller.testDraft(
        draft,
        existingId: widget.source?.id,
      );
      if (!mounted) return;
      setState(() {
        _success = listing.entries.isEmpty
            ? context.tr('连接成功，这个目录是空的。')
            : context.tr('连接成功，读到 ${listing.entries.length} 个条目。');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final NetworkSourceDraft draft = _collect();
    final String? invalid = draft.invalidReason;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.source == null) {
        await widget.controller.addSource(draft);
      } else {
        final NetworkSource? updated = await widget.controller.updateSource(
          widget.source!.id,
          draft,
          password: _password.text,
        );
        if (updated == null) {
          if (!mounted) return;
          setState(() => _error = '这个网络源已经不存在了。');
          return;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String trustedKeyLabel = context.tr('已信任的主机密钥');
    final bool webdav = _draft.kind == NetworkSourceKind.webdav;
    final bool smb = _draft.kind == NetworkSourceKind.smb;
    final bool sftp = _draft.kind == NetworkSourceKind.sftp;
    return AlertDialog(
      title: Text(context.tr(_editing ? '编辑网络源' : '添加网络源')),
      content: SizedBox(
        width: math.min(460, MediaQuery.sizeOf(context).width - 88),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.tr('协议'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: apple.secondaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final NetworkSourceKind kind in networkSourceKinds)
                    ChoiceChip(
                      key: ValueKey<String>('network-kind-${kind.name}'),
                      label: Text(networkSourceKindLabel(kind)),
                      selected: _draft.kind == kind,
                      onSelected: (bool selected) {
                        if (selected) _switchKind(kind);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
              NetworkField(
                label: '名称（可选）',
                hint: '例如 客厅 NAS',
                controller: _name,
                fieldKey: const ValueKey<String>('network-field-name'),
              ),
              NetworkField(
                label: '服务器地址',
                hint: 'nas.local 或 192.168.1.10',
                controller: _host,
                keyboardType: TextInputType.url,
                fieldKey: const ValueKey<String>('network-field-host'),
              ),
              if (smb)
                // smb_connect always dials 445, so the port field would be a
                // control that does nothing.
                NetworkField(
                  label: '共享与目录',
                  hint: 'Music 或 data/music',
                  controller: _path,
                  fieldKey: const ValueKey<String>('network-field-path'),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 2,
                      child: NetworkField(
                        label: '端口',
                        hint: '',
                        controller: _port,
                        keyboardType: TextInputType.number,
                        fieldKey: const ValueKey<String>('network-field-port'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: NetworkField(
                        label: '起始目录',
                        hint: '/',
                        controller: _path,
                        fieldKey: const ValueKey<String>('network-field-path'),
                      ),
                    ),
                  ],
                ),
              NetworkField(
                label: '用户名',
                hint: smb ? r'NAS\用户名 或留空' : '留空表示匿名',
                controller: _username,
                fieldKey: const ValueKey<String>('network-field-username'),
              ),
              NetworkField(
                label: '密码',
                hint: _editing ? '留空表示不修改' : '',
                controller: _password,
                obscure: _obscure,
                fieldKey: const ValueKey<String>('network-field-password'),
              ),
              Row(
                children: <Widget>[
                  SpringTextButton(
                    key: const ValueKey<String>('network-toggle-password'),
                    onPressed: () => setState(() => _obscure = !_obscure),
                    child: TrText(_obscure ? '显示密码' : '隐藏密码'),
                  ),
                ],
              ),
              if (smb)
                NetworkField(
                  label: '域（可选）',
                  hint: 'WORKGROUP',
                  controller: _domain,
                  fieldKey: const ValueKey<String>('network-field-domain'),
                ),
              if (webdav)
                _NetworkSwitch(
                  key: const ValueKey<String>('network-switch-secure'),
                  label: '使用 HTTPS',
                  value: _draft.secure,
                  onChanged: (bool value) => setState(() {
                    final int previous = _draft.secure
                        ? networkSourceDefaultSecurePort(_draft.kind)
                        : networkSourceDefaultPort(_draft.kind);
                    _draft.secure = value;
                    if ((int.tryParse(_port.text.trim()) ?? 0) == previous) {
                      _draft.port = value
                          ? networkSourceDefaultSecurePort(_draft.kind)
                          : networkSourceDefaultPort(_draft.kind);
                      _port.text = _draft.port.toString();
                    }
                  }),
                ),
              if (webdav && _draft.secure)
                _NetworkSwitch(
                  key: const ValueKey<String>('network-switch-self-signed'),
                  label: '允许自签名证书',
                  value: _draft.allowSelfSignedCertificate,
                  onChanged: (bool value) =>
                      setState(() => _draft.allowSelfSignedCertificate = value),
                ),
              if (sftp && widget.source?.hostKey != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              trustedKeyLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: apple.secondaryLabel,
                              ),
                            ),
                            Text(
                              widget.source!.hostKey!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: apple.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SpringTextButton(
                        key: const ValueKey<String>('network-clear-host-key'),
                        onPressed: () => setState(() {
                          _draft.clearHostKey = true;
                          _success = context.tr('已标记重新信任，保存后生效。');
                        }),
                        child: const TrText('重新信任'),
                      ),
                    ],
                  ),
                ),
              if (_success != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _success!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: apple.accent,
                    ),
                  ),
                ),
              NetworkErrorText(
                error: _error,
                padding: const EdgeInsets.only(top: 6),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      actions: <Widget>[
        SpringTextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const TrText('取消'),
        ),
        SpringTextButton(
          key: const ValueKey<String>('network-source-test'),
          onPressed: _busy ? null : _test,
          child: _busy ? const NetworkProgressLabel() : const TrText('测试连接'),
        ),
        SpringFilledButton(
          key: const ValueKey<String>('network-source-save'),
          onPressed: _busy ? null : _save,
          child: const TrText('保存'),
        ),
      ],
    );
  }
}

class _NetworkSwitch extends StatelessWidget {
  const _NetworkSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              context.tr(label),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppleSemanticColors.of(context).label,
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
