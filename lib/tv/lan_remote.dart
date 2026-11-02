import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../l10n/app_localizations.dart';
import '../state/ui_preferences.dart';
import '../widgets/settings_row.dart';
import 'tv_mode.dart';

/// An opt-in remote, running only while the large-screen surface is active.
class LanRemoteController extends ChangeNotifier {
  LanRemoteController(
    this.state, {
    this.bindAddress,
    Future<List<InternetAddress>> Function()? interfaceAddresses,
  }) : _interfaceAddresses = interfaceAddresses ?? _localAddresses {
    state.addListener(_reconcile);
  }

  final AppState state;
  final InternetAddress? bindAddress;
  final Future<List<InternetAddress>> Function() _interfaceAddresses;
  HttpServer? _server;
  bool enabled = false;
  bool _disposed = false, _starting = false;
  String? error;
  String _token = '';
  List<String> urls = const [];
  int? get port => _server?.port;
  bool get running => _server != null;
  bool get _active =>
      state.surface == AppSurface.tv ||
      (state.surface == AppSurface.auto && state.deviceIsTelevision);

  static Future<List<InternetAddress>> _localAddresses() async =>
      (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((interface) => interface.addresses)
          .where((address) => !address.isLoopback)
          .toList();

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    enabled = prefs.getBool('lazer_lan_remote') ?? false;
    _reconcile();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    error = null;
    notifyListeners();
    _reconcile();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_lan_remote', value);
  }

  void _reconcile() {
    if (_disposed) return;
    if (!enabled || !_active) {
      final server = _server;
      _server = null;
      urls = const [];
      unawaited(server?.close(force: true));
      if (server != null) notifyListeners();
    } else if (_server == null && !_starting && error == null) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    _starting = true;
    error = null;
    try {
      final random = Random.secure();
      _token = base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
      final server = await HttpServer.bind(
        bindAddress ?? InternetAddress.anyIPv4,
        0,
      );
      if (_disposed || !enabled || !_active) {
        await server.close(force: true);
        return;
      }
      _server = server;
      server.listen((request) => unawaited(_handle(request)));
      final addresses = bindAddress == null
          ? await _interfaceAddresses()
          : [bindAddress!];
      if (_server != server || _disposed) return;
      urls = [
        for (final address in addresses)
          'http://${address.address}:${server.port}/?token=$_token',
      ];
    } catch (e) {
      final server = _server;
      _server = null;
      await server?.close(force: true);
      error = '无法启动遥控器：$e';
    } finally {
      _starting = false;
      if (!_disposed) {
        notifyListeners();
        // The mode or switch can change while binding/listing interfaces.
        // A close followed by an enable must restart after this start ends.
        _reconcile();
      }
    }
  }

  EditableTextState? get _editor {
    EditableTextState? editor;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
      element,
    ) {
      if (element is StatefulElement && element.state is EditableTextState) {
        editor = element.state as EditableTextState;
        return false;
      }
      return true;
    });
    return editor;
  }

  Map<String, Object?> get snapshot {
    final editor = _editor;
    final hidden = editor?.widget.obscureText ?? false;
    return {
      'title': state.current?.title ?? '尚未播放',
      'artist': state.current?.artist ?? '',
      'playing': state.playing,
      'volume': state.volume,
      'input': editor != null,
      'secret': hidden,
      'text': editor == null || hidden ? '' : editor.widget.controller.text,
    };
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'",
    );
    try {
      if (!enabled ||
          !_active ||
          request.uri.queryParameters['token'] != _token) {
        response.statusCode = HttpStatus.forbidden;
      } else if (request.method == 'GET' && request.uri.path == '/') {
        response.headers.contentType = ContentType.html;
        response.write(_remoteHtml);
      } else if (request.method == 'GET' && request.uri.path == '/state') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(snapshot));
      } else if (request.method == 'POST' && request.uri.path == '/command') {
        // A token grants control, but another web page must never issue commands.
        final origin = request.headers.value('origin');
        if (origin != null &&
            origin !=
                'http://${request.headers.value(HttpHeaders.hostHeader)}') {
          response.statusCode = HttpStatus.forbidden;
        } else {
          final bytes = <int>[];
          await for (final chunk in request.timeout(
            const Duration(seconds: 5),
          )) {
            bytes.addAll(chunk);
            if (bytes.length > 16384) {
              throw const FormatException('Request too large');
            }
          }
          final body = jsonDecode(utf8.decode(bytes));
          if (body is! Map<String, dynamic>) throw const FormatException();
          await command(body);
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(snapshot));
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await response.close();
      } on IOException {
        // The peer or the opt-in server may close while a request is pending.
      }
    }
  }

  Future<void> command(Map<String, dynamic> body) async {
    switch (body['action']) {
      case 'play':
        state.togglePlay();
      case 'next':
        state.next();
      case 'previous':
        state.previous();
      case 'volume':
        final value = body['value'];
        if (value is num && value.isFinite) {
          await state.setVolume(value.toDouble().clamp(0, 1));
        }
      case 'text':
        _replaceInput(_editor, body['text']);
      case 'submit':
        final editor = _editor;
        if (editor != null) {
          // Confirming from the browser also sends the current draft. Users
          // need not press the separate send button before submitting a field.
          _replaceInput(editor, body['text']);
          editor.performAction(
            editor.widget.textInputAction ?? TextInputAction.done,
          );
        }
      case 'key':
        final key = switch (body['key']) {
          'up' => (PhysicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp),
          'down' => (
            PhysicalKeyboardKey.arrowDown,
            LogicalKeyboardKey.arrowDown,
          ),
          'left' => (
            PhysicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.arrowLeft,
          ),
          'right' => (
            PhysicalKeyboardKey.arrowRight,
            LogicalKeyboardKey.arrowRight,
          ),
          'select' => (PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
          'back' => (PhysicalKeyboardKey.escape, LogicalKeyboardKey.escape),
          _ => null,
        };
        if (key == null) return;
        if (body['key'] == 'back') {
          if (TvOverlayStack.instance.closeTop()) return;
          final context = FocusManager.instance.primaryFocus?.context;
          if (context != null) {
            final navigator = Navigator.maybeOf(context);
            if (navigator != null) await navigator.maybePop();
          }
          return;
        }
        final events = <KeyEvent>[
          KeyDownEvent(
            physicalKey: key.$1,
            logicalKey: key.$2,
            timeStamp: Duration.zero,
          ),
          KeyUpEvent(
            physicalKey: key.$1,
            logicalKey: key.$2,
            timeStamp: Duration.zero,
          ),
        ];
        for (final event in events) {
          HardwareKeyboard.instance.handleKeyEvent(event);
          // Flutter's focus dispatcher still consumes KeyMessage internally.
          // ignore: deprecated_member_use
          ServicesBinding.instance.keyEventManager.keyMessageHandler?.call(
            // ignore: deprecated_member_use
            KeyMessage([event], null),
          );
        }
    }
  }

  void _replaceInput(EditableTextState? editor, Object? text) {
    if (editor == null ||
        editor.widget.readOnly ||
        text is! String ||
        text.length > 4096) {
      return;
    }
    editor.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    state.removeListener(_reconcile);
    unawaited(_server?.close(force: true));
    _server = null;
    super.dispose();
  }
}

class LanRemoteScope extends InheritedWidget {
  const LanRemoteScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final LanRemoteController controller;
  static LanRemoteController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanRemoteScope>()?.controller;
  @override
  bool updateShouldNotify(LanRemoteScope oldWidget) =>
      controller != oldWidget.controller;
}

class LanRemoteSettings extends StatelessWidget {
  const LanRemoteSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final remote = LanRemoteScope.of(context);
    if (remote == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: remote,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(remote.setEnabled(!remote.enabled)),
            child: SettingsRow(
              label: '局域网遥控器',
              subtitle: '在大屏幕模式下开启，用同一网络的手机或电脑控制并输入文字',
              trailing: Switch(
                value: remote.enabled,
                onChanged: (value) => unawaited(remote.setEnabled(value)),
              ),
            ),
          ),
          if (remote.enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TrText(
                    remote.error ??
                        (remote.running ? '在浏览器打开以下地址：' : '切换到大屏幕模式后启动'),
                  ),
                  for (final url in remote.urls) SelectableText(url),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

const _remoteHtml = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Lazer 遥控器</title>
<style>body{font:16px system-ui;background:#151519;color:#fafafa;max-width:460px;margin:32px auto;padding:16px}button,input,textarea{font:inherit;border:0;border-radius:16px;padding:18px;background:#303038;color:inherit}button{cursor:pointer;min-width:76px;touch-action:manipulation}button:active{background:#fa3155}.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin:24px 0}.row{display:flex;gap:12px;justify-content:center;margin:16px 0}textarea{box-sizing:border-box;width:100%;resize:vertical}#status{color:#bdbdc6}input{width:100%;box-sizing:border-box}</style>
<h1>Lazer 遥控器</h1><h3 id="song">正在连接…</h3><p id="status">请保持设备在同一局域网</p>
<div class="pad"><span></span><button data-key="up">↑</button><span></span><button data-key="left">←</button><button data-key="select">确定</button><button data-key="right">→</button><span></span><button data-key="down">↓</button><span></span></div>
<div class="row"><button data-key="back">返回</button></div><div class="row"><button data-action="previous">上一首</button><button data-action="play" id="play">播放 / 暂停</button><button data-action="next">下一首</button></div>
<label>音量<input id="volume" type="range" min="0" max="1" step="0.02"></label>
<section id="editor" hidden><h3>文字输入</h3><textarea id="text" rows="3" placeholder="在此输入文字"></textarea><div class="row"><button id="send">发送文字</button><button data-action="submit">确认输入</button></div></section>
<script>const token=new URLSearchParams(location.search).get('token'),q='?token='+encodeURIComponent(token),$=id=>document.getElementById(id);let busy=false;async function send(body){try{const r=await fetch('/command'+q,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});if(!r.ok)throw Error();render(await r.json())}catch(e){$('status').textContent='连接中断，请检查大屏上的地址'}}function render(s){$('song').textContent=s.title;$('status').textContent=s.artist||'已连接';$('play').textContent=s.playing?'暂停':'播放';$('editor').hidden=!s.input;if(document.activeElement!==$('text')){$('text').value=s.text;$('text').placeholder=s.secret?'输入内容不会回显在遥控器':'在此输入文字'}if(document.activeElement!==$('volume'))$('volume').value=s.volume}document.querySelectorAll('[data-key]').forEach(b=>b.onclick=()=>send({action:'key',key:b.dataset.key}));document.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>send({action:b.dataset.action,...(b.dataset.action==='submit'?{text:$('text').value}:{})}));$('send').onclick=()=>send({action:'text',text:$('text').value});$('volume').onchange=()=>send({action:'volume',value:Number($('volume').value)});document.onkeydown=e=>{if(['TEXTAREA','INPUT'].includes(e.target.tagName))return;const key={ArrowUp:'up',ArrowDown:'down',ArrowLeft:'left',ArrowRight:'right',Enter:'select',Escape:'back'}[e.key];if(key){e.preventDefault();send({action:'key',key})}};async function poll(){if(busy)return;busy=true;try{const r=await fetch('/state'+q);if(!r.ok)throw Error();render(await r.json())}catch(e){$('status').textContent='连接中断，请检查大屏上的地址'}finally{busy=false}}poll();setInterval(poll,1200);</script></html>''';
