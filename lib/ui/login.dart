import '../widgets/spring_buttons.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../animation/view_transitions.dart';
import '../updates/open_external.dart';
import '../widgets/music_provider_badge.dart';
import '../gateway/gateway.dart';
import 'navidrome_login_fields.dart';

/// Present the sign-in card in the Apple sheet language.
Future<void> showAppLoginDialog(BuildContext context, AppState state) {
  final Brightness brightness = Theme.of(context).brightness;
  final Color accent = state.accentSeed ?? AppleColors.musicRed;
  return showAppleDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (BuildContext context) => Theme(
      data: buildAppleTheme(
        brightness: brightness,
        seedAccent: accent,
        fonts: state.fontPreferences,
      ),
      child: _AppLoginDialog(state: state),
    ),
  );
}

enum _Phase { creating, waiting, scanned, expired, error }

enum _Mode { qr, sms, password, cookie }

class _AppLoginDialog extends StatefulWidget {
  const _AppLoginDialog({required this.state});

  final AppState state;

  @override
  State<_AppLoginDialog> createState() => _AppLoginDialogState();
}

class _AppLoginDialogState extends State<_AppLoginDialog> {
  /// Seconds before another SMS code may be requested.
  static const int _resendCooldown = 60;

  /// The mainland number the +86 field accepts.
  static final RegExp _phonePattern = RegExp(r'^1\d{10}$');

  _Mode _mode = _Mode.qr;
  late bool _navidrome = state.isNavidrome;
  bool _navBusy = false;
  _Phase _phase = _Phase.creating;
  String? _url;
  Timer? _poll;
  bool _polling = false;

  /// Invalidates an in-flight [beginQrLogin] when the tab changes or another
  /// refresh starts, so only the newest handshake may install a poll timer.
  int _qrGeneration = 0;

  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _cookie = TextEditingController();
  bool _obscurePassword = true;
  bool _submitting = false;
  bool _sendingCode = false;
  int _resendSeconds = 0;
  Timer? _resend;
  String? _error;
  String? _notice;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    if (!_navidrome) unawaited(_start());
  }

  Future<void> _start() async {
    if (_navidrome) return;
    final int generation = ++_qrGeneration;
    _poll?.cancel();
    setState(() {
      _phase = _Phase.creating;
      _url = null;
      _error = null;
    });
    final String? url = await state.beginQrLogin();
    if (!mounted ||
        _navidrome ||
        _mode != _Mode.qr ||
        generation != _qrGeneration) {
      return;
    }
    setState(() {
      _url = url;
      _phase = url == null ? _Phase.error : _Phase.waiting;
      _error = url == null ? state.qrStartError ?? '连接失败，请检查网络后重试。' : null;
    });
    if (url != null) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick(url));
      unawaited(_tick(url));
    }
  }

  Future<void> _tick(String url) async {
    if (_polling || !mounted || _navidrome || _mode != _Mode.qr) return;
    _polling = true;
    try {
      final int code = await state.pollQrLogin(url);
      if (!mounted || _navidrome) return;
      if (code == 803) {
        // The poll may confirm after the card switched to another tab; the
        // session is already adopted, so close it from here as well.
        _poll?.cancel();
        Navigator.of(context).maybePop();
        return;
      }
      if (_mode != _Mode.qr) return;
      setState(() {
        _error = state.qrPollError;
        if (code == 800) {
          _phase = _Phase.expired;
          _poll?.cancel();
        } else if (code == 802 || code == 8821) {
          _phase = _Phase.scanned;
        }
      });
    } finally {
      _polling = false;
    }
  }

  void _switchMode(_Mode mode) {
    if (_mode == mode) return;
    _poll?.cancel();
    ++_qrGeneration;
    setState(() {
      _mode = mode;
      _error = null;
      _notice = null;
    });
    if (mode == _Mode.qr) unawaited(_start());
  }

  void _switchPlatform(bool navidrome) {
    if (_navBusy || _submitting || _navidrome == navidrome) return;
    _poll?.cancel();
    _qrGeneration++;
    setState(() {
      _navidrome = navidrome;
      _error = null;
    });
    if (!navidrome && _mode == _Mode.qr) unawaited(_start());
  }

  Future<void> _submitCookie() async {
    final String value = _cookie.text.trim();
    if (value.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final AuthOutcome outcome = await state.signInWithCookie(value);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      Navigator.of(context).maybePop();
    } else if (_mode == _Mode.cookie) {
      setState(() => _error = outcome.error ?? '这个 Cookie 无效或已过期。'); // i18n:key
    }
  }

  Future<void> _sendCode() async {
    final String phone = _phone.text.trim();
    if (!_phonePattern.hasMatch(phone)) {
      setState(() => _error = '手机号格式不正确。'); // i18n:key
      return;
    }
    if (_sendingCode || _resendSeconds > 0) return;
    setState(() {
      _sendingCode = true;
      _error = null;
      _notice = null;
    });
    final AuthOutcome outcome = await state.sendSmsCode(phone);
    if (!mounted) return;
    setState(() {
      _sendingCode = false;
      if (outcome.ok) {
        _notice = '验证码已发送，请注意查收。'; // i18n:key
        _resendSeconds = _resendCooldown;
      } else if (_mode == _Mode.sms) {
        _error = outcome.error ?? '验证码发送失败，请稍后重试。'; // i18n:key
      }
    });
    if (outcome.ok) _startResendTimer();
  }

  void _startResendTimer() {
    _resend?.cancel();
    _resend = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendSeconds = (_resendSeconds - 1).clamp(0, _resendCooldown);
        if (_resendSeconds == 0) timer.cancel();
      });
    });
  }

  Future<void> _submitSms() async {
    if (_submitting) return;
    final String phone = _phone.text.trim();
    final String code = _code.text.trim();
    if (!_phonePattern.hasMatch(phone)) {
      setState(() => _error = '手机号格式不正确。'); // i18n:key
      return;
    }
    if (code.length < 4) {
      setState(() => _error = '请输入短信验证码。'); // i18n:key
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final AuthOutcome outcome = await state.signInWithPhoneCaptcha(phone, code);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      Navigator.of(context).maybePop();
    } else if (_mode == _Mode.sms) {
      setState(() => _error = outcome.error ?? '登录失败，请稍后再试。'); // i18n:key
    }
  }

  String? _accountValidationError(String account) {
    if (account.isEmpty) return '请输入手机号或邮箱。';
    if (account.contains('@')) {
      return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(account)
          ? null
          : '邮箱格式不正确。';
    }
    return _phonePattern.hasMatch(account) ? null : '手机号格式不正确。';
  }

  Future<void> _submitPassword() async {
    if (_submitting) return;
    final String account = _account.text.trim();
    final String password = _password.text;
    final String? validation = _accountValidationError(account);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请输入密码。'); // i18n:key
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final AuthOutcome outcome = await state.signInWithPassword(
      account,
      password,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      _password.clear();
      Navigator.of(context).maybePop();
    } else if (_mode == _Mode.password) {
      setState(() => _error = outcome.error ?? '登录失败，请稍后再试。'); // i18n:key
    }
  }

  Future<void> _openForgotPassword() async {
    const String url = 'https://music.163.com/#/forgetpassword';
    final bool opened = await openExternalUrl(url);
    if (!opened && mounted) {
      setState(() => _error = '无法打开浏览器，请手动访问 $url'); // i18n:key
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _resend?.cancel();
    _phone.dispose();
    _code.dispose();
    _account.dispose();
    _password.dispose();
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 370),
        decoration: BoxDecoration(
          color: apple.tertiaryBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: apple.separator, width: .5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: .3),
              blurRadius: 44,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TrText(
                      '登录',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: apple.label,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('取消'),
                    onPressed: _navBusy || _submitting
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
              SegmentedButton<bool>(
                selected: {_navidrome},
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: TrText('网易云音乐')),
                  ButtonSegment(value: true, label: Text('Navidrome')),
                ],
                onSelectionChanged: _navBusy || _submitting
                    ? null
                    : (values) => _switchPlatform(values.single),
              ),
              if (_navidrome)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ExperimentalMusicBadge(),
                  ),
                ),
              if (state.musicConnections.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(
                      'login-connections-${state.activeConnectionKey}',
                    ),
                    initialValue: state.activeConnectionKey,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: context.tr('已保存的连接'),
                    ),
                    items: [
                      for (final gateway in state.musicConnections)
                        DropdownMenuItem(
                          value: GatewayRegistry.keyOf(gateway),
                          child: Text(
                            gateway is NavidromeGateway
                                ? 'Navidrome · ${gateway.username} @ ${gateway.server.authority}${gateway.server.path}'
                                : context.tr('网易云音乐'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _navBusy || _submitting
                        ? null
                        : (key) async {
                            if (key == null) return;
                            _poll?.cancel();
                            _qrGeneration++;
                            await state.selectMusicConnection(key);
                            if (!mounted) return;
                            setState(() => _navidrome = state.isNavidrome);
                            if (!_navidrome && _mode == _Mode.qr) {
                              unawaited(_start());
                            }
                          },
                  ),
                ),
              const SizedBox(height: 12),
              if (!_navidrome)
                Text(
                  context.tr(switch (_mode) {
                    _Mode.qr => '使用网易云音乐 App 扫描二维码登录。',
                    _Mode.sms => '使用手机号和短信验证码登录。',
                    _Mode.password => '使用手机号或邮箱和密码登录。',
                    _Mode.cookie => '粘贴浏览器里网易云音乐的登录 Cookie。',
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
              const SizedBox(height: 18),
              ViewTransitionSwitcher(
                expand: false,
                child: KeyedSubtree(
                  key: ValueKey(
                    _navidrome
                        ? 'navidrome-${state.activeConnectionKey}'
                        : _mode.name,
                  ),
                  child: _navidrome
                      ? NavidromeLoginFields(
                          state: state,
                          onConnected: () => Navigator.of(context).maybePop(),
                          onBusy: (busy) => setState(() => _navBusy = busy),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_mode == _Mode.sms)
                              ..._smsFields(theme, apple)
                            else if (_mode == _Mode.password)
                              ..._passwordFields(theme, apple)
                            else if (_mode == _Mode.cookie)
                              ..._cookieFields(theme)
                            else
                              ..._qrFields(theme),
                            ..._modeLinks(),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _qrFields(ThemeData theme) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String? url = _url;
    return [
      Center(
        child: Container(
          width: 204,
          height: 204,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: apple.separator, width: .5),
          ),
          clipBehavior: Clip.antiAlias,
          child: url == null
              ? Center(
                  child: _phase == _Phase.creating
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.qr_code_2_rounded,
                          size: 40,
                          color: apple.tertiaryLabel,
                        ),
                )
              : QrImageView(
                  data: url,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                ),
        ),
      ),
      const SizedBox(height: 14),
      Center(
        child: TrText(
          switch (_phase) {
            _Phase.creating => '正在生成二维码…',
            _Phase.waiting => '打开 App 扫描二维码',
            _Phase.scanned => '已扫描，请在手机上确认',
            _Phase.expired => '二维码已过期',
            _Phase.error => '二维码获取失败，请检查网络后重试。',
          },
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: _phase == _Phase.scanned
                ? apple.accent
                : apple.secondaryLabel,
          ),
        ),
      ),
      if (_phase == _Phase.expired || _phase == _Phase.error) ...<Widget>[
        const SizedBox(height: 12),
        Center(
          child: SpringFilledButton(onPressed: _start, child: TrText('刷新二维码')),
        ),
      ],
    ];
  }

  List<Widget> _smsFields(ThemeData theme, AppleSemanticColors apple) {
    return [
      TextField(
        controller: _phone,
        autofocus: true,
        keyboardType: TextInputType.phone,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(11),
        ],
        style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
        decoration: InputDecoration(
          hintText: context.tr('手机号'),
          prefixText: '+86 ',
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              onSubmitted: (_) => unawaited(_submitSms()),
              style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
              decoration: InputDecoration(hintText: context.tr('短信验证码')),
            ),
          ),
          const SizedBox(width: 8),
          SpringTextButton(
            onPressed: _sendingCode || _resendSeconds > 0 ? null : _sendCode,
            child: _sendingCode
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TrText(_resendSeconds > 0 ? '$_resendSeconds 秒' : '获取验证码'),
          ),
        ],
      ),
      if (_notice != null) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          context.tr(_notice!),
          style: theme.textTheme.bodySmall?.copyWith(
            color: apple.secondaryLabel,
          ),
        ),
      ],
      if (_error != null) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          context.tr(_error!),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
      const SizedBox(height: 14),
      SpringFilledButton(
        onPressed: _submitting ? null : _submitSms,
        child: _submitting
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const TrText('登录'),
      ),
    ];
  }

  List<Widget> _passwordFields(ThemeData theme, AppleSemanticColors apple) {
    return [
      TextField(
        key: const ValueKey('login-password-account'),
        controller: _account,
        autofocus: true,
        enabled: !_submitting,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        autocorrect: false,
        autofillHints: const <String>[AutofillHints.username],
        style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
        decoration: InputDecoration(
          labelText: context.tr('手机号或邮箱'),
          hintText: context.tr('请输入手机号或邮箱'),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('login-password-password'),
        controller: _password,
        enabled: !_submitting,
        obscureText: _obscurePassword,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: const <String>[AutofillHints.password],
        onSubmitted: (_) => unawaited(_submitPassword()),
        style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
        decoration: InputDecoration(
          labelText: context.tr('密码'),
          suffixIcon: IconButton(
            tooltip: context.tr(_obscurePassword ? '显示密码' : '隐藏密码'),
            onPressed: _submitting
                ? null
                : () => setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
            ),
          ),
        ),
      ),
      if (_error != null) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          context.tr(_error!),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
      const SizedBox(height: 14),
      SpringFilledButton(
        key: const ValueKey('login-password-submit'),
        onPressed: _submitting ? null : _submitPassword,
        child: _submitting
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const TrText('登录'),
      ),
      const SizedBox(height: 2),
      Center(
        child: SpringTextButton(
          onPressed: _submitting ? null : _openForgotPassword,
          child: const TrText('忘记密码？'),
        ),
      ),
    ];
  }

  List<Widget> _cookieFields(ThemeData theme) {
    return [
      TextField(
        controller: _cookie,
        minLines: 3,
        maxLines: 5,
        autofocus: true,
        style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
        decoration: const InputDecoration(hintText: 'MUSIC_U=…  __csrf=…'),
      ),
      if (_error != null) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          context.tr(_error!),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
      const SizedBox(height: 14),
      SpringFilledButton(
        onPressed: _submitting ? null : _submitCookie,
        child: _submitting
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TrText('登录'),
      ),
    ];
  }

  List<Widget> _modeLinks() {
    return <Widget>[
      const SizedBox(height: 4),
      Wrap(
        alignment: WrapAlignment.center,
        children: <Widget>[
          if (_mode != _Mode.qr)
            SpringTextButton(
              onPressed: () => _switchMode(_Mode.qr),
              child: const TrText('扫码登录'),
            ),
          if (_mode != _Mode.sms)
            SpringTextButton(
              onPressed: () => _switchMode(_Mode.sms),
              child: const TrText('短信验证码登录'),
            ),
          if (_mode != _Mode.password)
            SpringTextButton(
              onPressed: () => _switchMode(_Mode.password),
              child: const TrText('密码登录'),
            ),
          if (_mode != _Mode.cookie)
            SpringTextButton(
              onPressed: () => _switchMode(_Mode.cookie),
              child: const TrText('使用 Cookie 登录'),
            ),
        ],
      ),
    ];
  }
}
