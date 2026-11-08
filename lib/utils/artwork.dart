import 'media_requests.dart';

/// Keeps public artwork in snapshots without persisting signed request URLs.
/// Unknown query parameters are resolved again through the owning gateway.
String? persistableArtworkUrl(String? raw) {
  final value = raw?.trim() ?? '';
  final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
  if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment) return null;
  if (uri.scheme == 'file') return value;
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    return null;
  }
  const publicParameters = {
    'param',
    'w',
    'h',
    'width',
    'height',
    'size',
    'quality',
    'q',
    'fit',
    'crop',
    'format',
    'fm',
    'auto',
    'dpr',
    'id',
    'coverid',
    'imageid',
    'v',
    'version',
  };
  if (uri.queryParameters.keys.any(
    (key) => !publicParameters.contains(key.toLowerCase()),
  )) {
    return null;
  }
  return value;
}

/// Normalizes network artwork without assuming a provider's URL convention.
String? normalizedArtworkUrl(String? raw) {
  final value = raw?.trim() ?? '';
  final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

String? enlargedArtworkUrl(String? raw, {int sizePx = 1024}) {
  final url = normalizedArtworkUrl(raw);
  if (url == null) return _localArtworkUrl(raw);
  final uri = Uri.parse(url);
  final hint = MediaRequestRules.rule(uri)?['artworkResize'];
  if (hint is! Map ||
      hint['parameter'] is! String ||
      hint['value'] is! String) {
    return url;
  }
  return uri
      .replace(
        queryParameters: {
          ...uri.queryParameters,
          hint['parameter'] as String: (hint['value'] as String).replaceAll(
            '{size}',
            '$sizePx',
          ),
        },
      )
      .toString();
}

/// Renditions the CDN is asked for. Quantising to this ladder keeps one
/// decoded image per display size instead of one per widget instance.
const List<int> kArtworkRenditions = <int>[
  64,
  96,
  128,
  192,
  256,
  384,
  512,
  768,
  1024,
];

/// The smallest rendition that covers [logicalEdge] at [devicePixelRatio].
int artworkPixelSize(double? logicalEdge, double devicePixelRatio) {
  if (logicalEdge == null || !logicalEdge.isFinite || logicalEdge <= 0) {
    return kArtworkRenditions.last;
  }
  final double dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1;
  final int needed = (logicalEdge * dpr).ceil();
  for (final int size in kArtworkRenditions) {
    if (needed <= size) return size;
  }
  return kArtworkRenditions.last;
}

/// A CDN-sized artwork URL for a widget painted at [logicalEdge].
String? artworkUrlForSize(
  String? raw, {
  double? logicalEdge,
  double devicePixelRatio = 1,
}) => enlargedArtworkUrl(
  raw,
  sizePx: artworkPixelSize(logicalEdge, devicePixelRatio),
);

/// Provider-declared alternatives, bounded to avoid unending CDN retries.
List<String> artworkCandidates(String? raw) {
  final preferred = normalizedArtworkUrl(raw) ?? _localArtworkUrl(raw);
  if (preferred == null) return const [];
  final uri = Uri.parse(preferred);
  final rule = MediaRequestRules.rule(uri);
  if (rule == null) return [preferred];
  final parameter = (rule['artworkResize'] as Map?)?['parameter'];
  final query = Map<String, String>.of(uri.queryParameters);
  if (parameter is String) query.remove(parameter);
  final original = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: query.isEmpty ? null : query,
    fragment: uri.hasFragment ? uri.fragment : null,
  );
  return <String>{
    preferred,
    original.toString(),
    for (final host
        in (rule['fallbackHosts'] as List? ?? const [])
            .whereType<String>()
            .take(4))
      original.replace(host: host).toString(),
  }.toList(growable: false);
}

String? _localArtworkUrl(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  return trimmed.startsWith('file://') ? trimmed : null;
}
