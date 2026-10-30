import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/utils/artwork.dart';
import 'package:lazer_nextgen/widgets/plate_art.dart';
import 'package:lazer_nextgen/widgets/artwork_image.dart';

const cover =
    'https://p1.music.126.net/Xgxfl8qPlwjRIoBDI-cPrg==/109951173819308049.jpg?param=1024y1024';

void main() {
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
      'https://p1.music.126.net/Xgxfl8qPlwjRIoBDI-cPrg==/109951173819308049.jpg?param=96y96',
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
      final resized = image.image as ResizeImage;
      expect(resized.width, (44 * dpr).ceil());
      expect((resized.imageProvider as ArtworkImage).url, sizedCover);
      image.errorBuilder!(
        tester.element(find.byType(Image)),
        NetworkImageLoadException(statusCode: 403, uri: Uri.parse(cover)),
        null,
      );
      await tester.pump();
      await tester.pump();
      final retried =
          (tester.widget<Image>(find.byType(Image)).image as ResizeImage)
                  .imageProvider
              as ArtworkImage;
      // CDN fallback is now handled once in the shared cache, rather than
      // restarting the same candidate sequence separately in each widget.
      expect(retried.url, sizedCover);
      const next = 'https://p1.music.126.net/another/123.jpg';
      await render(next);
      expect(
        ((tester.widget<Image>(find.byType(Image)).image as ResizeImage)
                    .imageProvider
                as ArtworkImage)
            .url,
        artworkUrlForSize(next, logicalEdge: 44, devicePixelRatio: dpr),
      );
    },
  );
}
