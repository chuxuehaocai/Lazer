import 'lua_state.dart';

/// basic ypes
enum LuaType {
  luaNil,
  luaBoolean,
  luaLightUserdata,
  luaNumber,
  luaString,
  luaTable,
  luaFunction,
  luaUserdata,
  luaThread,
  luaNone,
}


/// arithmetic functions
enum ArithOp {
  luaOpAdd , // +
  luaOpSub , // -
  luaOpMul , // *
  luaOpMod , // %
  luaOpPow , // ^
  luaOpDiv , // /
  luaOpIdiv, // //
  luaOpBand, // &
  luaOpBor , // |
  luaOpBxor, // ~
  luaOpShl , // <<
  luaOpShr , // >>
  luaOpUnm , // -
  luaOpBnot, // ~
}

/// comparison functions
enum CmpOp {
  luaOpEq, // ==
  luaOpLt, // <
  luaOpLe, // <=
}

enum ThreadStatus {
  luaOk,
  luaYield,
  luaDead,
  luaErrRun,
  luaErrSyntax,
  luaErrMem,
  luaErrGcmm,
  luaErrErr,
  luaErrFile,
}

/// Synchronous Dart function that can be called from Lua.
/// Returns the number of values pushed onto the Lua stack.
typedef DartFunction = int Function(LuaState ls);

/// Asynchronous Dart function that can be called from Lua.
/// Returns a Future that resolves to the number of values pushed onto the Lua stack.
typedef DartFunctionAsync = Future<int> Function(LuaState ls);