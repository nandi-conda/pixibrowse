import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixibrowse/src/conda/prefix.dart';

void main() {
  test('recognises prefix.dev channels', () {
    expect(
      prefixDevChannelName('https://prefix.dev/nandi-testing'),
      'nandi-testing',
    );
    expect(
      prefixDevChannelName('https://repo.prefix.dev/nandi-testing/'),
      'nandi-testing',
    );
    expect(prefixDevChannelName('conda-forge'), isNull);
    expect(prefixDevChannelName('https://conda.anaconda.org/x'), isNull);
    expect(prefixDevChannelName('https://notprefix.dev/x'), isNull);
  });

  test(
    'reads the newest variant listed, raw records as objects or strings',
    () {
      final info = parsePrefixDevPackage(
        {
          'data': {
            'package': {
              'name': 'zumba',
              'description': 'Top-level description',
              'variants': {
                'page': [
                  {
                    'version': '0.1.0',
                    'rawAbout': {'summary': 'old'},
                    'rawIndex': {},
                  },
                  {
                    'version': '0.10.0',
                    'rawAbout': jsonEncode({
                      'summary': 'Conda channel browser',
                      'home': 'https://github.com/codegod100/zumba',
                    }),
                    'rawIndex': {'license': 'MIT', 'timestamp': 1789077156000},
                  },
                ],
              },
            },
          },
        },
        name: 'zumba',
        channel: 'https://prefix.dev/nandi-testing',
      )!;
      expect(info.summary, 'Conda channel browser');
      expect(info.description, 'Top-level description');
      expect(info.license, 'MIT');
      expect(info.home, ['https://github.com/codegod100/zumba']);
      expect(info.version, isNull);
      expect(info.timestamp!.year, 2026);
      expect(info.channel, 'https://prefix.dev/nandi-testing');
    },
  );

  test('a missing package is null, an error throws', () {
    expect(
      parsePrefixDevPackage(
        {
          'data': {'package': null},
        },
        name: 'x',
        channel: 'https://prefix.dev/c',
      ),
      isNull,
    );
    expect(
      () => parsePrefixDevPackage(
        {
          'errors': [
            {'message': 'boom'},
          ],
        },
        name: 'x',
        channel: 'https://prefix.dev/c',
      ),
      throwsA(isA<PrefixDevException>()),
    );
  });

  test('posts the query with variables', () async {
    late Map<String, Object?> sent;
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), prefixDevGraphqlUrl);
      sent = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response(
        jsonEncode({
          'data': {
            'package': {
              'name': 'zumba',
              'variants': {
                'page': [
                  {
                    'version': '1.0',
                    'rawAbout': {'summary': 'hi'},
                  },
                ],
              },
            },
          },
        }),
        200,
      );
    });
    final info = await fetchPrefixDevPackage(
      client,
      'https://prefix.dev/nandi-testing',
      'zumba',
    );
    expect(info!.summary, 'hi');
    expect(sent['variables'], {'channel': 'nandi-testing', 'name': 'zumba'});
    expect(await fetchPrefixDevPackage(client, 'conda-forge', 'zumba'), isNull);
  });
}
