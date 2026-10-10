import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixibrowse/src/codec/msgpack.dart';
import 'package:pixibrowse/src/codec/zstd.dart';

import 'helpers.dart';

void main() {
  group('zstd', () {
    test('decodes a real conda-forge shard', () {
      final out = zstdDecode(fixture('numpy_shard.msgpack.zst'));
      expect(out.length, 361719);
      expect(fnv1a(out), 0xd6088e89);
    });

    test('decodes the info section of a real .conda archive', () {
      final out =
          zstdDecode(fixture('info-numpy-2.5.3-py315h11958a5_0.tar.zst'));
      expect(out.length, 410624);
      expect(fnv1a(out), 0xa021b6d5);
    });

    test('decodes raw blocks and concatenated frames', () {
      final a = List<int>.generate(250000, (i) => i * 7 & 0xFF);
      final b = [1, 2, 3];
      final out = zstdDecode(
        Uint8List.fromList([...zstdRawFrame(a), ...zstdRawFrame(b)]),
      );
      expect(out, [...a, ...b]);
    });

    test('rejects data that is not zstd', () {
      expect(
        () => zstdDecode(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(isA<ZstdFormatException>()),
      );
    });
  });

  group('msgpack', () {
    test('round-trips maps, lists, binaries and 64-bit integers', () {
      final value = {
        'name': 'numpy',
        'timestamp': 1788731990709,
        'size': 9394101,
        'depends': ['python', 'libgcc >=15'],
        'sha256': Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
        'noarch': null,
        'flag': true,
      };
      final decoded = msgpackDecode(msgpackEncode(value)) as Map;
      expect(decoded['name'], 'numpy');
      expect(decoded['timestamp'], 1788731990709);
      expect(decoded['size'], 9394101);
      expect(decoded['depends'], ['python', 'libgcc >=15']);
      expect(decoded['sha256'], [0xde, 0xad, 0xbe, 0xef]);
      expect(decoded['noarch'], isNull);
      expect(decoded['flag'], isTrue);
    });

    test('decodes fixints, negative ints and short strings', () {
      expect(msgpackDecode(Uint8List.fromList([0x05])), 5);
      expect(msgpackDecode(Uint8List.fromList([0xff])), -1);
      expect(msgpackDecode(Uint8List.fromList([0xa2, 0x68, 0x69])), 'hi');
      expect(msgpackDecode(Uint8List.fromList([0x92, 0x01, 0xc0])), [1, null]);
    });
  });
}
