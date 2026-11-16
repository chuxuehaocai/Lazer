import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/platform/system_widgets.dart';

Track _track({String id = 't1', String title = 'Song'}) => Track(
  id: id,
  title: title,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 7,
  coverUrl: 'https://cdn.example/cover.jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('widget write status', () {
    test('the two successful statuses are not failures', () {
      expect(systemWidgetWriteFailure(systemWidgetStatusUpdated), isNull);
      expect(systemWidgetWriteFailure(systemWidgetStatusUnchanged), isNull);
    });

    test('the app-group status names the entitlement, not the music', () {
      final String reason = systemWidgetWriteFailure(
        systemWidgetStatusAppGroupUnavailable,
      )!;
      expect(reason, contains('App Groups'));
    });

    test('an unknown status is reported instead of ignored', () {
      expect(systemWidgetWriteFailure('somethingNew'), contains('somethingNew'));
    });
  });

  group('publishing', () {
    late List<Map<String, Object?>> published;

    setUp(() => published = <Map<String, Object?>>[]);

    test('a snapshot carries every field the widget decodes', () async {
      final SystemWidgetsBridge bridge = SystemWidgetsBridge(
        publish: (Map<String, Object?> data) async => published.add(data),
        loadArtwork: (String _) async => null,
      );
      await bridge.update(
        track: _track(),
        playing: true,
        language: 'zh-Hans',
      );
      expect(published, hasLength(1));
      final Map<String, Object?> snapshot = published.single;
      // Keys and types are the contract with PlayCountWidget.swift's
      // `PlaybackKey` decode: a rename here silently empties the widget.
      expect(snapshot['title'], 'Song');
      expect(snapshot['artist'], 'Artist');
      expect(snapshot['album'], 'Album');
      expect(snapshot['trackId'], 't1');
      expect(snapshot['hasTrack'], isTrue);
      expect(snapshot['playing'], isTrue);
      expect(snapshot['language'], 'zh-Hans');
      // The cover URL itself never crosses: only decoded bytes do.
      expect(snapshot.containsKey('coverSource'), isFalse);
      expect(bridge.lastReason, isNull);
    });

    test('no track still publishes a snapshot the widget can explain', () async {
      final SystemWidgetsBridge bridge = SystemWidgetsBridge(
        publish: (Map<String, Object?> data) async => published.add(data),
        loadArtwork: (String _) async => null,
      );
      await bridge.update(track: null, playing: false, language: 'en');
      expect(published, hasLength(1));
      expect(published.single['hasTrack'], isFalse);
      expect(published.single['playing'], isFalse);
    });

    test('a platform refusal is recorded instead of swallowed', () async {
      final SystemWidgetsBridge bridge = SystemWidgetsBridge(
        publish: (Map<String, Object?> _) async {
          throw StateError(
            systemWidgetWriteFailure(systemWidgetStatusAppGroupUnavailable)!,
          );
        },
        loadArtwork: (String _) async => null,
      );
      await bridge.update(track: _track(), playing: true, language: 'en');
      expect(bridge.status, SystemWidgetStatus.failed);
      expect(bridge.lastReason, contains('App Groups'));
    });
  });

  group('method channel contract', () {
    const MethodChannel channel = MethodChannel(
      'dev.naominet.lazer/system_widgets',
    );
    late List<MethodCall> calls;
    late Object? reply;

    setUp(() {
      calls = <MethodCall>[];
      reply = systemWidgetStatusUpdated;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return reply;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('the update reaches the platform and a status is read back', () async {
      final SystemWidgetsBridge bridge = SystemWidgetsBridge(
        loadArtwork: (String _) async => null,
      );
      await bridge.update(track: _track(), playing: true, language: 'ja');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'updateRecentPlayback');
      expect((calls.single.arguments as Map<Object?, Object?>)['title'], 'Song');
      expect(bridge.status, SystemWidgetStatus.published);
    });

    test('a missing App Group surfaces as a failure, not a silent success', () async {
      reply = systemWidgetStatusAppGroupUnavailable;
      final SystemWidgetsBridge bridge = SystemWidgetsBridge(
        loadArtwork: (String _) async => null,
      );
      await bridge.update(track: _track(), playing: true, language: 'ja');
      expect(bridge.status, SystemWidgetStatus.failed);
      expect(bridge.lastReason, contains('App Groups'));
    });
  });

  test('artwork bytes are published on their own lane', () async {
    final Uint8List png = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final List<Map<String, Object?>> published = <Map<String, Object?>>[];
    final SystemWidgetsBridge bridge = SystemWidgetsBridge(
      publish: (Map<String, Object?> data) async => published.add(data),
      loadArtwork: (String _) async => png,
    );
    await bridge.update(track: _track(), playing: true, language: 'en');
    // The title must not wait for the cover, and the cover must follow.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(published.first['artwork'], isNull);
    expect(published.last['artwork'], png);
    expect(jsonEncode(published.last)[0], '{');
  });
}
