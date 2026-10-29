import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Decode and normalize a gateway response without blocking the UI on large
/// payloads. Small responses avoid the overhead of spawning an isolate.
Future<Map<String, dynamic>> decodeGatewayResponse(String body) =>
    body.length < 65536
    ? Future<Map<String, dynamic>>.value(_decode(body))
    : compute(_decode, body, debugLabel: 'gateway-response-decode');

Map<String, dynamic> _decode(String body) {
  final dynamic decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) throw const FormatException();
  return _normalizeFields(decoded);
}

Map<String, dynamic> _normalizeFields(
  Map<String, dynamic> element,
) => element.map((String key, dynamic value) {
  final String name = key == 'avatarImgId_str' ? 'avatarImgIdStr' : key;
  if (value is Map<String, dynamic>) {
    return MapEntry<String, dynamic>(name, _normalizeFields(value));
  }
  if (value is List) {
    return MapEntry<String, dynamic>(
      name,
      value
          .map<dynamic>(
            (dynamic item) =>
                item is Map<String, dynamic> ? _normalizeFields(item) : item,
          )
          .toList(),
    );
  }
  return MapEntry<String, dynamic>(name, value);
});
