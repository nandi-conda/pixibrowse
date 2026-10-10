import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixibrowse/src/conda/cache/cache.dart';
import 'package:pixibrowse/src/conda/cache/cache_io.dart';
import 'package:pixibrowse/src/conda/channeldata.dart';
import 'package:pixibrowse/src/conda/repodata.dart';
import 'package:pixibrowse/src/search.dart';

Uint8List _json(Object value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  group('channeldata', () {
    test('reads fields of any shape', () {
      final info = parseChannelData(
        _json({
          'packages': {
            'numpy': {
              'summary': ' Array computing ',
              'description': 'NumPy is the fundamental package.',
              'license': 'BSD-3-Clause',
              'home': 'http://numpy.org/',
              'dev_url': ['https://github.com/numpy/numpy'],
              'subdirs': ['linux-64', 'osx-arm64'],
              'version': '2.5.3',
              'timestamp': 1789077156,
            },
            'odd': {
              'home': ['', 'https://a.example'],
              'subdirs': {'noarch': {}},
              'summary': '',
              'keywords': 'one',
            },
            'broken': 'not a map',
          },
        }),
        channel: 'conda-forge',
      );
      expect(info.keys, ['numpy', 'odd']);
      final numpy = info['numpy']!;
      expect(numpy.summary, 'Array computing');
      expect(numpy.summaryLower, 'array computing');
      expect(numpy.home, ['http://numpy.org/']);
      expect(numpy.devUrl, ['https://github.com/numpy/numpy']);
      expect(numpy.timestamp!.year, 2026);
      expect(numpy.toJson()['license'], 'BSD-3-Clause');
      final odd = info['odd']!;
      expect(odd.summary, isNull);
      expect(odd.home, ['https://a.example']);
      expect(odd.subdirs, ['noarch']);
      expect(odd.keywords, ['one']);
    });

    test('a channel without channeldata gives an empty map', () async {
      final client = RepodataClient(
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(await client.channelData('bioconda'), isEmpty);
    });
  });

  group('rankPackages', () {
    const names = ['numpy', 'numpy-docs', 'pandas', 'scipy', 'xarray'];
    const summaries = {
      'pandas': 'data structures built on numpy',
      'scipy': 'scientific computing',
      'xarray': 'n-d labeled arrays',
    };
    const descriptions = {
      'scipy': 'uses numpy arrays throughout',
      'xarray': 'works with numpy',
    };

    test('name hits first, then summaries, then descriptions', () {
      final hits = rankPackages('numpy', names,
          summary: (n) => summaries[n], description: (n) => descriptions[n]);
      expect(hits, [
        ('numpy', MatchKind.name),
        ('numpy-docs', MatchKind.name),
        ('pandas', MatchKind.summary),
        ('scipy', MatchKind.description),
        ('xarray', MatchKind.description),
      ]);
    });

    test('without metadata it is the plain name filter', () {
      expect(rankPackages('py', names).map((h) => h.$1),
          substringFilter('py', names, (n) => n));
    });

    test('short queries skip descriptions', () {
      final hits = rankPackages('nu', names,
          summary: (n) => null, description: (n) => descriptions[n]);
      expect(hits.map((h) => h.$2).toSet(), {MatchKind.name});
    });
  });

  group('cache', () {
    test('reuses fresh responses, revalidates stale ones', () async {
      var requests = 0;
      String? sentEtag;
      final cache = MemoryCache();
      final mock = MockClient((request) async {
        requests++;
        sentEtag = request.headers['If-None-Match'];
        if (sentEtag == '"v1"') return http.Response('', 304);
        return http.Response('hello', 200, headers: {'etag': '"v1"'});
      });
      final client = RepodataClient(client: mock, cache: cache);
      const url = 'https://example.org/c/noarch/repodata.json';
      expect(utf8.decode(await client.get(url)), 'hello');
      expect(utf8.decode(await client.get(url)), 'hello');
      expect(requests, 1);

      client.refresh();
      expect(utf8.decode(await client.get(url)), 'hello');
      expect(requests, 2);
      expect(sentEtag, '"v1"');
    });

    test('remembers missing files and serves stale data offline', () async {
      final cache = MemoryCache();
      var online = true;
      final mock = MockClient((request) async {
        if (!online) throw const SocketException('offline');
        return request.url.path.endsWith('missing')
            ? http.Response('', 404)
            : http.Response('data', 200);
      });
      final client = RepodataClient(
          client: mock, cache: cache, maxAge: Duration.zero);
      await expectLater(client.get('https://x.org/missing'),
          throwsA(isA<HttpStatusException>()));
      expect(cache.entries['https://x.org/missing']!.statusCode, 404);
      await client.get('https://x.org/present');
      online = false;
      expect(utf8.decode(await client.get('https://x.org/present')), 'data');
    });

    test('disk cache round-trips and picks a directory', () async {
      final dir = await Directory.systemTemp.createTemp('pixibrowse');
      addTearDown(() => dir.delete(recursive: true));
      final cache = DiskCache(dir);
      final url = 'https://conda.anaconda.org/conda-forge/${'x' * 300}';
      await cache.write(
        url,
        CachedResponse(
          statusCode: 200,
          bytes: Uint8List.fromList([1, 2, 3]),
          fetchedAt: DateTime.utc(2026),
          etag: 'e',
        ),
      );
      final back = await cache.read(url);
      expect(back!.bytes, [1, 2, 3]);
      expect(back.etag, 'e');
      expect(back.fetchedAt, DateTime.utc(2026));
      expect(await cache.read('https://other'), isNull);

      expect(cacheDirectory({'PIXIBROWSE_CACHE_DIR': '/c'}), '/c');
      if (Platform.isLinux) {
        expect(cacheDirectory({'XDG_CACHE_HOME': '/x'}), '/x/pixibrowse');
        expect(cacheDirectory({'HOME': '/h'}), '/h/.cache/pixibrowse');
      }
    });
  });
}
