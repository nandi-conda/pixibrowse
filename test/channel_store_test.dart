import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixibrowse/src/conda/repodata.dart';
import 'package:pixibrowse/src/settings/channel_store.dart';
import 'package:pixibrowse/src/settings/channel_store_io.dart';
import 'package:pixibrowse/src/state.dart';

void main() {
  test('config directory follows the platform convention', () {
    expect(configDirectory({'PIXIBROWSE_CONFIG_DIR': '/c'}), '/c');
    if (Platform.isLinux) {
      expect(configDirectory({'XDG_CONFIG_HOME': '/x'}), '/x/pixibrowse');
      expect(configDirectory({'HOME': '/h'}), '/h/.config/pixibrowse');
    }
  });

  test('file store round-trips and shrugs off bad files', () {
    final dir = Directory.systemTemp.createTempSync('pixibrowse-config');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/sub/channels.json');
    final store = FileChannelStore(file);
    expect(store.load(), isNull);
    store.save(['conda-forge', 'bioconda']);
    expect(FileChannelStore(file).load(), ['conda-forge', 'bioconda']);
    file.writeAsStringSync('not json');
    expect(store.load(), isNull);
    file.writeAsStringSync('{"channels": 1}');
    expect(store.load(), isNull);
  });

  test('state starts on saved channels and saves edits', () async {
    final store = MemoryChannelStore(['bioconda']);
    expect(BrowserState(channelStore: store).channels, ['bioconda']);
    // Channels given on the command line win for that run.
    expect(BrowserState(channels: ['pytorch'], channelStore: store).channels, [
      'pytorch',
    ]);
    expect(store.channels, ['bioconda']);
    expect(BrowserState(channelStore: MemoryChannelStore()).channels, [
      'conda-forge',
    ]);

    final state = BrowserState(
      client: RepodataClient(
        client: MockClient((_) async => http.Response('', 404)),
      ),
      channelStore: store,
    );
    await state.setChannels([' conda-forge', 'nvidia', 'nvidia']);
    expect(store.channels, ['conda-forge', 'nvidia']);
    await state.setChannels(['nvidia']);
    expect(store.channels, ['nvidia']);
  });
}
