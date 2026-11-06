/// Context for a debug hook.
class HookContext {
  int hookId;
  int line;
  String fileName;
  Function hookFunction;

  HookContext(this.hookId, this.line, this.fileName, this.hookFunction);

  bool isHooked(String fileName, int line) {
    return this.line == line && fileName.contains(this.fileName);
  }

  void triggerHook() {
    hookFunction();
  }
}

/// Abstract interface for Lua debug operations.
abstract class LuaDebug {
  /// Sets a debug hook.
  void setHook(HookContext context);
}
