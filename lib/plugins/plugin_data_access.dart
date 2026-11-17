import 'plugin_manifest.dart';

/// Host-owned consent for private data. Grants never live in the Lua VM, so
/// revoking one takes effect even while a plugin is still running.
class PluginDataAccess {
  PluginDataAccess(this.manifest);

  final PluginManifest manifest;
  final Set<String> _granted = {};
  final Map<String, int> _revisions = {};
  final Map<String, Future<bool>> _requests = {};
  Object _epoch = Object();
  bool _active = true;

  /// Invalidate before the first asynchronous teardown step, not after socket
  /// handshakes or provider cleanup finish. Grants persist across VM restarts;
  /// requests and consent dialogs from the old VM never do.
  void suspend() {
    _active = false;
    _epoch = Object();
    _requests.clear();
  }

  void resume() {
    _epoch = Object();
    _active = true;
  }

  Set<String> get granted => Set.unmodifiable(_granted);

  void setGranted(String scope, bool value) {
    if (!manifest.dataPermissions.contains(scope)) {
      throw const FormatException('Undeclared plugin data permission');
    }
    _revisions[scope] = (_revisions[scope] ?? 0) + 1;
    if (value) {
      _granted.add(scope);
    } else {
      _granted.remove(scope);
    }
  }

  static String? requiredScope(String command) => switch (command) {
    'library_playlists' ||
    'library_tracks' ||
    'library_search' ||
    'library_play' ||
    'library_album' ||
    'library_local' => 'library',
    'native_audio.status' || 'native_audio.devices' => 'native_audio',
    'native_lyrics.status' || 'native_lyrics.configure' => 'native_control',
    'user_profile' || 'user_platforms' => 'profile',
    'user_statistics' ||
    'recent' ||
    'recent_tracks' ||
    'recenttracks' => 'history',
    _ => null,
  };

  Future<bool> request(
    String scope,
    Future<bool> Function(String permission) prompt,
    Future<void> Function() persist,
  ) async {
    if (!_active || !manifest.dataPermissions.contains(scope)) return false;
    if (_granted.contains(scope)) return true;
    final existing = _requests[scope];
    if (existing != null) return existing;
    late final Future<bool> pending;
    pending = _request(scope, prompt, persist).whenComplete(() {
      if (identical(_requests[scope], pending)) _requests.remove(scope);
    });
    _requests[scope] = pending;
    return pending;
  }

  Future<bool> _request(
    String scope,
    Future<bool> Function(String permission) prompt,
    Future<void> Function() persist,
  ) async {
    final revision = _revisions[scope] ?? 0;
    final epoch = _epoch;
    if (!await prompt('data.$scope') ||
        !_active ||
        !identical(epoch, _epoch) ||
        revision != (_revisions[scope] ?? 0)) {
      return false;
    }
    setGranted(scope, true);
    final grantedRevision = _revisions[scope];
    await persist();
    return _active &&
        identical(epoch, _epoch) &&
        _granted.contains(scope) &&
        grantedRevision == _revisions[scope];
  }

  Future<Object?> dispatch(
    Map<String, dynamic> spec, {
    required Future<bool> Function(String permission) prompt,
    required Future<void> Function() persist,
    required bool Function() isActive,
    required Future<Object?> Function(Map<String, dynamic>) backend,
  }) async {
    final epoch = _epoch;
    void assertActive() {
      if (!_active || !identical(epoch, _epoch) || !isActive()) {
        throw const PluginException('Plugin is no longer active', code: 403);
      }
    }

    assertActive();
    final command = '${spec['command'] ?? spec['op'] ?? spec['action'] ?? ''}'
        .toLowerCase()
        .trim();
    if (command == 'permissions') {
      return {
        'declared': manifest.dataPermissions,
        'granted': _granted.toList(),
      };
    }
    if (command == 'permission_request') {
      final result = await request('${spec['scope'] ?? ''}', prompt, persist);
      assertActive();
      return result;
    }
    final scope = requiredScope(command);
    if (scope != null && !await request(scope, prompt, persist)) {
      throw const PluginException('Plugin data permission denied', code: 403);
    }
    final revision = scope == null ? null : _revisions[scope];
    void assertCurrentAccess() {
      assertActive();
      if (scope != null &&
          (!_granted.contains(scope) || _revisions[scope] != revision)) {
        throw const PluginException(
          'Plugin data permission revoked',
          code: 403,
        );
      }
    }

    assertCurrentAccess();
    final result = await backend({
      ...spec,
      'command': command,
      // The caller cannot impersonate a different plugin.
      '_callerPluginId': manifest.id,
      // Host-only callback, never transferred into Lua. A backend that reads
      // private data and then mutates public state must call this synchronously
      // immediately before committing that mutation, not just before returning.
      '_assertDataAccess': assertCurrentAccess,
    });
    assertCurrentAccess();
    return result;
  }
}

/// Lua helpers share one backend across native and browser runtimes. The host
/// validates permission and operation again; wrappers are only convenience.
const pluginFrontendLua = r'''
local function frontend_call(command, spec)
  local request = {}
  if type(spec) == "table" then
    for key, value in pairs(spec) do request[key] = value end
  end
  request.command = command
  return _player_control(request)
end
host.permissions = function() return frontend_call("permissions") end
host.request_permission = function(scope)
  return frontend_call("permission_request", {scope = scope})
end
host.library = function(spec)
  spec = spec or {}
  return frontend_call("library_" .. (spec.operation or "playlists"), spec)
end
host.user = function(spec)
  spec = spec or {}
  return frontend_call("user_" .. (spec.operation or "profile"), spec)
end
host.native = function(spec)
  spec = spec or {}
  return frontend_call("native_" .. (spec.operation or "capabilities"), spec)
end
host.search = function(spec) return frontend_call("library_search", spec) end
''';
