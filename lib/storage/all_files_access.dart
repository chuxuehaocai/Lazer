import 'dart:io';

import 'package:flutter/services.dart';

class AllFilesAccess {
  const AllFilesAccess({this.android});
  final bool? android;
  static const channel = MethodChannel('dev.naominet.lazer/local_media');

  Future<bool> hasAccess() => _call('hasAllFilesAccess');
  Future<bool> requestAccess() => _call('requestAllFilesAccess');

  Future<bool> _call(String method) async {
    if (!(android ?? Platform.isAndroid)) return true;
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
