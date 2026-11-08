import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../state/build_safe_notifier.dart';
import '../updates/release_version.dart';
import 'plugin_manager.dart';
import 'plugin_package.dart';

const defaultPluginSource = 'https://lazer.naominet.dev/plugin';

Uri pluginIndexUri(String source) {
  final uri = Uri.tryParse(source.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请输入有效的 HTTPS 插件源地址。');
  }
  return uri.path.endsWith('.json')
      ? uri
      : uri.replace(
          path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/plugins.json',
        );
}

class MarketPlugin {
  MarketPlugin.fromJson(Map<String, dynamic> json, Uri index)
    : id = json['id'] as String,
      version = json['version'] as String,
      name = json['name'],
      summary = json['summary'],
      author = json['author'] as String? ?? '',
      platforms = List<String>.from(json['platforms'] as List? ?? []),
      minAppVersion = json['minAppVersion'] as String?,
      checksum = json['sha256'] as String?,
      download = index.resolve(json['download'] as String) {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{2,79}$').hasMatch(id) ||
        ReleaseVersion.parse(version) == null ||
        download.scheme != 'https' ||
        download.userInfo.isNotEmpty ||
        checksum != null && !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(checksum!)) {
      throw const FormatException('插件源包含无效的插件信息。');
    }
  }
  final String id, version, author;
  final Object? name, summary;
  final List<String> platforms;
  final String? minAppVersion, checksum;
  final Uri download;

  String localized(Object? value, String locale) {
    if (value is String) return value;
    if (value is Map) {
      final language = locale.split('-').first;
      return '${value[locale] ?? value[language] ?? value['zh-CN'] ?? value['en'] ?? value.values.firstOrNull ?? ''}';
    }
    return '';
  }

  String? incompatibility(String platform, String appVersion) {
    if (platforms.isNotEmpty && !platforms.contains(platform)) {
      return '不支持当前系统';
    }
    if (minAppVersion case final minimum?) {
      final required = ReleaseVersion.parse(minimum);
      final current = ReleaseVersion.parse(appVersion);
      if (required == null ||
          current == null ||
          current.compareTo(required) < 0) {
        return '需要 Lazer $minimum 或更高版本';
      }
    }
    return null;
  }
}

/// Owns bounded HTTP transfers and installation state, independent of routes.
class PluginMarket extends ChangeNotifier with BuildSafeNotifier {
  PluginMarket(this.manager, {http.Client? client})
    : _client = client ?? http.Client();
  final PluginManager manager;
  final http.Client _client;
  static const _sourceKey = 'lazer_plugin_market_source';
  String source = defaultPluginSource;
  List<MarketPlugin> plugins = const [];
  bool loading = false;
  String? error, installing;
  double? progress;
  bool _disposed = false;
  int _request = 0, _download = 0;
  StreamIterator<List<int>>? _downloadReader;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    source = prefs.getString(_sourceKey) ?? defaultPluginSource;
    await refresh();
  }

  Future<void> setSource(String value) async {
    pluginIndexUri(value);
    source = value.trim();
    plugins = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sourceKey, source);
    if (!_disposed) await refresh();
  }

  Future<Uint8List> _read(Uri uri, int limit, {int? transfer}) async {
    final response = await _client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw FormatException('插件源请求失败（HTTP ${response.statusCode}）。');
    }
    if ((response.contentLength ?? 0) > limit) {
      throw const FormatException('插件源返回的文件过大。');
    }
    final bytes = BytesBuilder(copy: false);
    final reader = StreamIterator(
      response.stream.timeout(const Duration(seconds: 30)),
    );
    if (transfer != null) _downloadReader = reader;
    try {
      while (await reader.moveNext()) {
        final chunk = reader.current;
        if (_disposed || transfer != null && transfer != _download) {
          throw const _Cancelled();
        }
        if (bytes.length + chunk.length > limit) {
          throw const FormatException('插件源返回的文件过大。');
        }
        bytes.add(chunk);
        if (transfer != null) {
          final length = response.contentLength;
          progress = length != null && length > 0
              ? bytes.length / length
              : null;
          notifyListeners();
        }
      }
      if (_disposed || transfer != null && transfer != _download) {
        throw const _Cancelled();
      }
      return bytes.takeBytes();
    } finally {
      if (identical(_downloadReader, reader)) _downloadReader = null;
      await reader.cancel();
    }
  }

  Future<void> refresh() async {
    final request = ++_request;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final index = pluginIndexUri(source);
      final data = jsonDecode(utf8.decode(await _read(index, 2 * 1024 * 1024)));
      if (data is! Map ||
          data['schemaVersion'] != 1 ||
          data['plugins'] is! List) {
        throw const FormatException('不支持的插件源格式。');
      }
      final entries = (data['plugins'] as List)
          .map(
            (entry) => MarketPlugin.fromJson(
              Map<String, dynamic>.from(entry as Map),
              index,
            ),
          )
          .toList();
      if (entries.map((entry) => entry.id).toSet().length != entries.length) {
        throw const FormatException('插件源包含重复的插件。');
      }
      if (!_disposed && request == _request) plugins = entries;
    } catch (failure) {
      if (!_disposed && request == _request) error = '$failure';
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void cancelDownload() {
    _download++;
    unawaited(_downloadReader?.cancel());
    installing = null;
    progress = null;
    notifyListeners();
  }

  Future<void> install(MarketPlugin plugin) async {
    if (installing != null || manager.busy) return;
    final transfer = ++_download;
    installing = plugin.id;
    progress = null;
    error = null;
    notifyListeners();
    try {
      final bytes = await _read(
        plugin.download,
        maxPluginArchiveBytes,
        transfer: transfer,
      );
      if (plugin.checksum != null &&
          sha256.convert(bytes).toString() != plugin.checksum!.toLowerCase()) {
        throw const FormatException('插件校验失败，请刷新插件源后重试。');
      }
      if (_disposed || transfer != _download) return;
      await manager.importZip(
        bytes,
        expectedId: plugin.id,
        expectedVersion: plugin.version,
      );
    } on _Cancelled {
      // Cancelling a download must leave the installed version intact.
    } catch (failure) {
      if (!_disposed && transfer == _download) error = '$failure';
    } finally {
      if (!_disposed && transfer == _download) {
        installing = null;
        progress = null;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_request;
    ++_download;
    unawaited(_downloadReader?.cancel());
    _client.close();
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
