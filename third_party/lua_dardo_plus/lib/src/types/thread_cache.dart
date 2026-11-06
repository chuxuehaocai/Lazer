import '../api/lua_state.dart';

/// Cache for tracking Lua threads (coroutines) with weak references.
/// This allows threads to be garbage collected when no longer needed.
class ThreadCache {
  WeakReference<LuaState>? pLuaState;
  int id;

  ThreadCache(this.id, LuaState ls) {
    pLuaState = WeakReference(ls);
  }
}

/// Map type for storing thread caches by ID
typedef ThreadsMap = Map<int, ThreadCache>;
