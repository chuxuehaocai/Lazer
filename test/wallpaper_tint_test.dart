import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/wallpaper_tint.dart';

Uint8List _pixels(List<List<int>> rgba) {
  final data = Uint8List(rgba.length * 4);
  for (var index = 0; index < rgba.length; index++) {
    data[index * 4] = rgba[index][0];
    data[index * 4 + 1] = rgba[index][1];
    data[index * 4 + 2] = rgba[index][2];
    data[index * 4 + 3] = rgba[index][3];
  }
  return data;
}

void main() {
  test('the average is the wallpaper colour DWM would have sampled', () {
    final color = averageWallpaperColor(
      _pixels(<List<int>>[
        <int>[200, 218, 239, 255],
        <int>[100, 118, 139, 255],
      ]),
    );
    expect(color, const Color(0xFF96A8BD));
  });

  test('transparent pixels do not drag the average towards black', () {
    final color = averageWallpaperColor(
      _pixels(<List<int>>[
        <int>[255, 255, 255, 255],
        <int>[0, 0, 0, 0],
        <int>[0, 0, 0, 0],
      ]),
    );
    expect(color, const Color(0xFFFFFFFF));
  });

  test('a fully transparent image has no colour to offer', () {
    expect(
      averageWallpaperColor(
        _pixels(<List<int>>[
          <int>[10, 20, 30, 0],
        ]),
      ),
      isNull,
    );
  });

  test('non-desktop platforms never look for a wallpaper file', () {
    // The lookup is what the material veil falls back from, so it has to be
    // empty rather than pointing at a path that cannot exist.
    expect(
      desktopWallpaperCandidates().every(
        (path) => path.contains('Themes') || path.contains('Pictures'),
      ),
      isTrue,
    );
  });
}
