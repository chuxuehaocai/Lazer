import '../state/app_state.dart';

/// The browser has no `audio_service` host, so system lock-screen controls are
/// not published. The shared entry point still constructs this controller.
class SystemMediaController {
  SystemMediaController(AppState state);

  Future<void> get settled => Future<void>.value();

  void close() {}
}
