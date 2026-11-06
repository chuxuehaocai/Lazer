import 'lua_state.dart';
import 'lua_type.dart';

/// Abstract interface for Lua coroutine operations.
/// Implements the coroutine library functionality.
abstract class LuaCoroutineLib {
  /// Converts the value at the given index to a Lua thread (coroutine).
  /// Returns null if the value is not a thread.
  LuaState? toThread(int idx);

  /// Pushes a thread onto the stack.
  void pushThread(LuaState L);

  /// Moves n values from one state to another.
  /// Pops the values from 'from' and pushes them to this state.
  void xmove(LuaState from, int n);

  /// Pops and returns the top value from the stack as a Dart object.
  Object? popObject();

  /// Creates a new thread (coroutine) that shares the global environment.
  LuaState newThread();

  /// Returns debug information about all threads.
  String debugThread();

  /// Clears weak references to dead threads.
  void clearThreadWeakRef();

  /// Sets the thread status.
  void setStatus(ThreadStatus status);

  /// Gets the current thread status.
  ThreadStatus getStatus();

  /// Resumes a suspended coroutine.
  void resume(int nArgs);

  /// Returns the unique ID of this thread.
  int runningId();

  /// Gets the number of expected results for current closure.
  int getCurrentNResults();

  /// Resets the expected number of results for the top closure.
  void resetTopClosureNResults(int nResults);

  /// Returns a stack trace for debugging.
  String traceStack();

  /// Pops the top stack frame (used after yield is caught).
  void popStackFrame();
}
