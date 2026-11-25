import 'package:lua_dardo_plus/lua.dart';

/// Fails unless this Lua VM can await asynchronous host functions.
///
/// The published `lua_dardo_plus` runs a Lua closure to completion on the
/// synchronous call path, so the first `pcall`, `host.http` or other async host
/// function reached from Lua bytecode dies inside the VM as a bare
/// "Null check operator used on a null value". `tool/patch_lua_dardo_plus.dart`
/// teaches the VM to await those nested calls; dependency resolution alone does
/// not apply it, so a checkout that ran `flutter pub get` without the patch
/// looks exactly like a plugin whose Lua source is broken.
///
/// One probe at VM start turns that into a message that names the actual fix,
/// which then reaches the app log through `lua.startup_error`.
Future<void> requireAsyncHostCalls(LuaState lua) async {
  var supported = false;
  try {
    // `pcall` is registered by the host as an async function, so reaching it at
    // all exercises the nested async path; `host.now` is the value it returns.
    // Assign first: `return pcall(..)` would leave both the flag and the value
    // on the stack and the flag would no longer be on top.
    supported =
        await lua.doStringAsync(
          'local ok = pcall(host.now)\nreturn ok',
        ) &&
        lua.isBoolean(-1) &&
        lua.toBoolean(-1);
  } catch (_) {
    supported = false;
  } finally {
    lua.setTop(0);
  }
  if (!supported) {
    throw const FormatException(
      'The Lua VM cannot await asynchronous host calls. '
      'Run: dart tool/patch_lua_dardo_plus.dart',
    );
  }
}
