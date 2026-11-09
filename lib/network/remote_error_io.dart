import 'dart:io';

/// Classifies a `dart:io` transport failure for [RemoteFailure.from].
({String kind, String? detail})? classifyPlatformError(Object error) {
  if (error is HandshakeException) {
    return (kind: 'tls', detail: error.message);
  }
  if (error is SocketException) {
    return (kind: 'unreachable', detail: error.osError?.message ?? error.message);
  }
  if (error is HttpException) {
    return (kind: 'io', detail: error.message);
  }
  if (error is TlsException) {
    return (kind: 'tls', detail: error.message);
  }
  return null;
}
