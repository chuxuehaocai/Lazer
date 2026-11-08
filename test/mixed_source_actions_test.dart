import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'support/music_gateway.dart';
class _Account extends TestMusicGateway {
  _Account(this.connectionId,this.features);
  @override final String connectionId;
  final Set<MusicCapability> features;
  @override Set<MusicCapability> get capabilities=>features;
  final calls=<String>[];
  @override Future<Map<String,dynamic>> listenTogether(String operation,[Map<String,dynamic> args=const {}])async {
    calls.add(operation);
    if(operation=='command') {expect((args['command'] as Map).containsKey('userId'),isFalse);}
    return {'roomId':'opaque-room','inviterId':'owner-user','members':[{'userId':'opaque-user','name':'Listener'}]};
  }
}
class _Catalog extends Catalog {
  _Catalog():super(cache:DiskCache(directory:()async=>throw const FileSystemException('disabled')),
    lyricsCache:CachedLyricsStore(supportDirectory:()async=>throw const FileSystemException('disabled')));
  @override Future<HomeFeed?> loadHome({int? userId})async=>null;
  @override Future<UserCollections> userCollections(int uid)async=>UserCollections.empty;
  @override Future<UserCollections?> cachedUserCollections(int uid)async=>null;
  @override Future<GatewayLyrics?> lyricsFor(Track track)async=>const GatewayLyrics(pureMusic:true);
}
Track song(MusicGateway gateway)=>Track(id:gateway.id(MusicEntityKind.song,'opaque-song').cacheKey,title:'Song',artist:'Artist',album:'Album',duration:const Duration(minutes:3),coverSeed:0);
void main(){
  setUp(()=>SharedPreferences.setMockInitialValues({}));
  test('player capabilities follow each song owner while browsing another source',()async {
    final catalog=_Catalog();final first=_Account('one',{MusicCapability.comments});final second=_Account('two',{MusicCapability.listenTogether});
    catalog.connections.add(first);catalog.connections.add(second);final state=AppState(catalog:catalog);addTearDown(state.dispose);
    await state.selectMusicConnection(GatewayRegistry.keyOf(second));state.playQueue([song(first)]);state.pause();
    expect(state.supportsCurrentMusic(MusicCapability.comments),isTrue);expect(state.supportsCurrentMusic(MusicCapability.listenTogether),isFalse);
    expect(state.supportsMusic(MusicCapability.listenTogether),isTrue);
  });
  test('room creation, refresh, commands and leave use the playing connection in local mode',()async {
    final catalog=_Catalog();final owner=_Account('one',{MusicCapability.listenTogether});catalog.connections.add(owner);
    final state=AppState(catalog:catalog);addTearDown(state.dispose);
    await state.selectMusicConnection(GatewayRegistry.keyOf(owner));await state.signInWithCookie('fixture');
    state.playQueue([song(owner)]);state.pause();await state.selectMusicConnection('local:local');
    expect(await state.listenTogether.create(),isTrue);expect(state.listenTogether.members.single.userId,'opaque-user');
    await state.listenTogether.refresh();await state.listenTogether.leave();
    expect(owner.calls,containsAll(['create','command','heartbeat','status','leave']));expect(state.isLocalPlayback,isTrue);
  });
}
