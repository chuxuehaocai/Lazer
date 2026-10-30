import 'package:flutter/material.dart';

import '../gateway/navidrome_gateway.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';

class NavidromeLoginFields extends StatefulWidget {
  const NavidromeLoginFields({
    super.key,
    required this.state,
    required this.onConnected,
    required this.onBusy,
  });
  final AppState state;
  final VoidCallback onConnected;
  final ValueChanged<bool> onBusy;
  @override
  State<NavidromeLoginFields> createState() => _NavidromeLoginFieldsState();
}

class _NavidromeLoginFieldsState extends State<NavidromeLoginFields> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final saved = widget.state.musicConnections.whereType<NavidromeGateway>();
    final gateway = widget.state.isNavidrome
        ? widget.state.catalog.activeGateway as NavidromeGateway
        : saved.firstOrNull;
    _server.text = gateway?.server.toString() ?? '';
    _username.text = gateway?.username ?? '';
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusy(true);
    final outcome = await widget.state.signInWithNavidrome(
      serverUrl: _server.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      allowInsecureHttp: _server.text.trim().toLowerCase().startsWith(
        'http://',
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = outcome.error;
    });
    widget.onBusy(false);
    if (outcome.ok) {
      _password.clear();
      widget.onConnected();
    }
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            key: const ValueKey('navidrome-server'),
            controller: _server,
            enabled: !_busy,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.tr('服务器地址'),
              hintText: 'https://music.example.com',
            ),
            validator: (value) {
              final uri = Uri.tryParse(value?.trim() ?? '');
              return uri == null ||
                      !uri.hasAuthority ||
                      !['http', 'https'].contains(uri.scheme)
                  ? context.tr('请输入完整的服务器地址。')
                  : null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('navidrome-username'),
            controller: _username,
            enabled: !_busy,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: context.tr('用户名')),
            validator: (value) =>
                value?.trim().isEmpty ?? true ? context.tr('请输入用户名。') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('navidrome-password'),
            controller: _password,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: context.tr('密码'),
              suffixIcon: IconButton(
                tooltip: context.tr(_obscure ? '显示密码' : '隐藏密码'),
                onPressed: _busy
                    ? null
                    : () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
              ),
            ),
            validator: (value) =>
                value?.isEmpty ?? true ? context.tr('请输入密码。') : null,
          ),
          const SizedBox(height: 12),
          TrText(
            '保留服务器和用户名，重新打开应用后需要再次登录。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                context.tr(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('navidrome-connect'),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const TrText('连接服务器'),
          ),
        ],
      ),
    ),
  );
}
