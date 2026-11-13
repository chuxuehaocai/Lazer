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
    // Public CDN transform chains, not credentials: NetEase decorates
    // editorial covers with `imageView/thumbnail/enlarge/watermark` and a
    // repeated `type/image/dx/dy` pair. Keeping them lets a cached shelf show
    // the same cover it showed live; anything unknown is still treated as
    // possibly signed and is dropped from snapshots.
    'imageview',
    'thumbnail',
    'enlarge',
    'watermark',
    'type',
    'image',
    'dx',
    'dy',
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
  return _withQueryParameter(
    url,
    hint['parameter'] as String,
    (hint['value'] as String).replaceAll('{size}', '$sizePx'),
  );
}

/// Sets or removes one query parameter without touching the rest of the URL.
///
/// CDN artwork is not always a plain `?w=…`: NetEase's editorial covers carry
/// a transform chain that repeats keys (`type`, `image`, `dx`, `dy`) and keeps
/// encoded separators inside values (`enlarge=1%7CimageView=1`). Rebuilding the
/// query from a decoded map collapses those repeats and re-encodes `%7C`/`==`,
/// and the service answers 400 — which is why those covers never loaded. Editing
/// the raw string keeps every byte the service produced.
String _withQueryParameter(String url, String name, String? value) {
  final int hash = url.indexOf('#');
  final String body = hash < 0 ? url : url.substring(0, hash);
  final String fragment = hash < 0 ? '' : url.substring(hash);
  final int mark = body.indexOf('?');
  final String head = mark < 0 ? body : body.substring(0, mark);
  final String query = mark < 0 ? '' : body.substring(mark + 1);
  final List<String> kept = <String>[];
  bool written = false;
  for (final String part in query.split('&')) {
    if (part.isEmpty) continue;
    final int equals = part.indexOf('=');
    final String key = equals < 0 ? part : part.substring(0, equals);
    if (_sameQueryKey(key, name)) {
      if (value != null && !written) {
        kept.add('$key=$value');
        written = true;
      }
      continue;
    }
    kept.add(part);
  }
  if (value != null && !written) kept.add('$name=$value');
  if (kept.isEmpty) return '$head$fragment';
  return '$head?${kept.join('&')}$fragment';
}

bool _sameQueryKey(String raw, String name) {
  if (raw == name) return true;
  try {
    return Uri.decodeQueryComponent(raw) == name;
  } on ArgumentError {
    return false;
  } on FormatException {
    return false;
  }
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
  final String original = parameter is String
      ? _withQueryParameter(preferred, parameter, null)
      : preferred;
  return <String>{
    preferred,
    original,
    for (final host
        in (rule['fallbackHosts'] as List? ?? const [])
            .whereType<String>()
            .take(4))
      _withHost(original, host),
  }.toList(growable: false);
}

/// Moves an artwork URL to a sibling CDN host, keeping its raw query.
String _withHost(String url, String host) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return url;
  return uri.replace(host: host).toString();
}

String? _localArtworkUrl(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  return trimmed.startsWith('file://') ? trimmed : null;
}
