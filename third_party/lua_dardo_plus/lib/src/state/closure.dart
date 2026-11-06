import '../api/lua_type.dart';
import '../binchunk/binary_chunk.dart';
import 'upvalue_holder.dart';

class Closure {
  final Prototype? proto;
  final DartFunction? dartFunc;
  final DartFunctionAsync? dartFuncAsync;
  final List<UpvalueHolder?> upvals;

  /// Number of expected results for coroutine support
  int nResults = 0;

  Closure(Prototype this.proto)
      : dartFunc = null,
        dartFuncAsync = null,
        upvals = List<UpvalueHolder?>.filled(proto.upvalues.length, null);

  Closure.DartFunc(this.dartFunc, int nUpvals)
      : proto = null,
        dartFuncAsync = null,
        upvals = List<UpvalueHolder?>.filled(nUpvals, null);

  Closure.DartFuncAsync(this.dartFuncAsync, int nUpvals)
      : proto = null,
        dartFunc = null,
        upvals = List<UpvalueHolder?>.filled(nUpvals, null);

  /// Whether this closure wraps an async Dart function.
  bool get isAsync => dartFuncAsync != null;

  /// Whether this closure wraps a sync Dart function.
  bool get isDartFunc => dartFunc != null;

  /// Whether this closure is a Lua function.
  bool get isLuaFunc => proto != null;
}