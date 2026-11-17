// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
// i18n:data — runtime error messages are interface keys shown by the plugin UI
// through `context.tr`.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:html' as html;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:lua_dardo_plus/lua.dart';
import 'package:pointycastle/export.dart' as pc;

import 'plugin_manifest.dart';
import 'plugin_event_scheduler.dart';
import 'plugin_data_access.dart' show pluginFrontendLua;
import 'plugin_socket_inbox.dart';
import 'lua_console_evaluator.dart';
import '../diagnostics/app_log.dart';
import '../utils/system_http.dart';

const _pluginFileMaxBytes = 4 * 1024 * 1024;
const _pluginFilesMaxBytes = 16 * 1024 * 1024;
const _pluginFilesMaxEntries = 2048;

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
    this.resources = const <String, String>{},
    required this.dataDirectory,
    this.timeout = const Duration(seconds: 40),
    this.httpHandler,
    bool? networkGranted,
    this.socketGranted = false,
    this.socketServerGranted = false,
    this.websocketGranted = false,
    this.websocketServerGranted = false,
    this.filesystemGranted = false,
    this.permissionRequester,
    this.onSettingAdded,
    this.onPlayerMenuItemAdded,
    this.onPageAdded,
    this.onPageEdited,
    this.onPlayerControl,
    this.onLog,
  }) : networkGranted = networkGranted ?? false;

  final PluginManifest manifest;
  final Map<String, String> sources;

  /// Read-only text files shipped in the plugin package.
  final Map<String, String> resources;
  final String dataDirectory;
  final Duration timeout;

  /// Optional transport for deterministic HTTP integration tests. The
  /// presence of this callback does not grant network permission.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  httpHandler;
  final bool networkGranted;
  final bool socketGranted;
  final bool socketServerGranted;
  final bool websocketGranted;
  final bool websocketServerGranted;
  final bool filesystemGranted;
  final Future<bool> Function(String permission)? permissionRequester;
  final Future<Object?> Function(Map<String, dynamic> spec)? onSettingAdded;
  final Future<Object?> Function(Map<String, dynamic> spec)?
  onPlayerMenuItemAdded;
  final Future<Object?> Function(Map<String, dynamic> spec)? onPageAdded;
  final Future<Object?> Function(Map<String, dynamic> spec)? onPageEdited;
  final Future<Object?> Function(Map<String, dynamic> spec)? onPlayerControl;
  final void Function(Map<String, dynamic> record)? onLog;
  late final _scheduler = PluginEventScheduler(
    (event, args) => _queueInvocation(event, args),
  );

  final Random _random = Random.secure();
  final http.Client _client = http.Client();
  Future<void>? _starting;
  Future<void> _calls = Future<void>.value();
  LuaState? _lua;
  _WebPluginHost? _host;
  bool _closed = false;
  bool get acceptsCalls => !_closed;
  int sessionRevision = 0;

  Future<void> start() => _starting ??= _start();

  void updateProxy({required ProxyMode mode, String? endpoint}) {}

  Future<void> _start() async {
    if (_closed) throw const PluginException('插件已停止。');
    AppLog.shared.event('lua', 'starting', {'plugin': manifest.id});
    final host = _WebPluginHost(
      manifest,
      sources,
      resources,
      dataDirectory,
      random: _random,
      client: _client,
      externalHttp: httpHandler,
      networkGranted: networkGranted,
      socketGranted: socketGranted,
      socketServerGranted: socketServerGranted,
      websocketGranted: websocketGranted,
      websocketServerGranted: websocketServerGranted,
      filesystemGranted: filesystemGranted,
      permissionRequester: permissionRequester,
      onLog: onLog,
      uiExtensions: (kind, spec) async {
        if (_closed) throw const FormatException('Plugin is closed');
        // Resolve async branches here before the mixed sync/async switch is
        // widened to Object?. The Web compiler can otherwise pass a Future
        // through to the Lua value converter and release the VM lane early.
        return switch (kind) {
          'timer' => _scheduler.configure(spec),
          'setting' =>
            onSettingAdded == null
                ? throw const FormatException('Plugin settings are unavailable')
                : await onSettingAdded!(spec),
          'playerMenu' =>
            onPlayerMenuItemAdded == null
                ? throw const FormatException(
                    'Plugin player menu is unavailable',
                  )
                : await onPlayerMenuItemAdded!(spec),
          'page' =>
            onPageAdded == null
                ? throw const FormatException('Plugin pages are unavailable')
                : await onPageAdded!(spec),
          'pageEdit' =>
            onPageEdited == null
                ? throw const FormatException('Plugin pages are unavailable')
                : await onPageEdited!(spec),
          'playerControl' =>
            onPlayerControl == null
                ? throw const FormatException('Player control is unavailable')
                : await onPlayerControl!(spec),
          _ => throw const FormatException('Unknown plugin extension'),
        };
      },
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
    return _queueInvocation(operation, args).timeout(budget ?? timeout);
  }

  // Timer backpressure tracks the actual VM work. A caller-facing timeout does
  // not settle a suspended permission prompt and must not release this slot.
  Future<Object?> _queueInvocation(
    String operation,
    Map<String, dynamic> args,
  ) {
    final result = Completer<Object?>();
    _calls = _calls.then((_) async {
      final clock = Stopwatch()..start();
      if (operation != 'timer') {
        AppLog.shared.event('lua', 'call', {
          'plugin': manifest.id,
          'operation': operation,
        });
      }
      try {
        await start();
        if (_closed) throw const PluginException('插件已停止，请重新启用。');
        result.complete(await _host!.invoke(operation, args));
        if (operation != 'timer') {
          AppLog.shared.event('lua', 'completed', {
            'plugin': manifest.id,
            'operation': operation,
            'elapsed_ms': clock.elapsedMilliseconds,
          });
        }
      } catch (error, stack) {
        AppLog.shared.event('lua', 'failed', {
          'plugin': manifest.id,
          'operation': operation,
        });
        result.completeError(error, stack);
      }
    });
    return result.future;
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

  /// Completes once the runtime holds no worker or listener.
  ///
  /// The native implementation waits for its isolate to release the listen
  /// ports; the browser build has nothing to release, so this is immediate.
  Future<void> get settled => Future<void>.value();

  Future<void> shutdown() async {
    close();
  }

  void close() {
    if (_closed) return;
    sessionRevision++;
    _closed = true;
    _scheduler.cancelAll();
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
    this.resources,
    this.dataKey, {
    required this.random,
    required this.client,
    this.externalHttp,
    this.networkGranted = false,
    this.socketGranted = false,
    this.socketServerGranted = false,
    this.websocketGranted = false,
    this.websocketServerGranted = false,
    this.filesystemGranted = false,
    this.permissionRequester,
    this.onLog,
    this.uiExtensions,
  });

  final PluginManifest manifest;
  final Map<String, String> sources;
  final Map<String, String> resources;
  final String dataKey;
  final Random random;
  final http.Client client;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  externalHttp;
  bool networkGranted;
  bool socketGranted, socketServerGranted;
  bool websocketGranted, websocketServerGranted;
  bool filesystemGranted;
  final Future<bool> Function(String permission)? permissionRequester;
  final void Function(Map<String, dynamic> record)? onLog;
  final Future<Object?> Function(String kind, Map<String, dynamic> spec)?
  uiExtensions;
  final ConsoleCapableLuaState lua = ConsoleCapableLuaState();
  Map<String, dynamic> storage = <String, dynamic>{};
  final Map<String, String> files = <String, String>{};
  final Set<String> directories = <String>{};
  final Map<String, html.WebSocket> _websockets = <String, html.WebSocket>{};

  final Map<String, PluginSocketInbox> _websocketInboxes = {};
  final Map<String, List<StreamSubscription<dynamic>>> _websocketSubscriptions =
      {};

  void _closeSocket(String id) {
    _websockets.remove(id)?.close();
    _websocketInboxes.remove(id)?.close(discard: true);
    for (final subscription
        in _websocketSubscriptions.remove(id) ??
            <StreamSubscription<dynamic>>[]) {
      unawaited(subscription.cancel());
    }
  }

  void closeSockets() {
    for (final id in _websockets.keys.toList()) {
      _closeSocket(id);
    }
  }

  String get _cookieName =>
      'lazer_plugin_${base64Url.encode(utf8.encode(dataKey)).replaceAll('=', '')}';
  String get _localStorageKey => 'lazer.plugin.$dataKey';

  Future<void> initialize() async {
    _loadStorage();
    _loadFiles();
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
    sync('_url_decode', (state) => Uri.decodeComponent(state.checkString(1)!));
    sync('_host_info', (_) => _hostInfo());
    sync('_resource', (state) {
      final path = state.checkString(1)!;
      if (!PluginManifest.safePath(path)) {
        throw const FormatException('Invalid resource path');
      }
      return resources[path];
    });
    sync('_resource_keys', (_) => resources.keys.toList()..sort());
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
    sync(
      '_storage_keys',
      (_) =>
          manifest.storage ? (storage.keys.toList()..sort()) : const <String>[],
    );
    sync('_storage_set', (state) {
      if (!manifest.storage) {
        throw const FormatException('Storage permission required');
      }
      final key = state.checkString(1)!;
      final value = _read(state, 2);
      final next = <String, dynamic>{...storage};
      value == null ? next.remove(key) : next[key] = value;
      _saveStorage(next);
      return null;
    });
    sync('_storage_clear', (_) {
      if (!manifest.storage) {
        throw const FormatException('Storage permission required');
      }
      _saveStorage(<String, dynamic>{});
      return null;
    });
    sync('_log', (state) {
      final level = (state.isNoneOrNil(1) ? 'info' : state.checkString(1)!)
          .toLowerCase();
      final message = state.isNoneOrNil(2) ? '' : '${_read(state, 2)}';
      final fields = <String, Object?>{
        'plugin': manifest.id,
        'message': message.length > 2048 ? message.substring(0, 2048) : message,
      };
      final data = state.isNoneOrNil(3) ? null : _read(state, 3);
      if (data is Map) fields['data'] = Map<String, dynamic>.from(data);
      if (onLog != null) {
        onLog!({
          'level': level,
          'message': fields['message'],
          if (fields['data'] != null) 'data': fields['data'],
        });
      } else {
        AppLog.shared.event('lua.plugin', level, fields);
      }
      return null;
    });
    lua.registerAsync('_add_setting', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Plugin settings are unavailable');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await uiExtensions!('setting', spec));
      return 1;
    });
    lua.registerAsync('_add_player_menu_item', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Plugin player menu is unavailable');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await uiExtensions!('playerMenu', spec) ?? true);
      return 1;
    });
    lua.registerAsync('_add_page', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Plugin pages are unavailable');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await uiExtensions!('page', spec) ?? true);
      return 1;
    });
    lua.registerAsync('_page_edit', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Plugin pages are unavailable');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await uiExtensions!('pageEdit', spec));
      return 1;
    });
    lua.registerAsync('_timer', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Plugin timers are unavailable');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await uiExtensions!('timer', spec));
      return 1;
    });
    lua.registerAsync('_player_control', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Player control is unavailable');
      }
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await uiExtensions!('playerControl', spec) ?? true);
      return 1;
    });
    lua.registerAsync('_player_state', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Player control is unavailable');
      }
      _push(
        state,
        await uiExtensions!('playerControl', {'command': 'status'}) ??
            const <String, dynamic>{},
      );
      return 1;
    });
    lua.registerAsync('_player_queue', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Player control is unavailable');
      }
      _push(
        state,
        await uiExtensions!('playerControl', {'command': 'queue'}) ??
            const <String, dynamic>{},
      );
      return 1;
    });
    lua.registerAsync('_player_track', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Player control is unavailable');
      }
      _push(state, await uiExtensions!('playerControl', {'command': 'track'}));
      return 1;
    });
    lua.registerAsync('_player_lyrics', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Player control is unavailable');
      }
      _push(
        state,
        await uiExtensions!('playerControl', {'command': 'lyrics'}) ??
            const <String, dynamic>{},
      );
      return 1;
    });
    lua.registerAsync('_player_recent', (state) async {
      if (uiExtensions == null) {
        throw const FormatException('Player control is unavailable');
      }
      _push(
        state,
        await uiExtensions!('playerControl', {'command': 'recent'}) ??
            const <Object?>[],
      );
      return 1;
    });
    lua.registerAsync('_sleep', (state) async {
      final requested = state.checkInteger(1) ?? 0;
      final milliseconds = requested.clamp(0, 60000);
      await Future<void>.delayed(Duration(milliseconds: milliseconds));
      _push(state, true);
      return 1;
    });
    lua.registerAsync('_file', (state) async {
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      _push(state, await _file(spec));
      return 1;
    });
    lua.registerAsync('_http', (state) async {
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      final result = await _http(spec).timeout(const Duration(seconds: 30));
      _push(state, result);
      return 1;
    });
    lua.registerAsync('_http_json', (state) async {
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      final result = await _http(spec).timeout(const Duration(seconds: 30));
      final body = result['body'];
      _push(state, body is String && body.isNotEmpty ? jsonDecode(body) : null);
      return 1;
    });
    lua.registerAsync('_websocket', (state) async {
      final spec = Map<String, dynamic>.from(_read(state, 1) as Map);
      final operation = spec['operation'] as String? ?? 'open';
      final id = spec['id'] as String? ?? 'default';
      if (operation == 'open') {
        final uri = Uri.parse(spec['url'] as String);
        if (!manifest.permitsWebSocket(uri)) {
          throw const FormatException('WebSocket permission denied');
        }
        if (!websocketGranted) {
          if (permissionRequester != null &&
              await permissionRequester!('websocket')) {
            websocketGranted = true;
          } else {
            throw const FormatException('WebSocket permission required');
          }
        }
        if (!_websockets.containsKey(id) && _websockets.length >= 16) {
          throw const FormatException('Too many WebSocket connections');
        }
        _closeSocket(id);
        final socket = html.WebSocket(uri.toString())
          ..binaryType = 'arraybuffer';
        final inbox = PluginSocketInbox();
        _websockets[id] = socket;
        _websocketInboxes[id] = inbox;
        final opened = Completer<void>();
        _websocketSubscriptions[id] = [
          socket.onOpen.listen((_) {
            if (!opened.isCompleted) opened.complete();
          }),
          socket.onMessage.listen((event) {
            final data = event.data;
            final value = data is ByteBuffer ? data.asUint8List() : data;
            if (value != null && !inbox.add(value)) {
              socket.close(1009);
              inbox.close(discard: true);
            }
          }),
          socket.onError.listen((_) {
            inbox.close();
            if (!opened.isCompleted) {
              opened.completeError(
                const FormatException('WebSocket connection failed'),
              );
            }
          }),
          socket.onClose.listen((_) {
            inbox.close();
            if (!opened.isCompleted) {
              opened.completeError(
                const FormatException('WebSocket connection closed'),
              );
            }
          }),
        ];
        try {
          await opened.future.timeout(const Duration(seconds: 20));
        } catch (_) {
          _closeSocket(id);
          rethrow;
        }
        _push(state, true);
        return 1;
      }
      final socket = _websockets[id];
      if (socket == null) throw const FormatException('WebSocket is not open');
      if (operation == 'send') {
        final data = pluginSocketData(spec['data']);
        socket.send(data is List<int> ? Uint8List.fromList(data) : data);
        _push(state, true);
        return 1;
      }
      if (operation == 'receive') {
        _push(
          state,
          await _websocketInboxes[id]!.receive(pluginSocketTimeout(spec)),
        );
        return 1;
      }
      if (operation == 'close') {
        _closeSocket(id);
        _push(state, true);
        return 1;
      }
      throw const FormatException('Unsupported WebSocket operation');
    });
    lua.register('_websocket_server', (state) {
      throw const FormatException(
        'WebSocket servers are unavailable in a browser',
      );
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
      local function page_edit(operation, spec)
        local request = {}
        if type(spec) == "table" then
          for key, value in pairs(spec) do request[key] = value end
        elseif spec ~= nil then
          request.page = spec
        end
        request.operation = operation
        return _page_edit(request)
      end
      host = { json_encode = _json_encode, json_decode = _json_decode,
        now = _now, url_encode = _url_encode, url_decode = _url_decode,
        info = _host_info, plugin_info = _host_info, resource = _resource,
        resource_keys = _resource_keys,
        read_resource = _resource, log = _log, random_hex = _random_hex,
        cookie_compact = _cookie_compact, cookie_field = _cookie_field,
        cookie_merge = _cookie_merge, crypto = _crypto, http = _http,
        http_json = _http_json,
        websocket = _websocket, websocket_server = _websocket_server,
        storage_get = _storage_get, storage_set = _storage_set,
        storage_keys = _storage_keys, storage_clear = _storage_clear,
        add_setting = _add_setting, add_player_menu_item = _add_player_menu_item,
        add_page = _add_page,
        page = function(id) return page_edit("get", id) end,
        pages = function() return page_edit("list", nil) end,
        update_page = function(spec) return page_edit("update", spec) end,
        set_page_elements = function(spec)
          return page_edit("set_elements", spec)
        end,
        add_page_element = function(spec)
          return page_edit("add_element", spec)
        end,
        update_page_element = function(spec)
          return page_edit("update_element", spec)
        end,
        remove_page_element = function(spec)
          return page_edit("remove_element", spec)
        end,
        move_page_element = function(spec)
          return page_edit("move_element", spec)
        end,
        timer = _timer, player_control = _player_control, player_state = _player_state,
        player_status = _player_state, player_queue = _player_queue,
        player_track = _player_track, now_playing = _player_track,
        player_lyrics = _player_lyrics, player_recent = _player_recent,
        file = _file, files = _file, sleep = _sleep }
      $pluginFrontendLua
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

  Map<String, dynamic> _hostInfo() => {
    'runtime': 'web',
    'plugin': manifest.id,
    'name': manifest.name,
    'version': manifest.version,
    'apiVersion': manifest.apiVersion,
    'provider': manifest.provider,
    'capabilities': List<String>.of(manifest.capabilities),
    'auth': List<String>.of(manifest.auth),
    'permissions': {
      'network': List<String>.of(manifest.domains),
      'socket': List<String>.of(manifest.socketDomains),
      'socketServer': List<String>.of(manifest.socketServerBindings),
      'websocket': List<String>.of(manifest.websocketDomains),
      'websocketServer': List<String>.of(manifest.websocketServerBindings),
      'data': manifest.dataPermissions,
      'storage': manifest.storage,
      'filesystem': manifest.filesystem,
    },
    'features': [
      'http',
      'crypto',
      'storage',
      'resources',
      'player',
      'player_lyrics',
      'player_recent',
      'frontend_library',
      'frontend_user',
      'data_permissions',
      'websocket',
      'sleep',
      'pages',
      'page_edit',
      'timer',
      'filesystem',
    ],
  };

  Future<Map<String, dynamic>> _http(Map<String, dynamic> spec) async {
    final uri = Uri.parse(spec['url'] as String);
    if (!manifest.permits(uri)) {
      throw const FormatException('Network permission denied');
    }
    if (!networkGranted) {
      if (permissionRequester != null &&
          await permissionRequester!('network')) {
        networkGranted = true;
      } else {
        throw const FormatException('Network permission required');
      }
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

  void _saveStorage([Map<String, dynamic>? next]) {
    if (!manifest.storage) return;
    if (next != null) storage = next;
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

  String get _filesStorageKey => 'lazer.plugin.files.$dataKey';

  void _loadFiles() {
    if (!manifest.filesystem) return;
    final value = html.window.localStorage[_filesStorageKey];
    if (value == null || value.isEmpty) return;
    try {
      final decoded =
          jsonDecode(utf8.decode(base64Url.decode(value)))
              as Map<dynamic, dynamic>;
      final rawFiles = decoded['files'] is Map
          ? decoded['files'] as Map
          : decoded;
      for (final entry in rawFiles.entries) {
        final path = entry.key.toString();
        if (!PluginManifest.safePath(path) || entry.value is! String) continue;
        final bytes = base64Url.decode(entry.value as String);
        if (bytes.length <= _pluginFileMaxBytes) {
          files[path] = entry.value as String;
        }
      }
      final rawDirectories = decoded['directories'];
      if (rawDirectories is List) {
        directories.addAll(
          rawDirectories.whereType<String>().where(
            (path) => PluginManifest.safePath(path),
          ),
        );
      }
    } catch (_) {
      files.clear();
      directories.clear();
    }
  }

  void _saveFiles() {
    if (!manifest.filesystem) return;
    try {
      final value = base64Url.encode(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'files': files,
            'directories': directories.toList()..sort(),
          }),
        ),
      );
      if (value.length > (_pluginFilesMaxBytes * 2)) {
        throw const FormatException('Filesystem storage full');
      }
      html.window.localStorage[_filesStorageKey] = value;
    } catch (error) {
      if (error is FormatException) rethrow;
      throw const FormatException('Filesystem storage unavailable');
    }
  }

  Future<Object?> _file(Map<String, dynamic> spec) async {
    if (!manifest.filesystem) {
      throw const FormatException('Filesystem permission required');
    }
    if (!filesystemGranted) {
      if (permissionRequester != null &&
          await permissionRequester!('filesystem')) {
        filesystemGranted = true;
      } else {
        throw const FormatException('Filesystem permission required');
      }
    }
    final operation = (spec['operation'] as String? ?? 'read')
        .toLowerCase()
        .trim();
    final pathValue = spec['path'] as String? ?? '';
    final path = _filePath(pathValue, allowRoot: operation == 'list');
    switch (operation) {
      case 'exists':
        return files.containsKey(path) || _directorySet().contains(path);
      case 'stat':
        return _fileStat(path);
      case 'list':
        return _fileList(path);
      case 'read':
        return _fileRead(path, spec['encoding'] as String?);
      case 'write':
      case 'append':
        if (path.isEmpty) throw const FormatException('File path required');
        final oldFiles = Map<String, String>.of(files);
        final oldDirectories = Set<String>.of(directories);
        try {
          final result = _fileWrite(
            path,
            spec['data'],
            encoding: spec['encoding'] as String?,
            append: operation == 'append',
          );
          _saveFiles();
          return result;
        } catch (_) {
          files
            ..clear()
            ..addAll(oldFiles);
          directories
            ..clear()
            ..addAll(oldDirectories);
          rethrow;
        }
      case 'mkdir':
        if (path.isEmpty) {
          throw const FormatException('Directory path required');
        }
        final oldDirectories = Set<String>.of(directories);
        try {
          _addDirectory(path);
          _saveFiles();
          return true;
        } catch (_) {
          directories
            ..clear()
            ..addAll(oldDirectories);
          rethrow;
        }
      case 'delete':
        if (path.isEmpty) throw const FormatException('File path required');
        final oldFiles = Map<String, String>.of(files);
        final oldDirectories = Set<String>.of(directories);
        try {
          final removed = _fileDelete(
            path,
            recursive: spec['recursive'] == true,
          );
          if (removed) _saveFiles();
          return removed;
        } catch (_) {
          files
            ..clear()
            ..addAll(oldFiles);
          directories
            ..clear()
            ..addAll(oldDirectories);
          rethrow;
        }
      default:
        throw FormatException('Unsupported file operation: $operation');
    }
  }

  String _filePath(String value, {required bool allowRoot}) {
    if (value.isEmpty && allowRoot) return '';
    if (!PluginManifest.safePath(value)) {
      throw const FormatException('Invalid file path');
    }
    return value;
  }

  Map<String, dynamic>? _fileStat(String path) {
    final encoded = files[path];
    if (encoded != null) {
      return {
        'path': path,
        'type': 'file',
        'size': base64Url.decode(encoded).length,
        'modifiedMs': 0,
      };
    }
    if (_directorySet().contains(path)) {
      return {'path': path, 'type': 'directory', 'size': 0, 'modifiedMs': 0};
    }
    return null;
  }

  List<Map<String, dynamic>> _fileList(String path) {
    if (files.containsKey(path)) {
      throw const FormatException('Not a directory');
    }
    if (path.isNotEmpty && !_directorySet().contains(path)) {
      throw const FormatException('Directory not found');
    }
    final prefix = path.isEmpty ? '' : '$path/';
    final entries = <String, Map<String, dynamic>>{};
    for (final directory in _directorySet()) {
      if (!directory.startsWith(prefix) || directory == path) continue;
      final rest = directory.substring(prefix.length);
      final name = rest.split('/').first;
      final entryPath = '$prefix$name';
      entries[entryPath] = {
        'name': name,
        'path': entryPath,
        'type': 'directory',
      };
    }
    for (final file in files.keys) {
      if (!file.startsWith(prefix)) continue;
      final rest = file.substring(prefix.length);
      final name = rest.split('/').first;
      final entryPath = '$prefix$name';
      if (rest.contains('/')) {
        entries[entryPath] = {
          'name': name,
          'path': entryPath,
          'type': 'directory',
        };
      } else {
        entries[entryPath] = {
          'name': name,
          'path': entryPath,
          'type': 'file',
          'size': base64Url.decode(files[file]!).length,
        };
      }
    }
    final result = entries.values.toList()
      ..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    if (result.length > _pluginFilesMaxEntries) {
      throw const FormatException('Too many files');
    }
    return result;
  }

  Object _fileRead(String path, String? encoding) {
    final encoded = files[path];
    if (encoded == null) throw const FormatException('File not found');
    final bytes = base64Url.decode(encoded);
    if (bytes.length > _pluginFileMaxBytes) {
      throw const FormatException('File too large');
    }
    if (encoding == 'binary') return bytes;
    if (encoding == 'base64') return base64Encode(bytes);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Map<String, dynamic> _fileWrite(
    String path,
    Object? value, {
    String? encoding,
    required bool append,
  }) {
    final bytes = _fileBytes(value, encoding);
    final oldBytes = files[path] == null
        ? const <int>[]
        : base64Url.decode(files[path]!);
    final next = append ? <int>[...oldBytes, ...bytes] : <int>[...bytes];
    if (next.length > _pluginFileMaxBytes ||
        _fileUsage() - oldBytes.length + next.length > _pluginFilesMaxBytes) {
      throw const FormatException('Filesystem storage full');
    }
    _addDirectory(
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '',
    );
    files[path] = base64Url.encode(next);
    return {'path': path, 'size': next.length};
  }

  List<int> _fileBytes(Object? value, String? encoding) {
    if (value is String) {
      if (encoding == 'base64') {
        try {
          return base64Decode(value);
        } catch (_) {
          throw const FormatException('Invalid base64 data');
        }
      }
      return utf8.encode(value);
    }
    if (value is List) {
      final bytes = <int>[];
      for (final item in value) {
        if (item is! num || item.toInt() < 0 || item.toInt() > 255) {
          throw const FormatException('Binary data must contain bytes');
        }
        bytes.add(item.toInt());
      }
      return bytes;
    }
    throw const FormatException('File data must be text or bytes');
  }

  int _fileUsage() => files.values.fold<int>(
    0,
    (total, value) => total + base64Url.decode(value).length,
  );

  bool _fileDelete(String path, {required bool recursive}) {
    if (files.remove(path) != null) return true;
    final prefix = '$path/';
    final hasChildren =
        files.keys.any((value) => value.startsWith(prefix)) ||
        directories.any((value) => value.startsWith(prefix));
    if (hasChildren && !recursive) {
      throw const FormatException('Directory is not empty');
    }
    final removed = directories.remove(path);
    files.removeWhere((value, _) => value.startsWith(prefix));
    directories.removeWhere((value) => value.startsWith(prefix));
    return removed || hasChildren;
  }

  Set<String> _directorySet() {
    final result = <String>{...directories};
    for (final file in files.keys) {
      final parts = file.split('/');
      for (var length = 1; length < parts.length; length++) {
        result.add(parts.take(length).join('/'));
      }
    }
    return result;
  }

  void _addDirectory(String path) {
    if (path.isEmpty) return;
    final parts = path.split('/');
    for (var length = 1; length <= parts.length; length++) {
      directories.add(parts.take(length).join('/'));
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
      case 'sha1':
        return crypto.sha1.convert(utf8.encode(input)).toString();
      case 'hmac':
        final key = utf8.encode(spec['key'] as String? ?? '');
        final algorithm = (spec['algorithm'] as String? ?? 'sha256')
            .toLowerCase();
        final hashAlgorithm = switch (algorithm) {
          'sha1' => crypto.sha1,
          'md5' => crypto.md5,
          _ => crypto.sha256,
        };
        return crypto.Hmac(
          hashAlgorithm,
          key,
        ).convert(utf8.encode(input)).toString();
      case 'xor':
        final raw = spec['encoding'] == 'hex'
            ? Uint8List.fromList([
                for (var i = 0; i < input.length; i += 2)
                  int.parse(input.substring(i, i + 2), radix: 16),
              ])
            : base64Decode(input);
        final keyBytes = spec['key'] is List
            ? List<int>.from(spec['key'] as List)
            : utf8.encode(spec['key'] as String? ?? '');
        if (keyBytes.isEmpty) return input;
        final output = Uint8List(raw.length);
        for (var i = 0; i < raw.length; i++) {
          output[i] = raw[i] ^ keyBytes[i % keyBytes.length];
        }
        return spec['outputEncoding'] == 'hex'
            ? output.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
            : (spec['outputEncoding'] == 'utf8'
                  ? utf8.decode(output, allowMalformed: true)
                  : base64Encode(output));
      case 'zlib_inflate':
        try {
          final raw = base64Decode(input);
          return utf8.decode(
            ZLibDecoder().decodeBytes(raw),
            allowMalformed: true,
          );
        } catch (_) {
          return '';
        }
      case 'zlib_deflate':
        try {
          return base64Encode(ZLibEncoder().encode(utf8.encode(input)));
        } catch (_) {
          return '';
        }
      case 'krc_decode':
        try {
          final raw = base64Decode(input);
          if (raw.length <= 4) return '';
          const enKey = [
            64,
            71,
            97,
            119,
            94,
            50,
            116,
            71,
            81,
            54,
            49,
            45,
            206,
            210,
            110,
            105,
          ];
          final payload = Uint8List(raw.length - 4);
          for (var i = 0; i < payload.length; i++) {
            payload[i] = raw[i + 4] ^ enKey[i % enKey.length];
          }
          return utf8.decode(
            ZLibDecoder().decodeBytes(payload),
            allowMalformed: true,
          );
        } catch (_) {
          return '';
        }
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
