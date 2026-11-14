// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
// i18n:data — runtime error messages are interface keys shown by the plugin UI
// through `context.tr`.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:html' as html;

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:lua_dardo_plus/lua.dart';
import 'package:pointycastle/export.dart' as pc;

import 'plugin_manifest.dart';
import 'lua_console_evaluator.dart';
import '../diagnostics/app_log.dart';
import '../utils/system_http.dart';

/// Browser implementation of the Lua gateway runtime.
///
/// The VM is still isolated from Flutter objects and filesystem APIs. Browser
/// storage is used for the small host storage contract; network calls go through
/// the same-origin `/api/plugin-http` function so plugins do not need CORS
/// access to a music service.
class LuaPluginRuntime {
  LuaPluginRuntime({
    required this.manifest,
    required this.sources,
    required this.dataDirectory,
    this.timeout = const Duration(seconds: 40),
    this.httpHandler,
    this.websocketGranted = false,
  });

  final PluginManifest manifest;
  final Map<String, String> sources;
  final String dataDirectory;
  final Duration timeout;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  httpHandler;
  final bool websocketGranted;

  final Random _random = Random.secure();
  final http.Client _client = http.Client();
  Future<void>? _starting;
  Future<void> _calls = Future<void>.value();
  LuaState? _lua;
  _WebPluginHost? _host;
  bool _closed = false;

  Future<void> start() => _starting ??= _start();

  void updateProxy({required ProxyMode mode, String? endpoint}) {}

  Future<void> _start() async {
    if (_closed) throw const PluginException('插件已停止。');
    AppLog.shared.event('lua', 'starting', {'plugin': manifest.id});
    final host = _WebPluginHost(
      manifest,
      sources,
      dataDirectory,
      random: _random,
      client: _client,
      externalHttp: httpHandler,
      websocketGranted: websocketGranted,
    );
    await host.initialize();
    _host = host;
    _lua = host.lua;
    AppLog.shared.event('lua', 'started', {'plugin': manifest.id});
  }

  Future<Object?> invoke(
    String operation, [
    Map<String, dynamic> args = const {},
    Duration? budget,
  ]) {
    final result = Completer<Object?>();
    _calls = _calls.then((_) async {
      final clock = Stopwatch()..start();
      AppLog.shared.event('lua', 'call', {
        'plugin': manifest.id,
        'operation': operation,
      });
      try {
        await start();
        if (_closed) throw const PluginException('插件已停止，请重新启用。');
        result.complete(await _host!.invoke(operation, args));
        AppLog.shared.event('lua', 'completed', {
          'plugin': manifest.id,
          'operation': operation,
          'elapsed_ms': clock.elapsedMilliseconds,
        });
      } catch (error, stack) {
        AppLog.shared.event('lua', 'failed', {
          'plugin': manifest.id,
          'operation': operation,
        });
        result.completeError(error, stack);
      }
    });
    return result.future.timeout(timeout);
  }

  Future<List<String>> evaluate(String source, [Duration? budget]) {
    final result = Completer<List<String>>();
    _calls = _calls.then((_) async {
      try {
        await start();
        if (_closed) throw const PluginException('插件已停止。');
        result.complete(await _host!.lua.evaluate(source));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future.timeout(budget ?? timeout);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    AppLog.shared.event('lua', 'closed', {'plugin': manifest.id});
    _client.close();
    _host?.closeSockets();
    _lua?.setTop(0);
  }
}

class _WebPluginHost {
  _WebPluginHost(
    this.manifest,
    this.sources,
    this.dataKey, {
    required this.random,
    required this.client,
    this.externalHttp,
    this.websocketGranted = false,
  });

  final PluginManifest manifest;
  final Map<String, String> sources;
  final String dataKey;
  final Random random;
  final http.Client client;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  externalHttp;
  final bool websocketGranted;
  final ConsoleCapableLuaState lua = ConsoleCapableLuaState();
  Map<String, dynamic> storage = <String, dynamic>{};
  final Map<String, html.WebSocket> _websockets = <String, html.WebSocket>{};

  void closeSockets() {
    for (final socket in _websockets.values) {
      socket.close();
    }
    _websockets.clear();
  }

  String get _cookieName =>
      'lazer_plugin_${base64Url.encode(utf8.encode(dataKey)).replaceAll('=', '')}';
  String get _localStorageKey => 'lazer.plugin.$dataKey';

  Future<void> initialize() async {
    _loadStorage();
    lua.openLibs();
    for (final key in [
      'io',
      'os',
      'package',
      'debug',
      'dofile',
      'loadfile',
      'load',
      'loadstring',
      'require',
      'print',
    ]) {
      lua.pushNil();
      lua.setGlobal(key);
    }

    void sync(String name, Object? Function(LuaState) fn) {
      lua.register(name, (state) {
        final value = fn(state);
        _push(state, value);
        return 1;
      });
    }

    sync('_json_encode', (state) => jsonEncode(_read(state, 1)));
    sync('_json_decode', (state) => jsonDecode(state.checkString(1)!));
    sync('_now', (_) => DateTime.now().millisecondsSinceEpoch);
    sync('_url_encode', (state) => Uri.encodeComponent(state.checkString(1)!));
    sync('_cookie_compact', (state) => _compactCookie(state.checkString(1)!));
    sync(
      '_cookie_field',
      (state) => _cookieField(state.checkString(1)!, state.checkString(2)!),
    );
    sync('_cookie_merge', (state) {
      final previous = state.isNoneOrNil(1) ? '' : state.checkString(1)!;
      final updates = state.isNoneOrNil(2) ? '' : _cookieText(_read(state, 2));
      return _compactCookie('$previous; $updates');
    });
    sync('_random_hex', (state) {
      final count = state.checkInteger(1) ?? 16;
      if (count < 1 || count > 1024) throw const FormatException();
      return List.generate(
        count,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    });
    sync(
      '_crypto',
      (state) => _crypt(Map<String, dynamic>.from(_read(state, 1) as Map)),
    );
    sync('_module_source', (state) {
      final name = state.checkString(1)!;
      final path = '${name.replaceAll('.', '/')}.lua';
      if (!PluginManifest.safePath(path) || !sources.containsKey(path)) {
        throw const FormatException('Unknown module');
      }
      return sources[path];
    });
    sync(
      '_storage_get',
      (state) => manifest.storage ? storage[state.checkString(1)] : null,
    );
    sync('_storage_set', (state) {
      if (!manifest.storage) {
        throw const FormatException('Storage permission required');
      }
      final key = state.checkString(1)!;
      final value = _read(state, 2);
      final next = <String, dynamic>{...storage};
      value == null ? next.remove(key) : next[key] = value;
      final encoded = jsonEncode(next);
      if (utf8.encode(encoded).length > 1024 * 1024) {
        throw const FormatException('Storage full');
      }
      storage = next;
      _saveStorage();
      return null;
    });
    lua.registerAsync('_http', (state) async {
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      final result = await _http(spec).timeout(const Duration(seconds: 30));
      _push(state, result);
      return 1;
    });
    lua.registerAsync('_websocket', (state) async {
      if (!websocketGranted) {
        throw const FormatException('WebSocket permission required');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      final operation = spec['operation'] as String? ?? 'open';
      final id = spec['id'] as String? ?? 'default';
      if (operation == 'open') {
        final uri = Uri.parse(spec['url'] as String);
        if (!manifest.permitsWebSocket(uri)) {
          throw const FormatException('WebSocket permission denied');
        }
        _websockets[id]?.close();
        final socket = html.WebSocket(uri.toString());
        await socket.onOpen.first;
        _websockets[id] = socket;
        _push(state, true);
        return 1;
      }
      final socket = _websockets[id];
      if (socket == null) throw const FormatException('WebSocket is not open');
      if (operation == 'send') {
        socket.send(spec['data'] ?? '');
        _push(state, true);
        return 1;
      }
      if (operation == 'receive') {
        final event = await socket.onMessage.first.timeout(
          const Duration(seconds: 30),
        );
        _push(state, event.data);
        return 1;
      }
      if (operation == 'close') {
        socket.close();
        _websockets.remove(id);
        _push(state, true);
        return 1;
      }
      throw const FormatException('Unsupported WebSocket operation');
    });
    lua.registerAsync('pcall', (state) async {
      final status = await state.pCallAsync(state.getTop() - 1, luaMultret, 0);
      state.pushBoolean(status == ThreadStatus.luaOk);
      state.insert(1);
      return state.getTop();
    });

    final moduleBuffers = StringBuffer()..writeln('local module_loaders = {}');
    for (final entry in sources.entries.where(
      (entry) => entry.key != manifest.entry,
    )) {
      final moduleName = entry.key
          .substring(0, entry.key.length - 4)
          .replaceAll('/', '.');
      moduleBuffers
        ..writeln('module_loaders[${jsonEncode(moduleName)}] = function()')
        ..writeln(entry.value)
        ..writeln('end');
    }
    final bootstrap =
        '''
      host = { json_encode = _json_encode, json_decode = _json_decode,
        now = _now, url_encode = _url_encode, random_hex = _random_hex,
        cookie_compact = _cookie_compact, cookie_field = _cookie_field,
        cookie_merge = _cookie_merge, crypto = _crypto, http = _http,
        websocket = _websocket,
        storage_get = _storage_get, storage_set = _storage_set }
      $moduleBuffers
      local modules = {}
      function require(name)
        if modules[name] ~= nil then return modules[name] end
        local loader = module_loaders[name]
        if loader == nil then error("unknown module: " .. tostring(name)) end
        local result = loader()
        if result == nil then result = true end
        modules[name] = result
        return result
      end
    ''';
    if (!await lua.doStringAsync(bootstrap)) {
      throw const FormatException('Bootstrap failed');
    }
    final source = sources[manifest.entry];
    if (source == null || lua.loadString(source) != ThreadStatus.luaOk) {
      throw const FormatException('Invalid entry');
    }
    await lua.callAsync(0, 1);
    if (!lua.isTable(-1)) {
      throw const FormatException('Entry must return a table');
    }
    lua.setGlobal('_plugin');
  }

  Future<Object?> invoke(String operation, Object? args) async {
    return lua.withInstructionBudget(250000, () async {
      lua.setTop(0);
      try {
        lua.getGlobal('_plugin');
        lua.getField(-1, 'call');
        lua.remove(-2);
        if (!lua.isFunction(-1)) {
          throw const PluginException('插件缺少 call 入口。');
        }
        lua.pushString(operation);
        _push(lua, args);
        await lua.callAsync(2, 1);
        return _read(lua, -1);
      } finally {
        lua.setTop(0);
      }
    });
  }

  Future<Map<String, dynamic>> _http(Map<String, dynamic> spec) async {
    final uri = Uri.parse(spec['url'] as String);
    if (!manifest.permits(uri)) {
      throw const FormatException('Network permission denied');
    }
    if (externalHttp != null) return externalHttp!(spec);

    // Browser fetch cannot set Cookie or read Set-Cookie. The same-origin
    // function forwards the request and returns a JSON-shaped host response.
    final proxy = Uri.base.resolve('/api/plugin-http');
    final response = await client.post(
      proxy,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'url': uri.toString(),
        'method': spec['method'] ?? 'GET',
        'headers': spec['headers'] ?? const <String, String>{},
        'body': spec['body'],
        'domains': manifest.domains,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('HTTP ${response.statusCode}');
    }
    final value = jsonDecode(response.body);
    if (value is! Map) throw const FormatException('Invalid proxy response');
    return Map<String, dynamic>.from(value);
  }

  void _loadStorage() {
    if (!manifest.storage) return;
    final encoded = _readBrowserValue(_cookieName);
    final value = encoded ?? html.window.localStorage[_localStorageKey];
    if (value == null || value.isEmpty) return;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(value))) as Map;
      storage = Map<String, dynamic>.from(decoded);
    } catch (_) {
      storage = <String, dynamic>{};
    }
  }

  void _saveStorage() {
    if (!manifest.storage) return;
    final value = base64Url.encode(utf8.encode(jsonEncode(storage)));
    // A browser cookie is the durable primary store for normal credentials.
    // Keep a localStorage fallback when a plugin's optional state exceeds the
    // browser's roughly 4 KiB per-cookie limit.
    if (value.length <= 3500) {
      html.document.cookie =
          '$_cookieName=$value; path=/; max-age=31536000; SameSite=Lax';
      html.window.localStorage.remove(_localStorageKey);
    } else {
      html.window.localStorage[_localStorageKey] = value;
    }
  }

  String? _readBrowserValue(String name) {
    for (final item in (html.document.cookie ?? '').split(';')) {
      final separator = item.indexOf('=');
      if (separator <= 0) continue;
      if (item.substring(0, separator).trim() == name) {
        return item.substring(separator + 1).trim();
      }
    }
    return null;
  }

  String _cookieText(Object? value) =>
      value is List ? value.map((item) => '$item').join('\n') : '$value';

  String? _compactCookie(String value) {
    const attributes = {
      'domain',
      'expires',
      'httponly',
      'max-age',
      'path',
      'secure',
      'samesite',
      'priority',
      'partitioned',
    };
    value = value.trim().replaceFirst(
      RegExp(r'^cookie:\s*', caseSensitive: false),
      '',
    );
    final values = <String, String>{};
    for (final segment in value.split(RegExp(r'[;\r\n]+'))) {
      final separator = segment.indexOf('=');
      if (separator <= 0) continue;
      final name = segment.substring(0, separator).trim();
      final cookieValue = segment.substring(separator + 1).trim();
      if (RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name) &&
          !attributes.contains(name.toLowerCase()) &&
          !cookieValue.contains(RegExp(r'[\r\n]'))) {
        values[name] = cookieValue;
      }
    }
    if (values.isEmpty) return null;
    return values.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  String? _cookieField(String value, String field) {
    final compact = _compactCookie(value);
    if (compact == null) return null;
    for (final segment in compact.split(';')) {
      final separator = segment.indexOf('=');
      if (separator > 0 && segment.substring(0, separator).trim() == field) {
        return segment.substring(separator + 1).trim();
      }
    }
    return null;
  }

  Object _crypt(Map<String, dynamic> spec) {
    final input = (spec['text'] ?? spec['input']) as String? ?? '';
    switch (spec['operation']) {
      case 'md5':
        return crypto.md5.convert(utf8.encode(input)).toString();
      case 'sha256':
        return crypto.sha256.convert(utf8.encode(input)).toString();
      case 'base64':
        return base64Encode(utf8.encode(input));
      case 'base64_decode':
        return utf8.decode(base64Decode(input));
      case 'rsa_modpow':
        final modulus = BigInt.parse(spec['modulus'] as String, radix: 16);
        final text = spec['reverse'] == true
            ? input.split('').reversed.join()
            : input;
        final hex = spec['inputEncoding'] == 'utf8'
            ? utf8
                  .encode(text)
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join()
            : text;
        return BigInt.parse(hex, radix: 16)
            .modPow(BigInt.from(spec['exponent'] as int? ?? 65537), modulus)
            .toRadixString(16)
            .padLeft(spec['width'] as int? ?? 256, '0');
      case 'aes':
        final key = utf8.encode(spec['key'] as String);
        final cbc = spec['mode'] == 'cbc';
        final iv = cbc ? utf8.encode(spec['iv'] as String) : null;
        if (spec['decrypt'] == true) {
          final bytes = spec['encoding'] == 'hex'
              ? Uint8List.fromList([
                  for (var i = 0; i < input.length; i += 2)
                    int.parse(input.substring(i, i + 2), radix: 16),
                ])
              : base64Decode(input);
          return utf8.decode(_aes(bytes, key: key, iv: iv, encrypt: false));
        }
        final bytes = _aes(
          Uint8List.fromList(utf8.encode(input)),
          key: key,
          iv: iv,
        );
        return spec['encoding'] == 'hex'
            ? bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
            : base64Encode(bytes);
      default:
        throw const FormatException('Unknown crypto operation');
    }
  }

  Uint8List _aes(
    Uint8List input, {
    required List<int> key,
    List<int>? iv,
    bool encrypt = true,
  }) {
    final pc.PaddedBlockCipher cipher = pc.PaddedBlockCipherImpl(
      pc.PKCS7Padding(),
      iv == null
          ? pc.ECBBlockCipher(pc.AESEngine())
          : pc.CBCBlockCipher(pc.AESEngine()),
    );
    final pc.CipherParameters parameters = iv == null
        ? pc.PaddedBlockCipherParameters<
            pc.CipherParameters,
            pc.CipherParameters
          >(pc.KeyParameter(Uint8List.fromList(key)), null)
        : pc.PaddedBlockCipherParameters<
            pc.CipherParameters,
            pc.CipherParameters
          >(
            pc.ParametersWithIV(
              pc.KeyParameter(Uint8List.fromList(key)),
              Uint8List.fromList(iv),
            ),
            null,
          );
    cipher.init(encrypt, parameters);
    return cipher.process(input);
  }
}

void _push(LuaState lua, Object? value, [int depth = 0]) {
  if (depth > 48) throw const FormatException('Value nesting too deep');
  switch (value) {
    case null:
      lua.pushNil();
    case bool v:
      lua.pushBoolean(v);
    case int v:
      lua.pushInteger(v);
    case num v:
      lua.pushNumber(v.toDouble());
    case String v:
      lua.pushString(v);
    case List values:
      lua.createTable(values.length, 0);
      for (var i = 0; i < values.length; i++) {
        _push(lua, values[i], depth + 1);
        lua.setI(-2, i + 1);
      }
    case Map values:
      lua.createTable(0, values.length);
      for (final entry in values.entries) {
        _push(lua, entry.value, depth + 1);
        lua.setField(-2, entry.key.toString());
      }
    default:
      throw const FormatException('Unsupported plugin value');
  }
}

Object? _read(LuaState lua, int index, [int depth = 0]) {
  if (depth > 48) throw const FormatException('Value nesting too deep');
  final idx = lua.absIndex(index);
  switch (lua.type(idx)) {
    case LuaType.luaNil:
      return null;
    case LuaType.luaBoolean:
      return lua.toBoolean(idx);
    case LuaType.luaNumber:
      return lua.isInteger(idx) ? lua.toInteger(idx) : lua.toNumber(idx);
    case LuaType.luaString:
      return lua.toStr(idx);
    case LuaType.luaTable:
      final values = <Object, Object?>{};
      lua.pushNil();
      while (lua.next(idx)) {
        final key = _read(lua, -2, depth + 1);
        if (key is! String && key is! int) {
          throw const FormatException('Invalid table key');
        }
        values[key!] = _read(lua, -1, depth + 1);
        lua.pop(1);
        if (values.length > 100000) {
          throw const FormatException('Table too large');
        }
      }
      if (values.isNotEmpty &&
          values.keys.every(
            (key) => key is int && key >= 1 && key <= values.length,
          )) {
        return [for (var i = 1; i <= values.length; i++) values[i]];
      }
      return {
        for (final entry in values.entries) entry.key.toString(): entry.value,
      };
    default:
      throw const FormatException('Only data can cross the plugin boundary');
  }
}
