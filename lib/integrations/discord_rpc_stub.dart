import '../state/app_state.dart';

class DiscordRpcController {
  DiscordRpcController(AppState state);
  Future<void> get settled => Future<void>.value();
  void dispose() {}
}
