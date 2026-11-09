import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/podcast_feed.dart';

void main() {
  const PodcastFeedParser parser = PodcastFeedParser();

  test('RSS 2.0 reads channel metadata and iTunes durations', () {
    final PodcastFeed feed = parser.parse('''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Night Show</title>
    <description>&lt;p&gt;Talk &amp;amp; music&lt;/p&gt;</description>
    <itunes:author>Host</itunes:author>
    <itunes:image href="http://img.example/cover.jpg"/>
    <item>
      <title>Episode One</title>
      <guid>ep-1</guid>
      <pubDate>Mon, 06 May 2024 07:08:09 GMT</pubDate>
      <itunes:duration>1:02:03</itunes:duration>
      <enclosure url="http://a.example/1.mp3" length="12345" type="audio/mpeg"/>
    </item>
    <item>
      <title>Episode Two</title>
      <guid>ep-2</guid>
      <pubDate>Tue, 07 May 2024 07:08:09 GMT</pubDate>
      <enclosure url="http://a.example/2.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>
''', feedUrl: 'https://podcast.example/feed.xml');
    expect(feed.title, 'Night Show');
    expect(feed.description, 'Talk & music');
    expect(feed.imageUrl, 'http://img.example/cover.jpg');
    expect(feed.author, 'Host');
    expect(feed.episodes.length, 2);
    // Newest first.
    expect(feed.episodes.first.title, 'Episode Two');
    final PodcastEpisode one = feed.episodes.last;
    expect(one.id, podcastEpisodeId('ep-1', one.audioUrl));
    expect(one.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(one.bytes, 12345);
    expect(one.publishedAt?.toUtc(), DateTime.utc(2024, 5, 6, 7, 8, 9));
  });

  test('Atom entries use enclosure links', () {
    final PodcastFeed feed = parser.parse('''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Show</title>
  <subtitle>Weekly</subtitle>
  <author><name>Host</name></author>
  <entry>
    <id>tag:show,2024:1</id>
    <title>First</title>
    <published>2024-05-06T07:08:09Z</published>
    <summary>A summary</summary>
    <link rel="enclosure" type="audio/mpeg" href="http://a.example/1.mp3"/>
    <link rel="alternate" href="http://a.example/episode/1"/>
  </entry>
</feed>
''', feedUrl: 'https://atom.example/feed.xml');
    expect(feed.title, 'Atom Show');
    expect(feed.author, 'Host');
    expect(feed.episodes.single.audioUrl, 'http://a.example/1.mp3');
    expect(feed.episodes.single.title, 'First');
    expect(feed.episodes.single.publishedAt?.toUtc(), DateTime.utc(2024, 5, 6, 7, 8, 9));
  });

  test('entries without an audio attachment are skipped', () {
    final PodcastFeed feed = parser.parse(
      '<rss><channel><title>T</title><item><title>No audio</title>'
      '<link>http://a.example/page</link></item></channel></rss>',
      feedUrl: 'https://x/feed',
    );
    expect(feed.episodes, isEmpty);
  });

  test('media:content is accepted when enclosure is missing', () {
    final PodcastFeed feed = parser.parse(
      '<rss xmlns:media="http://search.yahoo.com/mrss/"><channel>'
      '<title>T</title><item><title>With media</title>'
      '<media:content url="http://a.example/1.mp3" type="audio/mpeg"/>'
      '</item></channel></rss>',
      feedUrl: 'https://x/feed',
    );
    expect(feed.episodes.single.audioUrl, 'http://a.example/1.mp3');
  });

  test('HTML in descriptions becomes plain text', () {
    final PodcastFeed feed = parser.parse(
      '<rss><channel><title>T</title><item><title>E</title>'
      '<description>Hello &lt;b&gt;world&lt;/b&gt; &amp; friends &amp;#39;quoted&amp;#39;</description>'
      '<enclosure url="http://a.example/1.mp3"/></item></channel></rss>',
      feedUrl: 'https://x/feed',
    );
    expect(feed.episodes.single.description, "Hello world & friends 'quoted'");
  });

  test('a malformed document raises the user-facing exception', () {
    expect(
      () => parser.parse('<html>nope</html>', feedUrl: 'https://x/feed'),
      throwsA(isA<PodcastFeedException>()),
    );
    expect(
      () => parser.parse('<<<not xml', feedUrl: 'https://x/feed'),
      throwsA(isA<PodcastFeedException>()),
    );
  });

  test('episode lists are capped and sorted', () {
    final StringBuffer items = StringBuffer();
    for (int i = 0; i < PodcastFeedParser.maxEpisodes + 20; i++) {
      items.write(
        '<item><title>E$i</title><guid>g$i</guid>'
        '<pubDate>${HttpDate.format(DateTime.utc(2024, 1, 1).add(Duration(days: i)))}</pubDate>'
        '<enclosure url="http://a.example/$i.mp3"/></item>',
      );
    }
    final PodcastFeed feed = parser.parse(
      '<rss><channel><title>T</title>$items</channel></rss>',
      feedUrl: 'https://x/feed',
    );
    expect(feed.episodes.length, PodcastFeedParser.maxEpisodes);
    expect(
      feed.episodes.first.publishedAt!.isAfter(feed.episodes.last.publishedAt!),
      isTrue,
    );
  });
}
