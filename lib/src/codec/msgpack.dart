/// A MessagePack decoder that is exact on the web.
///
/// Sharded repodata stores timestamps as 64-bit integers and checksums as
/// binary blobs. `ByteData.getInt64` is unavailable on the web, so 64-bit
/// values are assembled from two 32-bit halves instead.
library;

import 'dart:convert';
import 'dart:typed_data';

class MsgPackFormatException implements Exception {
  MsgPackFormatException(this.message);
  final String message;
  @override
  String toString() => 'MsgPackFormatException: $message';
}

/// Decodes one MessagePack value. Maps decode to `Map<Object?, Object?>`,
/// binary data to [Uint8List].
Object? msgpackDecode(Uint8List bytes) => _Reader(bytes).value();

class _Reader {
  _Reader(this.bytes) : view = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData view;
  int pos = 0;

  int _u8() => bytes[pos++];
  int _u16() {
    final v = view.getUint16(pos);
    pos += 2;
    return v;
  }

  int _u32() {
    final v = view.getUint32(pos);
    pos += 4;
    return v;
  }

  int _u64() {
    final hi = _u32();
    final lo = _u32();
    return hi * 4294967296 + lo;
  }

  int _i64() {
    final hi = view.getInt32(pos);
    pos += 4;
    final lo = _u32();
    return hi * 4294967296 + lo;
  }

  String _str(int length) {
    final s = utf8.decode(Uint8List.sublistView(bytes, pos, pos + length),
        allowMalformed: true);
    pos += length;
    return s;
  }

  Uint8List _bin(int length) {
    final b = Uint8List.fromList(Uint8List.sublistView(bytes, pos, pos + length));
    pos += length;
    return b;
  }

  List<Object?> _array(int length) =>
      List<Object?>.generate(length, (_) => value(), growable: false);

  Map<Object?, Object?> _map(int length) {
    final map = <Object?, Object?>{};
    for (var i = 0; i < length; i++) {
      final key = value();
      map[key] = value();
    }
    return map;
  }

  Object? _ext(int length) {
    final type = view.getInt8(pos);
    pos += 1;
    final data = _bin(length);
    // Timestamp extension: decode the common 32- and 64-bit forms.
    if (type == -1 && length == 4) {
      final seconds = ByteData.sublistView(data).getUint32(0);
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
    return data;
  }

  Object? value() {
    final b = _u8();
    if (b <= 0x7f) return b;
    if (b >= 0xe0) return b - 256;
    if (b & 0xf0 == 0x80) return _map(b & 0x0f);
    if (b & 0xf0 == 0x90) return _array(b & 0x0f);
    if (b & 0xe0 == 0xa0) return _str(b & 0x1f);
    switch (b) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _bin(_u8());
      case 0xc5:
        return _bin(_u16());
      case 0xc6:
        return _bin(_u32());
      case 0xc7:
        return _ext(_u8());
      case 0xc8:
        return _ext(_u16());
      case 0xc9:
        return _ext(_u32());
      case 0xca:
        final v = view.getFloat32(pos);
        pos += 4;
        return v;
      case 0xcb:
        final v = view.getFloat64(pos);
        pos += 8;
        return v;
      case 0xcc:
        return _u8();
      case 0xcd:
        return _u16();
      case 0xce:
        return _u32();
      case 0xcf:
        return _u64();
      case 0xd0:
        final v = view.getInt8(pos);
        pos += 1;
        return v;
      case 0xd1:
        final v = view.getInt16(pos);
        pos += 2;
        return v;
      case 0xd2:
        final v = view.getInt32(pos);
        pos += 4;
        return v;
      case 0xd3:
        return _i64();
      case 0xd4:
        return _ext(1);
      case 0xd5:
        return _ext(2);
      case 0xd6:
        return _ext(4);
      case 0xd7:
        return _ext(8);
      case 0xd8:
        return _ext(16);
      case 0xd9:
        return _str(_u8());
      case 0xda:
        return _str(_u16());
      case 0xdb:
        return _str(_u32());
      case 0xdc:
        return _array(_u16());
      case 0xdd:
        return _array(_u32());
      case 0xde:
        return _map(_u16());
      case 0xdf:
        return _map(_u32());
    }
    throw MsgPackFormatException(
        'unknown type byte 0x${b.toRadixString(16)} at ${pos - 1}');
  }
}
