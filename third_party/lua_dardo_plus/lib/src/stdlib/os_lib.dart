import '../../lua.dart';
import '../platform/platform.dart';

class OSLib {
  static const Map<String, DartFunction> _sysFuncs = {
    "clock": _osClock,
    "difftime": _osDiffTime,
    "time": _osTime,
    "date": _osDate,
    "remove": _osRemove,
    "rename": _osRename,
    "tmpname": _osTmpName,
    "getenv": _osGetEnv,
    "execute": _osExecute,
    "exit": _osExit,
    "setlocale": _osSetLocale,
  };

  static int openOSLib(LuaState ls) {
    ls.newLib(_sysFuncs);
    return 1;
  }

  // os.clock ()
// http://www.lua.org/manual/5.3/manual.html#pdf-os.clock
// lua-5.3.4/src/loslib.c#os_clock()
  static int _osClock(LuaState ls) {
    ls.pushNumber(DateTime.now().millisecondsSinceEpoch/1000);
    return 1;
  }

// os.difftime (t2, t1)
// http://www.lua.org/manual/5.3/manual.html#pdf-os.difftime
// lua-5.3.4/src/loslib.c#os_difftime()
  static int _osDiffTime(LuaState ls) {
    var t2 = ls.checkInteger(1)!;
    var t1 = ls.checkInteger(2)!;
    ls.pushInteger(t2 - t1);
    return 1;
  }

// os.time ([table])
// http://www.lua.org/manual/5.3/manual.html#pdf-os.time
// lua-5.3.4/src/loslib.c#os_time()
  static int _osTime(LuaState ls) {
    if (ls.isNoneOrNil(1)) {
      /* called without args? */
      var t =
          DateTime.now().millisecondsSinceEpoch ~/ 1000; /* get current time */
      ls.pushInteger(t);
    } else {
      ls.checkType(1, LuaType.luaTable);
      var sec = _getField(ls, "sec", 0);
      var min = _getField(ls, "min", 0);
      var hour = _getField(ls, "hour", 12);
      var day = _getField(ls, "day", -1);
      var month = _getField(ls, "month", -1);
      var year = _getField(ls, "year", -1);
      // todo: isdst
      var t =
          DateTime(year, month, day, hour, min, sec).millisecondsSinceEpoch ~/
              1000;
      ls.pushInteger(t);
    }
    return 1;
  }

// lua-5.3.4/src/loslib.c#getfield()
  static int _getField(LuaState ls, String key, int dft) {
    var t = ls.getField(-1, key); /* get field and its type */
    var res = ls.toIntegerX(-1);
    if (res == null) {
      /* field is not an integer? */
      if (t != LuaType.luaNil) {
        /* some other value? */
        return ls.error2("field '%s' is not an integer", [key]);
      } else if (dft < 0) {
        /* absent field; no default? */
        return ls.error2("field '%s' missing in date table", [key]);
      }
      res = dft;
    }
    ls.pop(1);
    return res;
  }

// os.date ([format [, time]])
// http://www.lua.org/manual/5.3/manual.html#pdf-os.date
// lua-5.3.4/src/loslib.c#os_date()
  static int _osDate(LuaState ls) {
    var format = ls.optString(1, "%c")!;
    DateTime t;
    if (ls.isInteger(2)) {
      t = DateTime.now().add(Duration(seconds: ls.toInteger(2)));
    } else {
      t = DateTime.now();
    }

    if (format.isNotEmpty && format[0] == '!') {
      /* UTC? */
      format = format.substring(1); /* skip '!' */
      t = t.toUtc();
    }

    if (format == "*t") {
      ls.createTable(0, 9); /* 9 = number of fields */
      _setField(ls, "sec", t.second);
      _setField(ls, "min", t.minute);
      _setField(ls, "hour", t.hour);
      _setField(ls, "day", t.day);
      _setField(ls, "month", t.month);
      _setField(ls, "year", t.year);
      _setField(ls, "wday", t.weekday);
      _setField(ls, "yday", _getYearDay(t));
    } else if (format == "%c") {
      ls.pushString(t.toString());
    } else {
      ls.pushString(format); // TODO
    }

    return 1;
  }

  static int _getYearDay(DateTime date){
    var monthDay = [31,28,31,30,31,30,31,31,30,31,30,31];

    if(date.year%4==0 && date.year%100!=0) monthDay[1] = 29;
    else if(date.year%400==0) monthDay[1] = 29;

    int sum=0;
    for(var i = 0;i<=date.month-2;i++){
      sum += monthDay[i];
    }

    return date.day + sum;
  }

  static void _setField(LuaState ls, String key, int value) {
    ls.pushInteger(value);
    ls.setField(-2, key);
  }

// os.remove (filename)
// http://www.lua.org/manual/5.3/manual.html#pdf-os.remove
  static int _osRemove(LuaState ls) {
    var filename = ls.checkString(1)!;

    if (!PlatformServices.instance.supportsFileSystem) {
      ls.pushNil();
      ls.pushString('os.remove is not supported on this platform');
      return 2;
    }

    if (PlatformServices.instance.deleteFile(filename)) {
      ls.pushBoolean(true);
      return 1;
    } else {
      ls.pushNil();
      ls.pushString('cannot remove file: $filename');
      return 2;
    }
  }

// os.rename (oldname, newname)
// http://www.lua.org/manual/5.3/manual.html#pdf-os.rename
  static int _osRename(LuaState ls) {
    var oldName = ls.checkString(1)!;
    var newName = ls.checkString(2)!;

    if (!PlatformServices.instance.supportsFileSystem) {
      ls.pushNil();
      ls.pushString('os.rename is not supported on this platform');
      return 2;
    }

    if (PlatformServices.instance.renameFile(oldName, newName)) {
      ls.pushBoolean(true);
      return 1;
    } else {
      ls.pushNil();
      ls.pushString('cannot rename file: $oldName');
      return 2;
    }
  }

// os.tmpname ()
// http://www.lua.org/manual/5.3/manual.html#pdf-os.tmpname
  static int _osTmpName(LuaState ls) {
    throw ("todo: osTmpName!");
  }

// os.getenv (varname)
// http://www.lua.org/manual/5.3/manual.html#pdf-os.getenv
// lua-5.3.4/src/loslib.c#os_getenv()
  static int _osGetEnv(LuaState ls) {
    var key = ls.checkString(1)!;
    var env = PlatformServices.instance.getEnvironmentVariable(key);

    if (env != null && env.isNotEmpty) {
      ls.pushString(env);
    } else {
      ls.pushNil();
    }
    return 1;
  }

// os.execute ([command])
// http://www.lua.org/manual/5.3/manual.html#pdf-os.execute
  static int _osExecute(LuaState ls) {
    if (!PlatformServices.instance.supportsProcess) {
      ls.pushNil();
      ls.pushString('os.execute is not supported on this platform');
      return 2;
    }

    var cmd = ls.checkString(1)!;
    var args = cmd.split(" ");
    int? exitCode;
    if (args.length > 1) {
      var comm = args.removeAt(0);
      exitCode = PlatformServices.instance.runProcess(comm, args);
    } else {
      exitCode = PlatformServices.instance.runProcess(cmd, []);
    }

    if (exitCode != null) {
      ls.pushBoolean(exitCode == 0);
      ls.pushString(exitCode == 0 ? 'exit' : 'signal');
      ls.pushInteger(exitCode);
      return 3;
    } else {
      ls.pushNil();
      ls.pushString('failed to execute command');
      return 2;
    }
  }

// os.exit ([code [, close]])
// http://www.lua.org/manual/5.3/manual.html#pdf-os.exit
// lua-5.3.4/src/loslib.c#os_exit()
  static int _osExit(LuaState ls) {
    int code;
    if (ls.isBoolean(1)) {
      code = ls.toBoolean(1) ? 0 : 1;
    } else {
      code = ls.optInteger(1, 0)!;
    }

    try {
      PlatformServices.instance.exit(code);
    } catch (e) {
      // On web platform, exit() throws UnsupportedError
      // In that case, we just return without exiting
      return 0;
    }
  }

// os.setlocale (locale [, category])
// http://www.lua.org/manual/5.3/manual.html#pdf-os.setlocale
  static int _osSetLocale(LuaState ls) {
    throw ("todo: osSetLocale!");
  }
}
