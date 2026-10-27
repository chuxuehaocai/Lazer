// i18n:data
// The device list is the whole point of the hidden debug panel; audio_session
// still marks its device-type enum as experimental.
// ignore_for_file: experimental_member_use

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// A snapshot of the platform's audio endpoints and session attributes for
/// the hidden debug panel.
///
/// `audio_session` only enumerates devices on Android and iOS. On desktop and
/// web the call still succeeds but returns an empty set, which the panel turns
/// into an unsupported notice instead of an error.
@immutable
class AudioDeviceReport {
  const AudioDeviceReport({
    this.outputs = const <AudioDeviceInfo>[],
    this.attributes = const <AudioSessionAttribute>[],
    this.error,
  });

  /// Every connected output endpoint, sorted by name.
  final List<AudioDeviceInfo> outputs;

  /// Session settings captured at the same time.
  final List<AudioSessionAttribute> attributes;

  /// The failure text when the platform refused to answer at all.
  final String? error;

  static Future<AudioDeviceReport> collect() async {
    try {
      final AudioSession session = await AudioSession.instance;
      final Set<AudioDevice> devices = await session.getDevices(
        includeInputs: false,
        includeOutputs: true,
      );
      final List<AudioDeviceInfo> outputs =
          devices
              .where((AudioDevice device) => device.isOutput)
              .map(AudioDeviceInfo.fromDevice)
              .toList(growable: false)
            ..sort(
              (AudioDeviceInfo a, AudioDeviceInfo b) =>
                  a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      return AudioDeviceReport(
        outputs: outputs,
        attributes: _describeSession(session.configuration),
      );
    } catch (error) {
      return AudioDeviceReport(error: '$error');
    }
  }

  static List<AudioSessionAttribute> _describeSession(
    AudioSessionConfiguration? config,
  ) {
    final TargetPlatform platform = defaultTargetPlatform;
    final List<AudioSessionAttribute> attributes = <AudioSessionAttribute>[
      AudioSessionAttribute('平台', _platformLabel(platform)),
    ];
    if (config == null) return attributes;
    if (platform == TargetPlatform.iOS) {
      final AVAudioSessionCategory? category = config.avAudioSessionCategory;
      if (category != null) {
        attributes.add(AudioSessionAttribute('会话类别', category.name));
      }
      final AVAudioSessionMode? mode = config.avAudioSessionMode;
      if (mode != null) {
        attributes.add(AudioSessionAttribute('会话模式', mode.name));
      }
    } else if (platform == TargetPlatform.android) {
      final AndroidAudioAttributes? attributesConfig =
          config.androidAudioAttributes;
      if (attributesConfig != null) {
        attributes.add(
          AudioSessionAttribute('音频用途', _usageLabel(attributesConfig.usage)),
        );
        attributes.add(
          AudioSessionAttribute('内容类型', attributesConfig.contentType.name),
        );
      }
      attributes.add(
        AudioSessionAttribute(
          '音频焦点',
          _focusLabel(config.androidAudioFocusGainType),
        ),
      );
    }
    return attributes;
  }

  static String _focusLabel(AndroidAudioFocusGainType type) =>
      switch (type.index) {
        1 => 'gain',
        2 => 'gainTransient',
        3 => 'gainTransientMayDuck',
        4 => 'gainTransientExclusive',
        final int value => '#$value',
      };

  static String _platformLabel(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };

  static String _usageLabel(AndroidAudioUsage usage) => switch (usage.value) {
    0 => 'unknown',
    1 => 'media',
    2 => 'voiceCommunication',
    4 => 'alarm',
    5 => 'notification',
    14 => 'game',
    16 => 'assistant',
    final int value => '#$value',
  };
}

/// One label/value pair in [AudioDeviceReport.attributes].
@immutable
class AudioSessionAttribute {
  const AudioSessionAttribute(this.label, this.value);

  /// A Chinese translation key; the settings page resolves it through
  /// `context.tr`.
  final String label;

  /// The raw platform value, shown verbatim.
  final String value;
}

/// One output endpoint in [AudioDeviceReport].
@immutable
class AudioDeviceInfo {
  const AudioDeviceInfo({
    required this.id,
    required this.name,
    required this.typeLabel,
  });

  factory AudioDeviceInfo.fromDevice(AudioDevice device) => AudioDeviceInfo(
    id: device.id,
    name: device.name,
    typeLabel: deviceTypeLabel(device.type),
  );

  final String id;
  final String name;

  /// A Chinese translation key for the device type; the settings page
  /// resolves it through `context.tr`.
  final String typeLabel;

  static String deviceTypeLabel(AudioDeviceType type) => switch (type) {
    AudioDeviceType.builtInSpeaker => '内置扬声器',
    AudioDeviceType.builtInSpeakerSafe => '系统提示扬声器',
    AudioDeviceType.builtInEarpiece => '听筒',
    AudioDeviceType.wiredHeadset => '有线耳麦',
    AudioDeviceType.wiredHeadphones => '有线耳机',
    AudioDeviceType.bluetoothA2dp => '蓝牙（A2DP）',
    AudioDeviceType.bluetoothSco => '蓝牙（通话）',
    AudioDeviceType.bluetoothLe => '蓝牙（LE）',
    AudioDeviceType.usbAudio => 'USB 音频',
    AudioDeviceType.hdmi => 'HDMI',
    AudioDeviceType.hdmiArc => 'HDMI ARC',
    AudioDeviceType.displayPort => 'DisplayPort',
    AudioDeviceType.airPlay => 'AirPlay',
    AudioDeviceType.hearingAid => '助听器',
    AudioDeviceType.carAudio => '车载音频',
    AudioDeviceType.lineAnalog => '模拟线路',
    AudioDeviceType.lineDigital => '数字线路',
    AudioDeviceType.auxLine => 'AUX',
    AudioDeviceType.dock => '底座',
    AudioDeviceType.ip => '网络音频',
    AudioDeviceType.bus => '音频总线',
    AudioDeviceType.avb => 'AVB',
    AudioDeviceType.fireWire => 'FireWire',
    AudioDeviceType.pci => 'PCI',
    AudioDeviceType.thunderbolt => '雷雳',
    AudioDeviceType.virtual => '虚拟设备',
    AudioDeviceType.fm => 'FM',
    AudioDeviceType.fmTuner => 'FM 调谐器',
    AudioDeviceType.tvTuner => '电视调谐器',
    AudioDeviceType.telephony => '电话',
    AudioDeviceType.headsetMic => '耳麦麦克风',
    AudioDeviceType.builtInMic => '内置麦克风',
    AudioDeviceType.remoteSubmix => '远程混音',
    AudioDeviceType.unknown => '未知',
  };
}
