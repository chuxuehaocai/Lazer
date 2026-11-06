# LuaDardo Plus 0.3.1

Vendored from the published `lua_dardo_plus` 0.3.1 package (Apache-2.0; see LICENSE).

Lazer patches:

- Await nested Lua CALL, TAILCALL and TFORCALL operations from `callAsync`.
  This preserves local variables across asynchronous host HTTP calls. Each
  closure unwinds its stack on errors, so protected calls can recover.
- Fix `string.reverse` indexing an empty Dart list.

Gateway host regression tests exercise nested calls, loops, multiple requests,
protected-call recovery and per-plugin isolation through the public API.
