import '../audio/hifi_controller.dart';

/// Fixed-size native snapshots, independent of player cadence. Device reads use
/// the controller's existing catalog: no scan, USB permission or device open.
Map<String, Object?> pluginNativeAudioStatus(HifiController? hifi) {
  final info = hifi?.streamInfo;
  final path = info?.outputPath;
  final metrics = hifi?.readMetrics();
  return {
    'engine': 'lazer-audio',
    'streamOpen': info != null,
    'source': info == null
        ? null
        : {
            'codec': info.codec,
            'sampleRate': info.sourceSampleRate,
            'channels': info.sourceChannels,
            'bitsPerSample': info.sourceBitsPerSample,
            'formatKind': info.sourceFormatKind,
            'dsdRateMultiplier': info.sourceDsdRateMultiplier,
            'lossless': info.lossless,
          },
    'output': info == null
        ? null
        : {
            'initialized': info.outputFormatInitialized,
            'sampleRate': info.outputSampleRate,
            'channels': info.outputChannels,
            'bitsPerSample': info.outputBitsPerSample,
            'containerBitsPerSample': info.outputContainerBitsPerSample,
            'isFloat': info.outputIsFloat,
            'exclusive': info.outputExclusive,
            'formatKind': info.outputFormatKind,
            'dsdRateMultiplier': info.outputDsdRateMultiplier,
            'dspActive': info.dspActive,
            'formatMatchesSource': info.formatMatchesSource,
            'bitPerfect': path!.bitPerfect,
            'agreesWithEngine': path.agreesWithEngine,
            'scope': 'engine-negotiated-not-dac-readback',
          },
    'metrics': metrics == null
        ? null
        : {
            'ringFillFrames': metrics.ringFillFrames,
            'ringCapacityFrames': metrics.ringCapacityFrames,
            'ringLowWatermarkFrames': metrics.ringLowWatermarkFrames,
            'ringHighWatermarkFrames': metrics.ringHighWatermarkFrames,
            'underrunActive': metrics.underrunActive,
            'underrunFrames': metrics.underrunFrames,
          },
  };
}

Map<String, Object?> pluginNativeAudioDevices(HifiController? hifi) {
  final devices = hifi?.devices;
  final selected = hifi?.selectedDevice;
  return {
    'snapshot': 'cached-catalog',
    'busy': hifi?.busy ?? false,
    'total': devices?.length ?? 0,
    'truncated': (devices?.length ?? 0) > 64,
    'items': [
      for (var i = 0; i < (devices?.length ?? 0) && i < 64; i++)
        {
          'index': i,
          'name': devices![i].displayName.length > 256
              ? devices[i].displayName.substring(0, 256)
              : devices[i].displayName,
          'isDefault': devices[i].isDefault,
          'isActive': devices[i].isActive,
          'isSelected': identical(devices[i], selected),
        },
    ],
  };
}
