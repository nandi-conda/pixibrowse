import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

int fnv1a(Uint8List bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h;
}

Uint8List fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

/// Wraps [data] in a zstd frame made of raw blocks.
Uint8List zstdRawFrame(List<int> data) {
  final out = BytesBuilder()
    ..add([0x28, 0xB5, 0x2F, 0xFD])
    // Descriptor: no content size, not single segment; window descriptor.
    ..add([0x00, 0x58]);
  const maxBlock = 100000;
  var pos = 0;
  do {
    final size = (data.length - pos).clamp(0, maxBlock);
    final last = pos + size >= data.length ? 1 : 0;
    final header = last | (0 << 1) | (size << 3);
    out.add([header & 0xFF, (header >> 8) & 0xFF, (header >> 16) & 0xFF]);
    out.add(data.sublist(pos, pos + size));
    pos += size;
  } while (pos < data.length);
  return out.toBytes();
}

/// A small MessagePack encoder for building test repodata.
Uint8List msgpackEncode(Object? value) {
  final out = BytesBuilder();
  void write(Object? v) {
    if (v == null) {
      out.addByte(0xc0);
    } else if (v is bool) {
      out.addByte(v ? 0xc3 : 0xc2);
    } else if (v is int) {
      if (v >= 0 && v < 128) {
        out.addByte(v);
      } else if (v >= 0 && v < 0x100000000) {
        out.addByte(0xce);
        out.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
      } else {
        out.addByte(0xcf);
        out.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
      }
    } else if (v is String) {
      final bytes = utf8.encode(v);
      out.addByte(0xda);
      out.add((ByteData(2)..setUint16(0, bytes.length)).buffer.asUint8List());
      out.add(bytes);
    } else if (v is Uint8List) {
      out.addByte(0xc4);
      out.addByte(v.length);
      out.add(v);
    } else if (v is List) {
      out.addByte(0xdc);
      out.add((ByteData(2)..setUint16(0, v.length)).buffer.asUint8List());
      v.forEach(write);
    } else if (v is Map) {
      out.addByte(0xde);
      out.add((ByteData(2)..setUint16(0, v.length)).buffer.asUint8List());
      v.forEach((key, value) {
        write(key);
        write(value);
      });
    } else {
      throw ArgumentError('cannot encode $v');
    }
  }

  write(value);
  return out.toBytes();
}
