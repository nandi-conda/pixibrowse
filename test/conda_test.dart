import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixibrowse/src/codec/msgpack.dart';
import 'package:pixibrowse/src/codec/zstd.dart';
import 'package:pixibrowse/src/conda/artifact.dart';
import 'package:pixibrowse/src/conda/models.dart';
import 'package:pixibrowse/src/conda/repodata.dart';
import 'package:pixibrowse/src/conda/version.dart';
import 'package:pixibrowse/src/search.dart';

import 'helpers.dart';

List<PackageRecord> numpyRecords() {
  final shard =
      msgpackDecode(zstdDecode(fixture('numpy_shard.msgpack.zst'))) as Map;
  return recordsFromRepodata(
    shard,
    subdir: 'linux-64',
    channel: 'conda-forge',
    baseUrl: 'https://conda.anaconda.org/conda-forge/linux-64/',
  );
}

void main() {
  group('CondaVersion', () {
    int cmp(String a, String b) =>
        CondaVersion.parse(a).compareTo(CondaVersion.parse(b));

    test('orders like conda', () {
      final ordered = [
        '0.4',
        '0.4.0',
        '0.4.1.rc',
        '0.4.1.RC',
        '0.4.1',
        '0.5a1',
        '0.5b3',
        '0.5C1',
        '0.5',
        '0.9.6',
        '0.960923',
        '1.0',
        '1.1dev1',
        '1.1a1',
        '1.1.0dev1',
        '1.1.a1',
        '1.1.0rc1',
        '1.1.0',
        '1.1.0post1',
        '1.1post1',
        '1996.07.12',
        '1!0.4.1',
        '1!3.1.1.6',
        '2!0.4.1',
      ];
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(cmp(ordered[i], ordered[i + 1]), lessThanOrEqualTo(0),
            reason: '${ordered[i]} <= ${ordered[i + 1]}');
      }
      expect(cmp('2.10', '2.9'), greaterThan(0));
      expect(cmp('1.0', '1.0.0'), 0);
    });
  });

  group('substringFilter', () {
    test('ranks earlier and shorter matches first', () {
      final names = ['libnumpy-dev', 'numpy-base', 'numpy', 'pynumpy'];
      expect(substringFilter('NumPy ', names, (n) => n),
          ['numpy', 'numpy-base', 'pynumpy', 'libnumpy-dev']);
      expect(substringFilter('', names, (n) => n), names);
      expect(substringFilter('zzz', names, (n) => n), isEmpty);
    });
  });

  group('repodata', () {
    test('parses a shard into records with hex checksums and URLs', () {
      final records = numpyRecords();
      expect(records.length, 537 + 271);
      final record = records.firstWhere(
          (r) => r.fileName == 'numpy-2.5.3-py315h11958a5_0.conda');
      expect(record.version, '2.5.3');
      expect(record.subdir, 'linux-64');
      expect(record.sha256,
          '178de8890fa33a5e208a4085ead6c5863cb7081b9b2ef4f872012dd8cdd55a54');
      expect(record.url,
          'https://conda.anaconda.org/conda-forge/linux-64/numpy-2.5.3-py315h11958a5_0.conda');
      expect(record.timestamp, DateTime.utc(2026, 9, 6, 21, 59, 50, 709));
      expect(record.depends, contains('libgcc >=15'));
      expect(record.runExports['weak'], ['numpy >=1.25,<3']);
    });

    test('sorts newest first', () {
      final records = numpyRecords()..sort(PackageRecord.newestFirst);
      for (var i = 0; i + 1 < records.length; i++) {
        expect(
          records[i].parsedVersion.compareTo(records[i + 1].parsedVersion),
          greaterThanOrEqualTo(0),
        );
      }
    });

    test('resolves CEP 16 base URLs', () {
      const index =
          'https://conda.anaconda.org/conda-forge/linux-64/repodata_shards.msgpack.zst';
      expect(resolveBase(index, ''),
          'https://conda.anaconda.org/conda-forge/linux-64/');
      expect(resolveBase(index, 'shards'),
          'https://conda.anaconda.org/conda-forge/linux-64/shards/');
      expect(resolveBase(index, 'https://example.com/x/'),
          'https://example.com/x/');
    });

    test('maps channel names to URLs', () {
      expect(channelUrl('bioconda'), 'https://conda.anaconda.org/bioconda');
      expect(channelUrl('https://prefix.dev/conda-forge/'),
          'https://prefix.dev/conda-forge');
      expect(normalizeChannels([' a ', '', 'b', 'a']), ['a', 'b']);
    });
  });

  group('artifact', () {
    test('reads files, about.json and index.json from a .conda archive', () {
      final archive = Archive()
        ..add(ArchiveFile.bytes('metadata.json', '{}'.codeUnits))
        ..add(ArchiveFile.bytes('info-numpy-2.5.3-py315h11958a5_0.tar.zst',
            fixture('info-numpy-2.5.3-py315h11958a5_0.tar.zst')));
      final conda = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      final contents = readArtifactBytes(conda, conda: true);
      expect(contents.files.length, 1335);
      expect(contents.infoFiles.length, 15);
      expect(contents.indexJson?['version'], '2.5.3');
      expect(contents.aboutJson, isNotNull);
      expect(contents.files.first.path.compareTo(contents.files.last.path),
          lessThan(0));
    });

    test('reports repodata patches against index.json', () {
      final record = numpyRecords().firstWhere(
          (r) => r.fileName == 'numpy-2.5.3-py315h11958a5_0.conda');
      final index = <String, Object?>{
        ...record.raw,
        'arch': 'x86_64',
        'platform': 'linux',
      };
      expect(repodataPatches(index, record), isEmpty);

      final patched = Map<String, Object?>.of(index)
        ..['depends'] = ['python', 'libgcc'];
      final rows = repodataPatches(patched, record);
      expect(rows.map((r) => r.label), ['depends']);
      expect(rows.single.original, 'python\nlibgcc');
    });
  });
}
