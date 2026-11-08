import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/song_comments_controller.dart';

const _source = r'''
return {call=function(op,args)
  if op == "describe" then
    return {providers={{id="fixture",name="Fixture",capabilities={"comments"}}}}
  end
  if op == "comments" then
    return {total=3,hasMore=args.offset == 0,hot={{id="hot-1",content="热门",author="A",likedCount=2}},latest={{id="latest-"..tostring(args.offset),content="第"..tostring(args.offset),author="B",liked=false,likedCount=1}}}
  end
  if op == "setCommentLiked" then
    host.storage_set("last",args.commentId..":"..tostring(args.liked))
    return true
  end
  if op == "state" then return host.storage_get("last") end
  return {}
end}
''';
Future<LuaMusicGateway> _gateway(Directory dir) async {
  final runtime = LuaPluginRuntime(
    manifest: PluginManifest.fromJson(const {
      'id': 'fixture.comments',
      'name': 'Fixture',
      'version': '1.0.0',
      'provider': 'fixture',
      'apiVersion': 1,
      'permissions': {'storage': true},
    }),
    sources: const {'main.lua': _source},
    dataDirectory: dir.path,
  );
  await runtime.start();
  return LuaMusicGateway(
    runtime: runtime,
    provider: const MusicProvider(id: 'fixture', name: 'Fixture'),
    connectionId: 'fixture',
    declaredCapabilities: const {MusicCapability.comments},
  );
}

void main() {
  test(
    'Lua comments fetch, paginate and like through the neutral gateway',
    () async {
      final dir = await Directory.systemTemp.createTemp('lua-comments-');
      final gateway = await _gateway(dir);
      addTearDown(() async {
        gateway.close();
        await dir.delete(recursive: true);
      });
      final registry = GatewayRegistry()..add(gateway);
      final controller = SongCommentsController(registry);
      addTearDown(controller.dispose);
      final song = gateway.id(MusicEntityKind.song, 'song');
      await controller.openSong(song.cacheKey, accountId: 7);
      expect(controller.hot.single.id, 'hot-1');
      expect(controller.latest.single.id, 'latest-0');
      expect(controller.hasMore, isTrue);
      await controller.loadMore();
      expect(controller.latest.map((value) => value.id), [
        'latest-0',
        'latest-1',
      ]);
      await controller.toggleLike('hot-1');
      expect(await gateway.runtime.invoke('state'), 'hot-1:true');
    },
  );
  test('local source does not expose comments', () async {
    final controller = SongCommentsController(
      GatewayRegistry()..add(LocalMusicGateway()),
    );
    addTearDown(controller.dispose);
    await controller.openSong('local:local:song:file', accountId: 7);
    expect(controller.unsupported, isTrue);
    expect(controller.hot, isEmpty);
  });
}
