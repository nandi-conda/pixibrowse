import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixibrowse/main.dart';
import 'package:pixibrowse/src/conda/repodata.dart';
import 'package:pixibrowse/src/install/pixi_runner.dart';
import 'package:pixibrowse/src/state.dart';

import 'helpers.dart';

const base = 'https://conda.anaconda.org/test-forge';

Uint8List hash(int n) => Uint8List.fromList(List.filled(32, n));
String hexOf(int n) => List.filled(32, n.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object?> record(String name, String version, String build,
        String subdir, {List<String> depends = const []}) =>
    {
      'name': name,
      'version': version,
      'build': build,
      'build_number': 0,
      'subdir': subdir,
      'depends': depends,
      'license': 'MIT',
      'timestamp': 1700000000000,
      'size': 1234,
      'sha256': hash(9),
    };

/// A fake channel: noarch and linux-64, sharded.
MockClient fakeChannel() {
  final indexes = {
    'noarch': {
      'tzdata': hash(1),
      'numpy-docs': hash(2),
    },
    'linux-64': {
      'numpy': hash(3),
      'python': hash(4),
    },
  };
  final shards = {
    hexOf(1): {
      'packages.conda': {
        'tzdata-2024a-h0_0.conda': record('tzdata', '2024a', 'h0_0', 'noarch'),
      },
    },
    hexOf(2): {'packages.conda': {}},
    hexOf(3): {
      'packages.conda': {
        'numpy-1.26.4-py312_0.conda':
            record('numpy', '1.26.4', 'py312_0', 'linux-64'),
        'numpy-2.0.0-py312_0.conda': record(
            'numpy', '2.0.0', 'py312_0', 'linux-64',
            depends: ['python >=3.12', 'libblas']),
      },
    },
    hexOf(4): {'packages.conda': {}},
  };
  final info = TarEncoder().encodeBytes(Archive()
    ..add(ArchiveFile.string('info/index.json', jsonEncode({
      ...record('numpy', '2.0.0', 'py312_0', 'linux-64',
          depends: ['python >=3.12', 'libblas']),
      'sha256': null,
      'depends': ['python >=3.12', 'libblas', 'libgcc'],
    })))
    ..add(ArchiveFile.string('info/about.json',
        jsonEncode({'summary': 'Array computing', 'home': 'https://numpy.org'})))
    ..add(ArchiveFile.string('info/paths.json', jsonEncode({
      'paths': [
        {'_path': 'lib/numpy/__init__.py', 'path_type': 'hardlink', 'size_in_bytes': 10},
        {'_path': 'bin/f2py', 'path_type': 'hardlink', 'size_in_bytes': 20},
      ],
    }))));
  final conda = ZipEncoder().encodeBytes(Archive()
    ..add(ArchiveFile.bytes(
        'info-numpy-2.0.0-py312_0.tar.zst', zstdRawFrame(info))));

  return MockClient((request) async {
    final url = request.url.toString();
    for (final MapEntry(key: subdir, value: names) in indexes.entries) {
      if (url == '$base/$subdir/repodata_shards.msgpack.zst') {
        return http.Response.bytes(
          zstdRawFrame(msgpackEncode({
            'version': 1,
            'info': {'base_url': '', 'shards_base_url': '', 'subdir': subdir},
            'shards': names,
          })),
          200,
        );
      }
    }
    for (final MapEntry(key: hex, value: shard) in shards.entries) {
      if (url.endsWith('/$hex.msgpack.zst')) {
        return http.Response.bytes(zstdRawFrame(msgpackEncode(shard)), 200);
      }
    }
    if (url == '$base/channeldata.json') {
      return http.Response(
        jsonEncode({
          'packages': {
            'numpy': {
              'summary': 'Array computing for Python',
              'description': 'The fundamental package for arrays.',
              'license': 'BSD-3-Clause',
              'home': 'https://numpy.org',
              'version': '2.0.0',
              'subdirs': ['linux-64'],
            },
            'tzdata': {'summary': 'Time zone data, used by numpy'},
            'python': {
              'summary': 'General purpose language',
              'description': 'Python is a language that numpy builds on.',
            },
          },
        }),
        200,
      );
    }
    if (url == '$base/linux-64/numpy-2.0.0-py312_0.conda') {
      return http.Response.bytes(conda, 200);
    }
    return http.Response('not found', 404);
  });
}

Future<BrowserState> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = BrowserState(
    client: RepodataClient(client: fakeChannel()),
    channels: ['test-forge'],
  );
  await tester.pumpWidget(PixiBrowseApp(state: state, followKde: false));
  await settle(
      tester, () => state.loadingChannels || state.loadingChannelData);
  return state;
}

Future<void> settle(WidgetTester tester, bool Function() busy) async {
  // Work started inside the test zone only advances when frames are pumped,
  // while isolates and real I/O need real time.
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
    if (!busy()) return;
  }
  fail('timed out waiting for the app');
}

void main() {
  // Never run the real pixi from tests.
  setUp(() => PixiRunner.instance = null);

  testWidgets('browses packages, versions, metadata and files', (tester) async {
    final state = await pumpApp(tester);
    expect(state.error, isNull);
    expect(state.availablePlatforms, ['linux-64', 'noarch']);
    expect(find.text('4 packages'), findsOneWidget);

    // Turn summaries off for the plain name filter.
    state.setSearchSummaries(false);
    await tester.enterText(find.byType(TextField).first, 'numpy');
    await tester.pump();
    expect(state.packages, ['numpy', 'numpy-docs']);

    await tester.tap(find.text('numpy').last);
    await settle(tester, () => state.loadingRecords);
    expect(find.text('▾ linux-64 (2)'), findsOneWidget);
    expect(state.versionRows[1].record!.version, '2.0.0');

    await tester.tap(find.textContaining('2.0.0').first);
    await settle(tester, () => state.loadingContents);
    expect(state.contents, isNotNull);
    expect(find.text('numpy 2.0.0'), findsOneWidget);
    expect(find.text('https://numpy.org'), findsOneWidget);

    // Everything is on one page: dependencies, patches and files together.
    expect(find.text('python >=3.12'), findsOneWidget);
    expect(find.text('Patches'), findsOneWidget);
    expect(find.textContaining('libgcc'), findsWidgets);
    expect(find.text('bin/f2py'), findsOneWidget);

    // Number keys fold sections away.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(find.text('python >=3.12'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(find.text('python >=3.12'), findsOneWidget);
  });

  testWidgets('keyboard navigation and instant dialogs', (tester) async {
    final state = await pumpApp(tester);
    // Packages are sorted: numpy, numpy-docs, python, tzdata.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(state.packages[state.packageIndex], 'python');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, () => state.loadingRecords);
    expect(state.selectedPackage, 'numpy');
    expect(state.focusedPane, Pane.versions);

    // The section header collapses with Enter on it.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('▸ linux-64 (2)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.selectedPackage, isNull);

    // Dialogs are fully shown after a single frame: no transition.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('Platforms').last, findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Select all'), findsNothing);
    expect(find.text('Select none'), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pump();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('letters typed into search are not shortcuts', (tester) async {
    final state = await pumpApp(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    for (final key in [LogicalKeyboardKey.keyP, LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyJ, LogicalKeyboardKey.slash]) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
    expect(find.text('Select none'), findsNothing);
    expect(find.text('Channels'), findsNothing);
    expect(state.packageIndex, 0);
    // Escape leaves the field; then shortcuts work again.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(state.packageIndex, 1);
  });

  testWidgets('summaries from channeldata: search, info panel, JSON',
      (tester) async {
    final state = await pumpApp(tester);
    expect(find.text('Array computing for Python'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'numpy');
    await tester.pump();
    // Name hits, then summary hits, then description hits.
    expect(state.packages, ['numpy', 'numpy-docs', 'tzdata', 'python']);
    expect(find.text('summary'), findsOneWidget);
    expect(find.text('description'), findsOneWidget);

    // `s` toggles summary search once the field lets go of the keyboard.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(state.packages, ['numpy', 'numpy-docs']);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();

    // Opening a package shows what channeldata says, no download needed.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, () => state.loadingRecords);
    expect(state.selectedRecord, isNull);
    expect(find.text('The fundamental package for arrays.'), findsOneWidget);
    expect(find.text('BSD-3-Clause'), findsOneWidget);
    expect(find.text('https://numpy.org'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.pump();
    final json = jsonDecode(copied!) as Map;
    expect(json['name'], 'numpy');
    expect(json['license'], 'BSD-3-Clause');
    expect(json['versions'], ['2.0.0', '1.26.4']);
    expect(find.text('Copied numpy as JSON'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Copied numpy as JSON'), findsNothing);

    // Install commands name the channel and copy with one click.
    expect(
      find.text('pixi workspace channel add test-forge && pixi add numpy'),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.content_copy).last);
    await tester.pump();
    expect(copied, 'pixi global install -c test-forge numpy');
    expect(
      find.text('Copied pixi global install -c test-forge numpy'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('refresh reloads the channel', (tester) async {
    final state = await pumpApp(tester);
    state.setPlatforms(['linux-64']);
    await settle(tester, () => state.loadingChannels);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(state.loadingChannels, isTrue);
    await settle(
        tester, () => state.loadingChannels || state.loadingChannelData);
    expect(state.selectedPlatforms, ['linux-64']);
    expect(state.channelInfo, isNotEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('searches every channel on prefix.dev', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final channel = fakeChannel();
    final queries = <Object?>[];
    final state = BrowserState(
      client: RepodataClient(
        client: MockClient((request) async {
          if (request.url.toString() != 'https://prefix.dev/api/graphql') {
            return channel.get(request.url, headers: request.headers);
          }
          queries.add((jsonDecode(request.body) as Map)['variables']);
          return http.Response(
            jsonEncode({
              'data': {
                'packages': {
                  'totalCount': 120,
                  'page': [
                    {
                      'name': 'numpy',
                      'summary': 'Array computing',
                      'platforms': ['linux-64', 'noarch'],
                      'channel': {'name': 'test-forge', 'baseUrl': '$base/'},
                    },
                  ],
                },
              },
            }),
            200,
          );
        }),
      ),
      channels: ['test-forge'],
      searchAllChannels: true,
    )..searchDelay = Duration.zero;
    await tester.pumpWidget(PixiBrowseApp(state: state, followKde: false));
    await tester.pump();
    expect(find.text('Type to search every channel on prefix.dev.'),
        findsOneWidget);
    // Nothing is downloaded until there is something to search for.
    expect(state.totalPackages, 0);

    await tester.enterText(find.byType(TextField).first, 'nump');
    await settle(tester, () => state.searchingAll);
    expect(queries, [
      {'query': 'nump', 'limit': 50},
    ]);
    expect(state.packages, ['test-forge/numpy']);
    expect(find.text('1 of 120'), findsOneWidget);
    expect(find.text('Array computing'), findsOneWidget);

    await tester.tap(find.text('numpy').last);
    await settle(tester, () => state.loadingRecords);
    expect(state.selectedPackage, 'numpy');
    expect(state.packageChannels, [base]);
    expect(state.recordsError, isNull);
    expect(find.text('▾ linux-64 (2)'), findsOneWidget);

    // Turning it off browses the chosen channels.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(state.searchAllChannels, isFalse);
    await settle(
        tester, () => state.loadingChannels || state.loadingChannelData);
    expect(state.totalPackages, 4);
    await tester.pump(const Duration(seconds: 3));
  });

  test('parses the TUI startup flags', () {
    final options =
        parseArgs(['-c', 'conda-forge', '--channel=bioconda', '-p', 'linux-64']);
    expect(options.channels, ['conda-forge', 'bioconda']);
    expect(options.platforms, ['linux-64']);
  });
}
