/// Exception thrown when a coroutine yields.
/// This is used internally to implement coroutine.yield().
class LuaYieldException implements Exception {
  /// The number of values being yielded
  final int nResults;

  LuaYieldException(this.nResults);

  @override
  String toString() => 'LuaYieldException(nResults: $nResults)';
}
