import '../audio/hifi_controller.dart';

// Browser builds do not import dart:ffi or probe a native library.
Map<String, Object?> pluginNativeAudioStatus(HifiController? hifi) => const {};
Map<String, Object?> pluginNativeAudioDevices(HifiController? hifi) => const {};
