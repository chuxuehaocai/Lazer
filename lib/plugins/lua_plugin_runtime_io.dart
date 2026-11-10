// i18n:data — runtime error messages are interface keys shown by the plugin UI
// through `context.tr`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;
import 'package:lua_dardo_plus/lua.dart';
import 'package:path/path.dart' as p;

import 'plugin_manifest.dart';

/// Each VM has its own isolate, session, serial call queue and time budget.
/// No executable, dynamic library, JIT or platform-specific Lua installation.
class LuaPluginRuntime {
  LuaPluginRuntime({
    required this.manifest,
    required this.sources,
    required this.dataDirectory,
    this.timeout = const Duration(seconds: 40),
    this.httpHandler,
  });
  final PluginManifest manifest;
  final Map<String, String> sources;
  final String dataDirectory;
  final Duration timeout;

  /// Optional transport for deterministic HTTP integration tests. The worker
  /// still validates every URL against the manifest before reaching it.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  httpHandler;
  Isolate? _isolate;
  ReceivePort? _port;
  SendPort? _commands;
  Future<void>? _starting;
  Future<void> _calls = Future.value();
  final Map<int, Completer<Object?>> _pending = {};
  int _serial = 0;

  /// Whether the current VM is unusable. Cleared by [_reset], which is how a
  /// timed-out VM comes back: a slow operation used to kill the plugin for the
  /// rest of the session, so one hiccup meant every later stream, lyric and
  /// cover request failed with "插件已停止".
  bool _closed = false;

  /// Whether the plugin was shut down on purpose (disabled, removed, or built
  /// from sources that cannot start). A reset never sets this.
  bool _disposed = false;

  Future<void> start() {
    if (_disposed) {
      return Future<void>.error(const PluginException('插件已停止，请重新启用。'));
    }
    return _starting ??= _start();
  }

  Future<void> _start() async {
    if (_disposed) throw const PluginException('插件已停止。');
    final ready = Completer<void>();
    final port = _port = ReceivePort();
    port.listen((dynamic message) async {
      if (message is SendPort) {
        _commands = message;
        if (!ready.isCompleted) ready.complete();
      } else if (message is Map && message['hostHttp'] is Map) {
        final reply = message['reply'] as SendPort;
        try {
          final value = await httpHandler!(
            Map<String, dynamic>.from(message['hostHttp'] as Map),
          );
          reply.send({'value': value});
        } catch (_) {
          reply.send({'error': true});
        }
      } else if (message is Map && message['startupError'] != null) {
        if (!ready.isCompleted) {
          ready.completeError(const PluginException('插件启动失败，请检查 Lua 源码。'));
        }
        close();
      } else if (message is Map) {
        final waiter = _pending.remove(message['id']);
        if (message['error'] == true) {
          waiter?.completeError(
            PluginException(
              message['detail'] as String? ?? '插件请求失败。',
              code: message['code'] as int?,
            ),
          );
        } else {
          waiter?.complete(message['value']);
        }
      } else {
        if (!ready.isCompleted) {
          ready.completeError(const PluginException('插件启动失败。'));
        }
        close();
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _runPlugin,
        {
          'port': port.sendPort,
          'manifest': manifest.toJson(),
          'sources': sources,
          'data': dataDirectory,
          'externalHttp': httpHandler != null,
        },
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (_disposed || !identical(_port, port)) {
        // A reset or a close replaced this VM while it was spawning.
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
      await ready.future.timeout(timeout);
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Runs one plugin operation on the serialized VM queue.
  ///
  /// [budget] overrides the plugin-wide timeout for this call. The queue is
  /// shared by everything the plugin does for the app, so a slow non-essential
  /// call (a scrobble upload, a lyric fetch) must be bounded more tightly than a
  /// track resolve — otherwise it holds the lane every later resolve needs.
  Future<Object?> invoke(
    String operation, [
    Map<String, dynamic> args = const {},
    Duration? budget,
  ]) {
    final result = Completer<Object?>();
    _calls = _calls.then((_) async {
      try {
        result.complete(await _invoke(operation, args, budget));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<Object?> _invoke(
    String operation,
    Map<String, dynamic> args,
    Duration? budget,
  ) async {
    await start();
    if (_closed) throw const PluginException('插件已停止，请重新启用。');
    final id = ++_serial;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands!.send({'id': id, 'operation': operation, 'args': args});
    try {
      return await result.future.timeout(budget ?? timeout);
    } on TimeoutException {
      // The VM is unresponsive, not gone: drop the isolate and let the next call
      // start a fresh one. The answer to this call is gone, so it reports the
      // timeout and the caller may repeat it once against the new VM.
      _pending.remove(id);
      _reset();
      throw const PluginException(
        '插件响应超时，已自动重启插件。',
        code: PluginException.timeoutCode,
      );
    }
  }

  /// Shuts the plugin down for good. Used when it is disabled, removed, or its
  /// sources cannot start at all.
  void close() {
    if (_disposed) return;
    _disposed = true;
    _teardown();
  }

  /// Discards the current VM but keeps the plugin usable: the next call starts a
  /// fresh isolate. Loaded state (login cookies, storage) lives in the plugin's
  /// own files, so a restart does not log the user out.
  void _reset() {
    _teardown();
    _closed = false;
  }

  void _teardown() {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
    _commands = null;
    _starting = null;
    for (final pending in _pending.values) {
      pending.completeError(const PluginException('插件已停止。'));
    }
    _pending.clear();
  }
}

Future<void> _runPlugin(Map<String, dynamic> config) async {
  final output = config['port'] as SendPort;
  final commands = ReceivePort();
  final host = _PluginHost(
    PluginManifest.fromJson(config['manifest'] as Map<String, dynamic>),
    Map<String, String>.from(config['sources'] as Map),
    config['data'] as String,
    externalHttp: config['externalHttp'] == true
        ? (spec) async {
            final reply = ReceivePort();
            try {
              output.send({'hostHttp': spec, 'reply': reply.sendPort});
              final response = await reply.first as Map;
              if (response['error'] == true) {
                throw const PluginException('插件网络请求失败。');
              }
              return Map<String, dynamic>.from(response['value'] as Map);
            } finally {
              reply.close();
            }
          }
        : null,
  );
  try {
    await host.initialize();
    output.send(commands.sendPort);
  } catch (error) {
    output.send({'startupError': '$error'});
    commands.close();
    return;
  }
  Future<void> tail = Future.value();
  commands.listen((dynamic request) {
    if (request is! Map) return;
    tail = tail.then((_) async {
      try {
        final value = await host.invoke(
          request['operation'] as String,
          request['args'],
        );
        if (value is Map && value['__error'] is Map) {
          output.send({
            'id': request['id'],
            'error': true,
            'code': value['__error']['code'],
          });
        } else {
          output.send({'id': request['id'], 'value': value});
        }
      } catch (error) {
        // Interpreter errors can include the whole Lua chunk or an upstream
        // body. Neither is safe to expose through app logs or the login UI.
        final code = RegExp(
          r'(?:Gateway code|HTTP) (\d{3,6})',
        ).allMatches('$error').lastOrNull?.group(1);
        output.send({
          'id': request['id'],
          'error': true,
          'detail': '插件请求失败，请重试或更新插件。',
          'code': int.tryParse(code ?? ''),
        });
      }
    });
  });
}

class _PluginHost {
  _PluginHost(this.manifest, this.sources, this.dataPath, {this.externalHttp});
  final PluginManifest manifest;
  final Map<String, String> sources;
  final String dataPath;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  externalHttp;
  final LuaState lua = LuaState.newState();
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  final Random random = Random.secure();
  Map<String, dynamic> storage = {};

  Future<void> initialize() async {
    if (manifest.storage) {
      final file = File(p.join(dataPath, 'storage.json'));
      if (await file.exists() && await file.length() <= 1024 * 1024) {
        try {
          storage =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    lua.openLibs();
    // Remove all standard filesystem/process/module escape routes.
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
    void sync(String name, Object? Function(LuaState) fn) =>
        lua.register(name, (l) {
          final value = fn(l);
          _push(l, value);
          return 1;
        });
    sync('_json_encode', (l) => jsonEncode(_read(l, 1)));
    sync('_json_decode', (l) => jsonDecode(l.checkString(1)!));
    sync('_now', (_) => DateTime.now().millisecondsSinceEpoch);
    sync('_url_encode', (l) => Uri.encodeComponent(l.checkString(1)!));
    sync('_cookie_compact', (l) => _compactCookie(l.checkString(1)!));
    sync(
      '_cookie_field',
      (l) => _cookieField(l.checkString(1)!, l.checkString(2)!),
    );
    sync('_cookie_merge', (l) {
      final previous = l.isNoneOrNil(1) ? '' : l.checkString(1)!;
      final updates = l.isNoneOrNil(2) ? '' : l.checkString(2)!;
      final fields = updates
          .split('\n')
          .map((line) => line.split(';').first)
          .join('; ');
      return _compactCookie('$previous; $fields');
    });
    sync('_random_hex', (l) {
      final count = l.checkInteger(1) ?? 16;
      if (count < 1 || count > 1024) throw const FormatException();
      return List.generate(
        count,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    });
    sync(
      '_crypto',
      (l) => _crypt(Map<String, dynamic>.from(_read(l, 1) as Map)),
    );
    sync('_module_source', (l) {
      final name = l.checkString(1)!;
      final path = '${name.replaceAll('.', '/')}.lua';
      if (!PluginManifest.safePath(path) || !sources.containsKey(path)) {
        throw const FormatException('Unknown module');
      }
      return sources[path];
    });
    sync(
      '_storage_get',
      (l) => manifest.storage ? storage[l.checkString(1)] : null,
    );
    sync('_storage_set', (l) {
      if (!manifest.storage) {
        throw const FormatException('Storage permission required');
      }
      final key = l.checkString(1)!;
      final value = _read(l, 2);
      final next = {...storage};
      value == null ? next.remove(key) : next[key] = value;
      final encoded = jsonEncode(next);
      if (utf8.encode(encoded).length > 1024 * 1024) {
        throw const FormatException('Storage full');
      }
      final directory = Directory(dataPath)..createSync(recursive: true);
      final temp = File(p.join(directory.path, 'storage.tmp'));
      temp.writeAsStringSync(encoded, flush: true);
      final target = File(p.join(directory.path, 'storage.json'));
      if (target.existsSync()) target.deleteSync();
      temp.renameSync(target.path);
      storage = next;
      return null;
    });
    lua.registerAsync('_http', (l) async {
      final spec = Map<String, dynamic>.from(_read(l, 1) as Map);
      final result = await _http(spec).timeout(const Duration(seconds: 30));
      _push(l, result);
      return 1;
    });
    lua.registerAsync('pcall', (l) async {
      final status = await l.pCallAsync(l.getTop() - 1, luaMultret, 0);
      l.pushBoolean(status == ThreadStatus.luaOk);
      l.insert(1);
      return l.getTop();
    });
    final moduleBuffers = StringBuffer();
    moduleBuffers.writeln('local module_loaders = {}');
    for (final entry in sources.entries.where(
      (entry) => entry.key != manifest.entry,
    )) {
      final moduleName = entry.key
          .substring(0, entry.key.length - 4)
          .replaceAll('/', '.');
      moduleBuffers.writeln(
        'module_loaders[${jsonEncode(moduleName)}] = function()',
      );
      moduleBuffers.writeln(entry.value);
      moduleBuffers.writeln('end');
    }
    final bootstrap =
        '''
host = { json_encode = _json_encode, json_decode = _json_decode,
  now = _now, url_encode = _url_encode, random_hex = _random_hex,
  cookie_compact = _cookie_compact, cookie_field = _cookie_field,
  cookie_merge = _cookie_merge,
  crypto = _crypto, http = _http, storage_get = _storage_get, storage_set = _storage_set }
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
    lua.setTop(0);
    try {
      lua.getGlobal('_plugin');
      lua.getField(-1, 'call');
      lua.remove(-2);
      if (!lua.isFunction(-1)) throw const PluginException('插件缺少 call 入口。');
      lua.pushString(operation);
      _push(lua, args);
      await lua.callAsync(2, 1);
      return _read(lua, -1);
    } finally {
      lua.setTop(0);
    }
  }

  Future<Map<String, dynamic>> _http(Map<String, dynamic> spec) async {
    final uri = Uri.parse(spec['url'] as String);
    if (!manifest.permits(uri)) {
      throw const FormatException('Network permission denied');
    }
    if (externalHttp != null) return externalHttp!(spec);
    final method = (spec['method'] as String? ?? 'GET').toUpperCase();
    if (!{'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'}.contains(method)) {
      throw const FormatException('Unsupported HTTP method');
    }
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    final headers = spec['headers'];
    if (headers is Map) {
      for (final entry in headers.entries) {
        if ([
          'host',
          'content-length',
          'connection',
        ].contains(entry.key.toString().toLowerCase())) {
          continue;
        }
        request.headers.set(entry.key.toString(), entry.value.toString());
      }
    }
    final body = spec['body'] as String?;
    if (body != null) {
      if (utf8.encode(body).length > 2 * 1024 * 1024) {
        throw const FormatException('Request too large');
      }
      request.add(utf8.encode(body));
    }
    final response = await request.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw const FormatException('Response too large');
      }
      bytes.add(chunk);
    }
    final responseHeaders = <String, dynamic>{};
    response.headers.forEach(
      (name, values) => responseHeaders[name] = values.join('\n'),
    );
    return {
      'status': response.statusCode,
      'headers': responseHeaders,
      'body': utf8.decode(bytes.takeBytes(), allowMalformed: true),
    };
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
        final value = BigInt.parse(hex, radix: 16);
        return value
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

  /// AES-CBC/ECB with PKCS7, the two modes the Lua `crypto` helper exposes.
  /// This used to come from the `encrypt` package; pointycastle is the engine
  /// underneath it and is already in the tree for the network clients.
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
        ? pc.PaddedBlockCipherParameters<pc.CipherParameters,
              pc.CipherParameters>(pc.KeyParameter(Uint8List.fromList(key)), null)
        : pc.PaddedBlockCipherParameters<pc.CipherParameters,
              pc.CipherParameters>(
            pc.ParametersWithIV(
              pc.KeyParameter(Uint8List.fromList(key)),
              Uint8List.fromList(iv),
            ),
            null,
          );
    cipher.init(encrypt, parameters);
    return cipher.process(input);
  }

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
