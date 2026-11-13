import 'package:lazer_nextgen/utils/media_requests.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/utils/artwork.dart';
import 'package:lazer_nextgen/widgets/plate_art.dart';
import 'package:lazer_nextgen/widgets/artwork_image.dart';

const cover =
    'https://p1.images.test/Xgxfl8qPlwjRIoBDI-cPrg==/109951173819308049.jpg?param=1024y1024';

void main() {
  setUp(
    () => MediaRequestRules.register('fixture', [
      {
        'host': '*.images.test',
        'artworkResize': {'parameter': 'param', 'value': '{size}y{size}'},
        'fallbackHosts': ['p2.images.test', 'p3.images.test', 'p4.images.test'],
      },
    ]),
  );
  tearDown(() => MediaRequestRules.remove('fixture'));
  test('public covers survive snapshots while signed URLs are renewed', () {
    expect(persistableArtworkUrl(cover), cover);
    expect(
      persistableArtworkUrl('https://images.test/album.jpg'),
      'https://images.test/album.jpg',
    );
    expect(
      persistableArtworkUrl('file:///music/cover.jpg'),
      'file:///music/cover.jpg',
    );
    for (final url in [
      'https://images.test/album.jpg?token=private',
      'http://localhost/rest/getCoverArt.view?id=cover&t=private&s=salt',
      'https://images.test/album.jpg?X-Amz-Signature=private',
      'https://user:private@images.test/album.jpg',
      'https://images.test/album.jpg#private',
    ]) {
      expect(persistableArtworkUrl(url), isNull);
    }
  });

  test('CDN alternatives preserve the image path and remove resize only', () {
    final urls = artworkCandidates(cover);
    expect(urls.first, cover);
    expect(Uri.parse(urls[1]).query, isEmpty);
    expect(urls.toSet().length, urls.length);
    for (final url in urls) {
      expect(Uri.parse(url).path, Uri.parse(cover).path);
      expect(Uri.parse(url).scheme, 'https');
    }
    expect(artworkCandidates('https://example.com/image.jpg'), <String>[
      'https://example.com/image.jpg',
    ]);
  });

  test('artwork requests the smallest rendition for the painted size', () {
    expect(artworkPixelSize(44, 1), 64);
    expect(artworkPixelSize(44, 2), 96);
    expect(artworkPixelSize(160, 1.25), 256);
    expect(artworkPixelSize(null, 1), 1024);
    expect(artworkPixelSize(2000, 1), 1024);
    expect(
      artworkUrlForSize(cover, logicalEdge: 44, devicePixelRatio: 2),
      'https://p1.images.test/Xgxfl8qPlwjRIoBDI-cPrg==/109951173819308049.jpg?param=96y96',
    );
  });

  test('watermark covers keep their signed query when a size is asked for', () {
    const String watermarked =
        'https://p1.images.test/Xgxfl8qPlwjRIoBDI-cPrg==/109951173819308049.jpg'
        '?imageView=1&thumbnail=800y800&enlarge=1%7CimageView=1&watermark'
        '&type=1&image=abc%3D%3D&dx=0&dy=0%7Cwatermark&type=1&image=def=='
        '&dx=0&dy=0%7CimageView=1';
    final String sized = artworkUrlForSize(
      watermarked,
      logicalEdge: 384,
      devicePixelRatio: 2,
    )!;
    // Every original byte survives: the repeated keys and %7C separators are
    // what the CDN signs, and rebuilding the query is what answered 400.
    expect(sized, startsWith(watermarked));
    expect(sized, endsWith('&param=768y768'));
    expect('&param='.allMatches(sized).length, 1);
    // The transform chain is public, so a cached shelf keeps the same cover.
    expect(persistableArtworkUrl(watermarked), watermarked);
    final List<String> candidates = artworkCandidates(sized);
    expect(candidates.first, sized);
    expect(candidates, contains(watermarked));
    expect(
      candidates.every(
        (String url) =>
            url.contains('type=1&image=abc%3D%3D&dx=0&dy=0%7Cwatermark'),
      ),
      isTrue,
    );
    // A sibling host keeps the same raw query instead of re-encoding it.
    expect(
      candidates.where(
        (String url) => url.startsWith('https://p2.images.test/'),
      ),
      hasLength(1),
    );
  });

  testWidgets(
    'artwork failure keeps one provider and changing cover updates its cache key',
    (tester) async {
      final double dpr = tester.view.devicePixelRatio;
      Future<void> render(String url) => tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 100,
            height: 100,
            child: PlateArt(seed: 1, coverUrl: url, size: 44),
          ),
        ),
      );
      await render(cover);
      final image = tester.widget<Image>(find.byType(Image));
      final String sizedCover = artworkUrlForSize(
        cover,
        logicalEdge: 44,
        devicePixelRatio: dpr,
      )!;
      final provider = image.image as ArtworkImage;
      expect(provider.targetSize, artworkPixelSize(44, dpr));
      expect(provider.url, sizedCover);
      image.errorBuilder!(
        tester.element(find.byType(Image)),
        NetworkImageLoadException(statusCode: 403, uri: Uri.parse(cover)),
        null,
      );
      await tester.pump();
      await tester.pump();
      final retried =
          tester.widget<Image>(find.byType(Image)).image as ArtworkImage;
      // CDN fallback is now handled once in the shared cache, rather than
      // restarting the same candidate sequence separately in each widget.
      expect(retried.url, sizedCover);
      const next = 'https://p1.images.test/another/123.jpg';
      await render(next);
      expect(
        (tester.widget<Image>(find.byType(Image)).image as ArtworkImage).url,
        artworkUrlForSize(next, logicalEdge: 44, devicePixelRatio: dpr),
      );
    },
  );
}
