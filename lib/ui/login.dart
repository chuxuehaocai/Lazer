import '../widgets/build_safe_state.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../theme/lazer_theme.dart';
import '../animation/view_transitions.dart';
import '../updates/open_external.dart';
import '../gateway/gateway.dart';
import 'plugin_manager_page.dart';
import '../widgets/settings_choice.dart';
import '../theme/shape_scale.dart';

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
        ui: state.pluginTheme ?? LazerThemeTokens.apple,
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

class _AppLoginDialogState extends State<_AppLoginDialog>
    with BuildSafeState<_AppLoginDialog> {
  /// Seconds before another SMS code may be requested.
  static const int _resendCooldown = 60;

  /// The mainland number the +86 field accepts.
  static final RegExp _phonePattern = RegExp(r'^1\d{10}$');

  _Mode _mode = _Mode.qr;
  Set<String> get _methods => state.musicAuthenticationMethods;
  bool _supports(_Mode mode) => _methods.contains(switch (mode) {
    _Mode.qr => 'qr',
    _Mode.sms => 'sms',
    _Mode.password => 'password',
    _Mode.cookie => 'cookie',
  });
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
  QrSessionInfo? _qrInfo;

  AppState get state => widget.state;
  bool get _formBusy => _submitting || _sendingCode || _navBusy;
  bool get _routeActive => mounted && ModalRoute.of(context)?.isActive == true;

  void _closeDialog() {
    if (!_routeActive) return;
    final route = ModalRoute.of(context)!;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      // Authentication can finish under another modal. Close only this card.
      navigator.removeRoute(route);
    }
  }

  @override
  void initState() {
    super.initState();
    _mode = _Mode.values.where(_supports).firstOrNull ?? _Mode.cookie;
    if (_mode == _Mode.qr) unawaited(_start());
  }

  Future<void> _start() async {
    if (!_supports(_Mode.qr)) return;
    final int generation = ++_qrGeneration;
    _poll?.cancel();
    setState(() {
      _phase = _Phase.creating;
      _url = null;
      _qrInfo = null;
      _error = null;
    });
    final owner = state.activeConnectionKey;
    String? url;
    try {
      url = await state.beginQrLogin();
    } catch (_) {
      // Plugin and persistence failures are recoverable from the card too.
    }
    if (!_routeActive ||
        _mode != _Mode.qr ||
        generation != _qrGeneration ||
        owner != state.activeConnectionKey) {
      return;
    }
    setState(() {
      _url = url;
      _qrInfo = state.qrSession;
      _phase = url == null ? _Phase.error : _Phase.waiting;
      _error = url == null ? state.qrStartError ?? '连接失败，请检查网络后重试。' : null;
    });
    final pollUrl = url;
    if (pollUrl != null) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick(pollUrl));
      unawaited(_tick(pollUrl));
    }
  }

  Future<void> _tick(String url) async {
    if (_polling || !_routeActive || _mode != _Mode.qr) return;
    _polling = true;
    final generation = _qrGeneration;
    final owner = state.activeConnectionKey;
    try {
      final int code = await state.pollQrLogin(url);
      if (!_routeActive ||
          generation != _qrGeneration ||
          owner != state.activeConnectionKey) {
        return;
      }
      if (code == 803) {
        // The poll may confirm after the card switched to another tab; the
        // session is already adopted, so close it from here as well.
        _poll?.cancel();
        _closeDialog();
        return;
      }
      if (_mode != _Mode.qr && _supports(_Mode.qr)) return;
      setState(() {
        _error = state.qrPollError;
        if (code == 800) {
          _phase = _Phase.expired;
          _poll?.cancel();
        } else if (code == 802 || code == 8821) {
          _phase = _Phase.scanned;
        }
      });
    } catch (_) {
      if (_routeActive &&
          generation == _qrGeneration &&
          owner == state.activeConnectionKey) {
        _poll?.cancel();
        setState(() {
          _phase = _Phase.error;
          _error = '连接失败，请检查网络后重试。'; // i18n:key
        });
      }
    } finally {
      _polling = false;
    }
  }

  void _switchMode(_Mode mode) {
    if (_formBusy || _mode == mode) return;
    _poll?.cancel();
    ++_qrGeneration;
    setState(() {
      _mode = mode;
      _error = null;
      _notice = null;
      _url = null;
      _qrInfo = null;
    });
    if (mode == _Mode.qr) unawaited(_start());
  }

  Future<void> _selectConnection(String? key) async {
    if (key == null || _formBusy) return;
    _poll?.cancel();
    _qrGeneration++;
    setState(() {
      _navBusy = true;
      _url = null;
      _qrInfo = null;
      _error = null;
    });
    try {
      await state.selectMusicConnection(key);
      if (!_routeActive) return;
      setState(() {
        _mode = _Mode.values.where(_supports).firstOrNull ?? _Mode.cookie;
      });
      if (_mode == _Mode.qr) unawaited(_start());
    } catch (_) {
      if (mounted) setState(() => _error = '操作失败，请稍后重试。'); // i18n:key
    } finally {
      if (mounted) setState(() => _navBusy = false);
    }
  }

  Future<AuthOutcome> _authenticationResult(
    Future<AuthOutcome> Function() request, {
    String failure = '登录失败，请稍后再试。', // i18n:key
  }) async {
    try {
      return await request();
    } catch (_) {
      return AuthOutcome(false, error: failure);
    }
  }

  Future<void> _submitCookie() async {
    final String value = _cookie.text.trim();
    if (value.isEmpty || _formBusy) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final AuthOutcome outcome = await _authenticationResult(
      () => state.signInWithCookie(value),
    );
    if (!_routeActive) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      _closeDialog();
    } else if (_mode == _Mode.cookie) {
      setState(() => _error = outcome.error ?? '这个 Cookie 无效或已过期。'); // i18n:key
    }
  }

  Future<void> _sendCode() async {
    if (_formBusy || _resendSeconds > 0) return;
    final String phone = _phone.text.trim();
    if (!_phonePattern.hasMatch(phone)) {
      setState(() => _error = '手机号格式不正确。'); // i18n:key
      return;
    }
    setState(() {
      _sendingCode = true;
      _error = null;
      _notice = null;
    });
    final AuthOutcome outcome = await _authenticationResult(
      () => state.sendSmsCode(phone),
      failure: '验证码发送失败，请稍后重试。', // i18n:key
    );
    if (!_routeActive) return;
    setState(() {
      _sendingCode = false;
      if (outcome.ok) {
        _notice = '验证码已发送。'; // i18n:key
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
    if (_formBusy) return;
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
    final AuthOutcome outcome = await _authenticationResult(
      () => state.signInWithPhoneCaptcha(phone, code),
    );
    if (!_routeActive) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      _closeDialog();
    } else if (_mode == _Mode.sms) {
      setState(() => _error = outcome.error ?? '登录失败，请稍后再试。'); // i18n:key
    }
  }

  String? _accountValidationError(String account) {
    if (account.isEmpty) return '请输入手机号或邮箱。';
    if (account.contains('@')) {
      return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(account)
          ? null
          : '邮箱格式不正确。'; // i18n:key
    }
    return _phonePattern.hasMatch(account) ? null : '手机号格式不正确。';
  }

  Future<void> _submitPassword() async {
    if (_formBusy) return;
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
    final AuthOutcome outcome = await _authenticationResult(
      () => state.signInWithPassword(account, password),
    );
    if (!_routeActive) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      _password.clear();
      _closeDialog();
    } else if (_mode == _Mode.password) {
      setState(() => _error = outcome.error ?? '登录失败，请稍后再试。'); // i18n:key
    }
  }

  Future<void> _openForgotPassword() async {
    final url = state.musicForgotPasswordUrl;
    if (url == null) return;
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
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: apple.tertiaryBackground,
          borderRadius: BorderRadius.circular(28 * AppleShape.scaleOf(context)),
          border: Border.all(color: apple.separator, width: .5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: .3),
              blurRadius: 44,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: apple.accentSoft,
                      borderRadius: BorderRadius.circular(14 * AppleShape.scaleOf(context)),
                    ),
                    child: Icon(
                      Icons.person_outline_rounded,
                      color: apple.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
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
                    style: IconButton.styleFrom(
                      backgroundColor: apple.secondaryFill,
                      foregroundColor: apple.secondaryLabel,
                      minimumSize: const Size(40, 40),
                    ),
                    // Route activity also guards the mounted exit animation.
                    onPressed: _closeDialog,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              TrText(
                '音乐平台',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: apple.secondaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SettingsChoice<String>(
                  key: ValueKey('login-platform-${state.activeConnectionKey}'),
                  value: state.activeConnectionKey,
                  items: [
                    for (final gateway in state.availableMusicPlatforms)
                      DropdownMenuItem(
                        value: GatewayRegistry.keyOf(gateway),
                        child: Row(
                          children: [
                            Icon(
                              gateway.provider.id == 'local'
                                  ? Icons.library_music_outlined
                                  : Icons.headphones_rounded,
                              size: 20,
                              color: apple.accent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                gateway.provider.id == 'local'
                                    ? context.tr('本地音乐')
                                    : gateway.provider.name,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (state.musicAccounts.containsKey(
                              GatewayRegistry.keyOf(gateway),
                            ))
                              Tooltip(
                                message: context.tr('已登录'),
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  size: 18,
                                  color: apple.accent,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: _formBusy ? null : _selectConnection,
                ),
              ),
              if (_methods.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    state.musicLoginHint ??
                        switch (_mode) {
                          _Mode.qr => '使用音乐平台 App 扫描二维码登录。',
                          _Mode.sms => '使用手机号和短信验证码登录。',
                          _Mode.password => '使用手机号或邮箱和密码登录。',
                          _Mode.cookie => '粘贴音乐平台的登录 Cookie。',
                        },
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (_methods.isEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: apple.secondaryFill.withValues(alpha: .45),
                        borderRadius: BorderRadius.circular(16 * AppleShape.scaleOf(context)),
                      ),
                      child: TrText(
                        state.musicProvider.id == 'local'
                            ? '本地音乐无需登录，其他平台的账号会继续保留。'
                            : '先安装并启用音乐平台插件，再登录。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: apple.secondaryLabel,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SpringFilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16 * AppleShape.scaleOf(context)),
                        ),
                      ),
                      onPressed: () {
                        final navigator = Navigator.of(context);
                        navigator.pop();
                        navigator.push(
                          ApplePageRoute<void>(
                            builder: (_) => PluginManagerPage(state: state),
                          ),
                        );
                      },
                      icon: const Icon(Icons.extension_outlined, size: 20),
                      label: const TrText('插件管理'),
                    ),
                  ],
                )
              else
                ViewTransitionSwitcher(
                  expand: false,
                  child: KeyedSubtree(
                    key: ValueKey(_mode.name),
                    child: Column(
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
            borderRadius: BorderRadius.circular(16 * AppleShape.scaleOf(context)),
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
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(
          _error!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
      const SizedBox(height: 14),
      Center(
        child: TrText(
          switch (_phase) {
            _Phase.creating => '正在生成二维码…',
            _Phase.waiting =>
              _qrInfo?.hint?.isNotEmpty == true
                  ? _qrInfo!.hint!
                  : '打开 App 扫描二维码',
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
      if (_phase == _Phase.waiting && _qrInfo?.code?.isNotEmpty == true) ...[
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: apple.tertiaryFill,
              borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
              border: Border.all(color: apple.separator, width: .5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TrText(
                  '验证码：',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
                Text(
                  _qrInfo!.code!,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: apple.label,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: context.tr('复制验证码'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _qrInfo!.code!));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(context.tr('验证码已复制到剪贴板。')),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
      if (_phase == _Phase.waiting &&
          _qrInfo?.actionUrl?.isNotEmpty == true) ...[
        const SizedBox(height: 8),
        Center(
          child: SpringTextButton(
            onPressed: () => unawaited(openExternalUrl(_qrInfo!.actionUrl!)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.open_in_browser_rounded,
                  size: 16,
                  color: apple.accent,
                ),
                const SizedBox(width: 6),
                const TrText('在浏览器中打开授权页'),
              ],
            ),
          ),
        ),
      ],
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
        enabled: !_formBusy,
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
              enabled: !_formBusy,
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
            onPressed: _formBusy || _resendSeconds > 0 ? null : _sendCode,
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
        onPressed: _formBusy ? null : _submitSms,
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
        enabled: !_formBusy,
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
        enabled: !_formBusy,
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
        onPressed: _formBusy ? null : _submitPassword,
        child: _submitting
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const TrText('登录'),
      ),
      const SizedBox(height: 2),
      if (state.musicForgotPasswordUrl != null)
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
        enabled: !_formBusy,
        minLines: 3,
        maxLines: 5,
        autofocus: true,
        style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
        decoration: InputDecoration(
          hintText: state.musicCookieHint ?? context.tr('登录 Cookie'),
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
        onPressed: _formBusy ? null : _submitCookie,
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
          if (_mode != _Mode.qr && _supports(_Mode.qr))
            SpringTextButton(
              onPressed: _formBusy ? null : () => _switchMode(_Mode.qr),
              child: const TrText('扫码登录'),
            ),
          if (_mode != _Mode.sms && _supports(_Mode.sms))
            SpringTextButton(
              onPressed: _formBusy ? null : () => _switchMode(_Mode.sms),
              child: const TrText('短信验证码登录'),
            ),
          if (_mode != _Mode.password && _supports(_Mode.password))
            SpringTextButton(
              onPressed: _formBusy ? null : () => _switchMode(_Mode.password),
              child: const TrText('密码登录'),
            ),
          if (_mode != _Mode.cookie && _supports(_Mode.cookie))
            SpringTextButton(
              onPressed: _formBusy ? null : () => _switchMode(_Mode.cookie),
              child: const TrText('使用 Cookie 登录'),
            ),
        ],
      ),
    ];
  }
}
