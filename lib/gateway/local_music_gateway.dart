import 'music_gateway.dart';

/// The default connection is deliberately offline. Network catalogue and
/// playback only become available after the user installs a Lua plugin.
class LocalMusicGateway extends MusicGateway {
  @override
  MusicProvider get provider => const MusicProvider(id: 'local', name: '本地音乐');
  @override
  String get connectionId => 'local';
  @override
  MusicUser? get user => null;
  @override
  Set<MusicCapability> get capabilities => const {};
}
