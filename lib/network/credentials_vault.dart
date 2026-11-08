// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../local/coalescing_writer.dart';
import '../storage/app_storage.dart';

/// Stores NAS passwords beside the source list, encrypted with a per-install
/// key.
///
/// There is no OS keychain plugin in this build (adding one would change every
/// platform's native build), so the key lives next to the ciphertext. That
/// keeps plain-text passwords out of backups and logs and out of a casual look
/// at the data directory; it is not a defence against someone who can already
/// read the app's data directory, which is stated in the docs.
class NetworkCredentialsVault {
  NetworkCredentialsVault({
    Future<Directory> Function()? supportDirectory,
    Random? random,
  }) : _supportDirectory = supportDirectory ?? appSupportDirectory,
       _random = random ?? Random.secure();

  static const String _fileName = 'network_credentials.json';
  static const String _keyFileName = 'network_credentials.key';
  static const int _keyLength = 32;
  static const int _ivLength = 12;

  final Future<Directory> Function() _supportDirectory;
  final Random _random;

  final Map<String, String> _secrets = <String, String>{};
  Uint8List? _key;
  bool _loaded = false;
  Future<void>? _loading;
  late final CoalescingWriter _writer = CoalescingWriter(_write);

  bool get loaded => _loaded;
  int get count => _secrets.length;

  Future<void> load() {
    final Future<void>? pending = _loading;
    if (pending != null) return pending;
    if (_loaded) return Future<void>.value();
    final Future<void> loading = _load();
    _loading = loading;
    return loading.whenComplete(() {
      if (identical(_loading, loading)) _loading = null;
    });
  }

  Future<void> _load() async {
    try {
      final Directory? directory = await _directory();
      if (directory == null) {
        _loaded = true;
        return;
      }
      final File keyFile = File('${directory.path}${Platform.pathSeparator}$_keyFileName');
      if (await keyFile.exists()) {
        final List<int> bytes = await keyFile.readAsBytes();
        if (bytes.length == _keyLength) {
          _key = Uint8List.fromList(bytes);
        }
      }
      final File file = File('${directory.path}${Platform.pathSeparator}$_fileName');
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        _loaded = true;
        return;
      }
      final Object? version = decoded['version'];
      if (version != null && version != 1) {
        _loaded = true;
        return;
      }
      final Object? entries = decoded['entries'];
      if (entries is Map<String, dynamic>) {
        for (final MapEntry<String, dynamic> entry in entries.entries) {
          final String? raw = entry.value as String?;
          if (raw == null || raw.isEmpty) continue;
          final String? plain = _decrypt(raw);
          if (plain != null && plain.isNotEmpty) _secrets[entry.key] = plain;
        }
      }
    } catch (_) {
      // A corrupt vault must not stop the app; the listener re-enters the
      // password, and a new key is written on the next save.
    } finally {
      _loaded = true;
    }
  }

  /// The stored password for [sourceId], or null when none is saved.
  String? secretFor(String sourceId) => _secrets[sourceId];

  Future<void> put(String sourceId, String secret) async {
    await load();
    if (secret.isEmpty) {
      _secrets.remove(sourceId);
    } else {
      _secrets[sourceId] = secret;
    }
    await _persist();
  }

  Future<void> remove(String sourceId) async {
    await load();
    if (_secrets.remove(sourceId) == null) return;
    await _persist();
  }

  Future<Directory?> _directory() async {
    try {
      final Directory directory = await _supportDirectory();
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      return null;
    }
  }

  /// Coalesces overlapping saves: the write that runs last always contains
  /// the newest secret, even when a password is replaced while a save is in
  /// flight.
  Future<void> _persist() => _writer.request();

  Future<void> _write() async {
    final Directory? directory = await _directory();
    if (directory == null) return;
    final Uint8List key = await _ensureKey(directory);
    final Map<String, String> encoded = <String, String>{};
    for (final MapEntry<String, String> entry in _secrets.entries) {
      encoded[entry.key] = _encrypt(entry.value, key);
    }
    final File file = File(
      '${directory.path}${Platform.pathSeparator}$_fileName',
    );
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{'version': 1, 'entries': encoded}),
      flush: true,
    );
    await temporary.rename(file.path);
    await _restrict(file);
  }

  /// Best effort: the file holds passwords, so keep it out of other users'
  /// reach on POSIX. Windows inherits the profile directory's ACL instead.
  static Future<void> _restrict(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['600', file.path]);
    } catch (_) {}
  }

  Future<Uint8List> _ensureKey(Directory directory) async {
    final Uint8List? current = _key;
    if (current != null) return current;
    final File keyFile = File(
      '${directory.path}${Platform.pathSeparator}$_keyFileName',
    );
    if (await keyFile.exists()) {
      final List<int> bytes = await keyFile.readAsBytes();
      if (bytes.length == _keyLength) {
        return _key = Uint8List.fromList(bytes);
      }
    }
    final Uint8List generated = Uint8List.fromList(
      List<int>.generate(_keyLength, (_) => _random.nextInt(256)),
    );
    await keyFile.writeAsBytes(generated, flush: true);
    await _restrict(keyFile);
    return _key = generated;
  }

  String _encrypt(String plainText, Uint8List key) {
    final Uint8List iv = Uint8List.fromList(
      List<int>.generate(_ivLength, (_) => _random.nextInt(256)),
    );
    final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
      );
    final Uint8List cipherText = cipher.process(
      Uint8List.fromList(utf8.encode(plainText)),
    );
    return base64Encode(<int>[...iv, ...cipherText]);
  }

  String? _decrypt(String encoded) {
    final Uint8List? key = _key;
    if (key == null) return null;
    try {
      final Uint8List bytes = base64Decode(encoded);
      if (bytes.length <= _ivLength) return null;
      final Uint8List iv = bytes.sublist(0, _ivLength);
      final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
        );
      final Uint8List clear = cipher.process(bytes.sublist(_ivLength));
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }
}
