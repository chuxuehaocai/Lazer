/// What the player should release when a one-shot sleep timer expires.
enum SleepTimerAction {
  /// Pause playback but keep the normal media session available.
  pause,

  /// Pause playback, release audio focus and remove the media foreground
  /// service/notification while keeping the app open.
  releaseAudio,
}
