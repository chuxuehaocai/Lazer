import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';

const List<String> _tags = <String>['zh_Hans', 'zh_Hant', 'ja', 'en'];
final RegExp _placeholder = RegExp(r'\{(\w+)\}');

Map<String, String> _load(String tag) =>
    (jsonDecode(File('assets/l10n/$tag.json').readAsStringSync())
            as Map<String, dynamic>)
        .cast<String, String>();

Set<String> _placeholders(String value) =>
    _placeholder.allMatches(value).map((RegExpMatch m) => m.group(1)!).toSet();

void main() {
  test('locale tables agree on keys and placeholders', () {
    final Map<String, Map<String, String>> tables =
        <String, Map<String, String>>{
          for (final String tag in _tags) tag: _load(tag),
        };
    final Map<String, String> base = tables['zh_Hans']!;
    for (final String tag in _tags.skip(1)) {
      final Map<String, String> table = tables[tag]!;
      expect(
        table.keys.toSet(),
        base.keys.toSet(),
        reason: '$tag.json must carry exactly the Simplified Chinese keys',
      );
      for (final String key in base.keys) {
        expect(
          _placeholders(table[key]!),
          _placeholders(key),
          reason: '$tag.json changes the placeholders of "$key"',
        );
      }
    }
  });

  test('patterns substitute runtime values and leave unknown text alone', () {
    final AppLocalizations strings =
        AppLocalizations(const Locale('en'), <String, String>{
          '{count} 首': '{count} songs',
          '下载失败（HTTP {code}）。': 'Download failed (HTTP {code}).',
        });
    expect(strings.text('3 首'), '3 songs');
    expect(strings.text('下载失败（HTTP 500）。'), 'Download failed (HTTP 500).');
    expect(strings.text('真实歌单'), '真实歌单');
  });

  test('catalogue loading labels translate around counts and artist data', () {
    final strings = AppLocalizations(const Locale('en'), _load('en'));
    expect(strings.text('7 张全长专辑（加载中）'), '7 full-length albums (loading)');
    expect(strings.text('3 张（加载中）'), '3 releases (loading)');
    expect(strings.text('设置 · 7 张（加载中）'), '设置 · 7 releases (loading)');
    expect(strings.text('12 秒后重试'), 'Retry in 12s');
    expect(strings.text('本地音乐 · 42'), 'Local music · 42');
    expect(
      strings.text('音频引擎已中断：device error（当前非 HiFi 路径）'),
      'Audio engine interrupted: device error (not currently using the HiFi path)',
    );
  });
}
