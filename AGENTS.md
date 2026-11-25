# Repository workflow

- Run `flutter test` successfully before every `git push`.
- Run `python3 tool/check_i18n.py` successfully before every `git push`.
- Run `dart tool/patch_lua_dardo_plus.dart` after every dependency resolution
  (`flutter pub get`, `flutter pub upgrade`, `dart pub cache repair`, a restored
  CI cache, a fresh clone) — see below for why.

## Lua 插件启动失败（插件加载不出来）

界面表现：插件管理里插件带着开关，但下面一行红字
「插件启动失败，请检查插件版本或重新导入。」，账号/平台栏里看不到它，日志里
`[lua] startup_error` 的 `error` 是：

```
Null check operator used on a null value
```

这不是插件的问题，也不是清单校验或权限的问题 —— **是本地 `lua_dardo_plus`
缺少兼容补丁**。

### 原因

`lua_dardo_plus` 从 pub.dev 获取（`567d5f39` 起不再 vendor），而 pub.dev 上的
0.3.1 用同步路径跑完整个 Lua 闭包。插件（`pcall`、`host.http`、
`host.add_setting` …）在 Lua 字节码里调宿主注册的**异步**函数时，VM 落到
`c.dartFunc!`，于是抛裸 null-check。`PluginManager._start()` 捕获后整体回滚：
网关、设置、主题全部丢弃，只留下那句通用错误。

`tool/patch_lua_dardo_plus.dart` 把 `callAsync` 里的 `_callLuaClosure` 换成会
await 嵌套 `CALL` / `TAILCALL` / `TFORCALL` 的 `_callLuaClosureAsync`，并修掉
`string.reverse` 的空表索引。**依赖解析不会自动执行它**，所以任何重新解析依赖
的动作都会把补丁覆盖掉。

### 修复步骤

```sh
# 1. 重新打补丁。幂等：已打过时只补缺失片段，并打印生效的包路径
dart tool/patch_lua_dardo_plus.dart

# 2. 确认补丁真的生效（这是唯一可信的检查，别靠界面判断）
flutter test test/lua_async_host_calls_test.dart

# 3. 完全退出应用后重启（hot reload 不会重编依赖）
flutter run -d windows
```

第 2 步通过 = VM 能 await 异步宿主调用，插件必然能启动；它失败时会直接把
`The Lua VM cannot await asynchronous host calls. Run: dart tool/patch_lua_dardo_plus.dart`
打出来，说明第 1 步没有作用到 `flutter`/`dart` 实际解析到的那份包（多个
Flutter SDK 或 `PUB_CACHE` 指向不同目录时会发生），此时按脚本打印的路径核对
`.dart_tool/package_config.json` 里 `lua_dardo_plus` 的 `rootUri`。

再补一条端到端确认：

```sh
flutter test test/lua_netease_plugin_contract_test.dart
```

不需要重新导入插件 ZIP。已安装的目录、`.network-enabled` 授权标记、
`lua_plugin_data` 里的设置与登录会话都保持原样。

### 定位手段（别再从界面猜）

- `[lua] startup_error`：解释器/宿主抛出的原始消息加栈，由
  `lua_plugin_runtime_io.dart` 写进 `AppLog`。插件管理页的通用中文不会告诉你
  真实原因，这条会。
- `lib/plugins/lua_vm_probe.dart`：每个插件 VM 在跑入口文件前先自检能否 await
  异步宿主调用。缺补丁时启动直接报
  `The Lua VM cannot await asynchronous host calls. Run: dart tool/patch_lua_dardo_plus.dart`，
  而不是裸 null-check。
- `test/lua_async_host_calls_test.dart`：锁住「Lua 闭包内经异步 `pcall` 调异步
  宿主函数、并且能捕获 Lua 错误」。用未打补丁的包跑它必然失败，且失败信息就是
  那条修复命令。

### 不要做的事

- 不要因为这条错误去改插件 Lua 源码或 `manifest.json`：`main.lua` 只是第一个
  触发点，换任何插件都一样。
- 不要把 `lua_dardo_plus` 降级/回退到 vendor 版本，也不要手改 pub cache 而不
  同步改 `tool/patch_lua_dardo_plus.dart`。
- 不要在没跑补丁的情况下把插件相关的测试失败当成插件 bug 去查。
