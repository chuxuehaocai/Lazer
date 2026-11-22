import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_library.dart';
import 'local_media_permission.dart';
import 'local_music_scanner.dart';

/// Set once a launch has looked for music on this device, so an empty music
/// folder is not rescanned on every start.
const String localAutoScanKey = 'lazer_local_music_autoscan_v1';

/// Fills a fresh install with the music already sitting in this device's music
/// folder.
///
/// A new install has no music connection until a plugin is added, and every
/// shelf stays empty until then. Scanning the usual folder once makes the
/// first launch playable without any setup. The scan runs in the background
/// after the app state finishes bootstrapping, and only when the library is
/// still empty.
///
/// Returns the scan result, or null when nothing was scanned.
Future<LocalScanResult?> autoScanLocalMusicOnce(
  LocalLibrary library, {
  LocalMusicScanner? scanner,
  Directory? root,
}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(localAutoScanKey) ?? false) return null;
  if (library.tracks.isNotEmpty) {
    await prefs.setBool(localAutoScanKey, true);
    return null;
  }
  final LocalMusicScanner scan = scanner ?? LocalMusicScanner();
  // A permission prompt over the first frame hides the shell behind a system
  // dialog, so mobile keeps the explicit scan button in the empty state.
  if (Platform.isAndroid || Platform.isIOS) {
    if (!await const LocalMediaPermission().hasAccess()) return null;
  }
  final Directory? target = root ?? await scan.defaultRoot();
  if (target == null || !await target.exists()) {
    await prefs.setBool(localAutoScanKey, true);
    return null;
  }
  // The attempt is remembered before the walk starts: a crash mid-scan must not
  // turn into a rescan on every launch.
  await prefs.setBool(localAutoScanKey, true);
  final LocalScanResult result;
  try {
    result = await scan.scan(target, existing: library.tracks);
  } catch (_) {
    return null;
  }
  if (result.tracks.isEmpty) return result;
  await library.addScanRoot(target.path);
  await library.addTracks(result.tracks);
  await library.refreshMissing();
  return result;
}
