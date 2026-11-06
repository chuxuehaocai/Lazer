import '../../lua.dart';

/// Lua coroutine library implementation.
/// Provides coroutine.create, coroutine.resume, coroutine.yield, etc.
class CoroutineLib {
  static const Map<String, DartFunction> _coFuncs = {
    "create": _coCreate,
    "resume": _coResume,
    "yield": _coYield,
    "wrap": _coWrap,
    "status": _coStatus,
    "running": _coRunning,
  };

  static int openCoroutineLib(LuaState ls) {
    ls.newLib(_coFuncs);
    return 1;
  }

  /// coroutine.create(f) - Creates a new coroutine with body f
  static int _coCreate(LuaState ls) {
    if (!ls.isFunction(1)) {
      return ls.error2("function expected");
    }

    LuaState newls = ls.newThread();
    newls.xmove(ls, 1); // Move function to new thread
    ls.pushThread(newls);
    return 1;
  }

  /// coroutine.resume(co [, val1, ...]) - Starts or resumes coroutine
  static int _coResume(LuaState ls) {
    int nArgs = ls.getTop() - 1;
    LuaState? co = ls.toThread(1);
    if (co == null) {
      ls.pushBoolean(false);
      ls.pushString("thread expected");
      return 2;
    }

    // Check for self-resume
    if (co.runningId() == ls.runningId()) {
      ls.pushBoolean(false);
      ls.pushString("cannot resume non-suspended coroutine");
      return 2;
    }

    if (co.getStatus() == ThreadStatus.luaDead) {
      ls.pushBoolean(false);
      ls.pushString("cannot resume dead coroutine");
      return 2;
    }

    // Move arguments to coroutine
    co.xmove(ls, nArgs);

    try {
      if (co.getStatus() == ThreadStatus.luaOk) {
        // First call - use luaMultret (-1) to get all results
        co.call(nArgs, -1);
      } else if (co.getStatus() == ThreadStatus.luaYield) {
        co.setStatus(ThreadStatus.luaOk);
        co.resume(nArgs);
      }
    } catch (e, s) {
      if (e is LuaYieldException) {
        final n = e.nResults;
        // Get yielded values from the yield's stack frame
        ls.pushBoolean(true);
        ls.xmove(co, n);
        // Pop the yield's stack frame from coroutine
        co.popStackFrame();
        return n + 1;
      } else {
        String msg = 'error: $e\n\n${s.toString()}\n\n${co.traceStack()}';
        ls.pushBoolean(false);
        ls.pushString(msg);
        return 2;
      }
    }

    // Coroutine completed successfully
    co.setStatus(ThreadStatus.luaDead);

    // Get all results from coroutine stack
    int nResults = co.getTop();
    ls.pushBoolean(true);
    if (nResults > 0) {
      ls.xmove(co, nResults);
    }
    return nResults + 1;
  }

  /// coroutine.status(co) - Returns status of coroutine
  static int _coStatus(LuaState ls) {
    LuaState? co = ls.toThread(1);
    if (co == null) {
      ls.pushString("dead");
    } else {
      if (co.runningId() == ls.runningId()) {
        ls.pushString("running");
      } else if (co.getStatus() == ThreadStatus.luaDead) {
        ls.pushString("dead");
      } else if (co.getStatus() == ThreadStatus.luaYield) {
        ls.pushString("suspended");
      } else {
        ls.pushString("suspended");
      }
    }
    return 1;
  }

  /// coroutine.yield(...) - Suspends execution of the coroutine
  static int _coYield(LuaState ls) {
    final nResults = ls.getTop();
    ls.setStatus(ThreadStatus.luaYield);
    throw LuaYieldException(nResults);
  }

  /// coroutine.running() - Returns the running coroutine
  static int _coRunning(LuaState ls) {
    ls.pushThread(ls);
    return 1;
  }

  /// coroutine.wrap(f) - Creates a coroutine and returns a resume function
  static int _coWrap(LuaState ls) {
    if (!ls.isFunction(1)) {
      ls.pushNil();
      return 1;
    }

    LuaState newCo = ls.newThread();
    newCo.xmove(ls, 1); // Move function to coroutine

    // Return a wrapper function that resumes the coroutine
    ls.pushDartFunction((LuaState innerLs) {
      LuaState co = newCo;
      int nargs = innerLs.getTop();

      co.xmove(innerLs, nargs);

      try {
        if (co.getStatus() == ThreadStatus.luaOk) {
          co.call(nargs, -1); // Use multret
        } else if (co.getStatus() == ThreadStatus.luaYield) {
          co.setStatus(ThreadStatus.luaOk);
          co.resume(nargs);
        }
      } catch (e) {
        if (e is LuaYieldException) {
          int n = e.nResults;
          innerLs.xmove(co, n);
          // Pop the yield's stack frame from coroutine
          co.popStackFrame();
          return n;
        } else {
          throw Exception("coroutine error: $e");
        }
      }

      co.setStatus(ThreadStatus.luaDead);
      int nResults = co.getTop();
      if (nResults > 0) {
        innerLs.xmove(co, nResults);
      }
      return nResults;
    });

    return 1;
  }
}
