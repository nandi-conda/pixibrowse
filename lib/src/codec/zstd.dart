/// A Zstandard (RFC 8878) decompressor in plain Dart.
///
/// Conda channels serve sharded repodata and `.conda` archive members as
/// zstd frames. The Dart zstd packages either wrap libzstd (no web) or carry
/// 56-bit integers through their bit readers (wrong on JavaScript), so this
/// decoder keeps every intermediate value below 2^32 and combines wider
/// values with multiplication. It runs unchanged on the VM and on the web.
///
/// Dictionaries are not supported; conda channels never use them. Content
/// checksums are skipped rather than verified.
library;

import 'dart:typed_data';

class ZstdFormatException implements Exception {
  ZstdFormatException(this.message);
  final String message;
  @override
  String toString() => 'ZstdFormatException: $message';
}

/// Decompresses every frame in [input] and returns the concatenated output.
Uint8List zstdDecode(Uint8List input) => _FrameDecoder(input).decodeAll();

const int _zstdMagic = 0xFD2FB528;

// Literal length codes: baseline and number of extra bits.
const List<int> _llBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
];
const List<int> _llBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16,
];

// Match length codes: baseline and number of extra bits.
const List<int> _mlBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, //
  19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
  35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
  4099, 8195, 16387, 32771, 65539,
];
const List<int> _mlBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
  12, 13, 14, 15, 16,
];

const List<int> _llDefaultDist = [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
  -1, -1, -1, -1,
];
const List<int> _mlDefaultDist = [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
  -1, -1, -1, -1, -1,
];
const List<int> _ofDefaultDist = [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
];

int _highBit(int value) {
  // Index of the highest set bit of a positive value below 2^32.
  var n = -1;
  while (value > 0) {
    value >>= 1;
    n++;
  }
  return n;
}

/// Growable output buffer that also serves as the match history.
class _Output {
  _Output(int capacity) : bytes = Uint8List(capacity < 64 ? 64 : capacity);
  Uint8List bytes;
  int length = 0;

  void _ensure(int extra) {
    final needed = length + extra;
    if (needed <= bytes.length) return;
    var size = bytes.length * 2;
    while (size < needed) {
      size *= 2;
    }
    final grown = Uint8List(size);
    grown.setRange(0, length, bytes);
    bytes = grown;
  }

  void addRange(Uint8List source, int start, int end) {
    final count = end - start;
    _ensure(count);
    bytes.setRange(length, length + count, source, start);
    length += count;
  }

  void addRepeated(int byte, int count) {
    _ensure(count);
    bytes.fillRange(length, length + count, byte);
    length += count;
  }

  void copyMatch(int offset, int count, int frameStart) {
    if (offset <= 0 || offset > length - frameStart) {
      throw ZstdFormatException('match offset $offset outside the window');
    }
    _ensure(count);
    final b = bytes;
    var src = length - offset;
    var dst = length;
    if (offset >= count) {
      b.setRange(dst, dst + count, b, src);
    } else {
      for (var i = 0; i < count; i++) {
        b[dst++] = b[src++];
      }
    }
    length += count;
  }

  Uint8List toBytes() => Uint8List.sublistView(bytes, 0, length);
}

/// Reads bits backwards, from the end of a stream towards its start, the way
/// zstd's FSE and Huffman streams are laid out.
class _BackwardBits {
  _BackwardBits(this.data, this.start, this.end) {
    if (end <= start) throw ZstdFormatException('empty bitstream');
    final last = data[end - 1];
    if (last == 0) throw ZstdFormatException('bitstream without end marker');
    bitPos = (end - 1 - start) * 8 + _highBit(last);
  }

  final Uint8List data;
  final int start;
  final int end;

  /// Number of bits not read yet; negative once the stream has overflowed.
  late int bitPos;

  int _byte(int index) {
    final at = start + index;
    return index < 0 || at >= end ? 0 : data[at];
  }

  /// Bits `[lo, lo + n)` of the stream, `n <= 16`, `lo >= 0`.
  int _extract(int lo, int n) {
    final i = lo >> 3;
    final v = _byte(i) | (_byte(i + 1) << 8) | (_byte(i + 2) << 16);
    return (v >> (lo & 7)) & ((1 << n) - 1);
  }

  int _peekSmall(int n) {
    if (n == 0) return 0;
    final lo = bitPos - n;
    if (lo >= 0) return _extract(lo, n);
    final available = bitPos > 0 ? bitPos : 0;
    if (available == 0) return 0;
    return _extract(0, available) << (n - available);
  }

  /// Returns the next [n] bits without consuming them, `n <= 16`.
  int peek(int n) => _peekSmall(n);

  void skip(int n) => bitPos -= n;

  int read(int n) {
    if (n <= 16) {
      final v = _peekSmall(n);
      bitPos -= n;
      return v;
    }
    final hi = read(n - 16);
    final lo = read(16);
    return hi * 65536 + lo;
  }

  bool get overflowed => bitPos < 0;
  bool get finished => bitPos == 0;
}

/// Reads bits forwards, least significant bit first.
class _ForwardBits {
  _ForwardBits(this.data, this.start, this.end);
  final Uint8List data;
  final int start;
  final int end;
  int bitPos = 0;

  int _byte(int index) {
    final at = start + index;
    return at < end ? data[at] : 0;
  }

  int peek(int n) {
    final i = bitPos >> 3;
    final v = _byte(i) | (_byte(i + 1) << 8) | (_byte(i + 2) << 16);
    return (v >> (bitPos & 7)) & ((1 << n) - 1);
  }

  int read(int n) {
    final v = peek(n);
    bitPos += n;
    return v;
  }

  int get bytesConsumed => (bitPos + 7) >> 3;
}

class _FseTable {
  _FseTable(this.accuracyLog)
      : symbol = Uint8List(1 << accuracyLog),
        nbBits = Uint8List(1 << accuracyLog),
        base = Int32List(1 << accuracyLog);

  final int accuracyLog;
  final Uint8List symbol;
  final Uint8List nbBits;
  final Int32List base;

  factory _FseTable.fromDistribution(List<int> probs, int accuracyLog) {
    final table = _FseTable(accuracyLog);
    final size = 1 << accuracyLog;
    var highThreshold = size - 1;
    final next = List<int>.filled(probs.length, 0);
    for (var s = 0; s < probs.length; s++) {
      if (probs[s] == -1) {
        table.symbol[highThreshold--] = s;
        next[s] = 1;
      } else {
        next[s] = probs[s];
      }
    }
    final step = (size >> 1) + (size >> 3) + 3;
    final mask = size - 1;
    var pos = 0;
    for (var s = 0; s < probs.length; s++) {
      for (var i = 0; i < probs[s]; i++) {
        table.symbol[pos] = s;
        do {
          pos = (pos + step) & mask;
        } while (pos > highThreshold);
      }
    }
    if (pos != 0) throw ZstdFormatException('invalid FSE distribution');
    for (var u = 0; u < size; u++) {
      final s = table.symbol[u];
      final nextState = next[s]++;
      final bits = accuracyLog - _highBit(nextState);
      table.nbBits[u] = bits;
      table.base[u] = (nextState << bits) - size;
    }
    return table;
  }

  factory _FseTable.rle(int symbol) {
    final table = _FseTable(0);
    table.symbol[0] = symbol;
    return table;
  }

  /// Reads an FSE table description starting at [start]. Returns the table
  /// and the number of bytes the description took.
  static (_FseTable, int) read(
    Uint8List data,
    int start,
    int end,
    int maxAccuracyLog,
    int maxSymbol,
  ) {
    final bits = _ForwardBits(data, start, end);
    final accuracyLog = bits.read(4) + 5;
    if (accuracyLog > maxAccuracyLog) {
      throw ZstdFormatException('FSE accuracy log $accuracyLog too large');
    }
    var remaining = (1 << accuracyLog) + 1;
    var threshold = 1 << accuracyLog;
    var nbBits = accuracyLog + 1;
    final probs = <int>[];
    while (remaining > 1 && probs.length <= maxSymbol) {
      final max = (2 * threshold - 1) - remaining;
      int count;
      final low = bits.peek(nbBits - 1);
      if (low < max) {
        count = low;
        bits.bitPos += nbBits - 1;
      } else {
        count = bits.peek(nbBits);
        if (count >= threshold) count -= max;
        bits.bitPos += nbBits;
      }
      count--;
      remaining -= count < 0 ? -count : count;
      probs.add(count);
      if (count == 0) {
        while (true) {
          final repeat = bits.read(2);
          for (var i = 0; i < repeat; i++) {
            probs.add(0);
          }
          if (repeat != 3) break;
        }
      }
      while (remaining < threshold) {
        nbBits--;
        threshold >>= 1;
      }
    }
    if (remaining != 1 || probs.length > maxSymbol + 1) {
      throw ZstdFormatException('corrupt FSE table description');
    }
    return (_FseTable.fromDistribution(probs, accuracyLog), bits.bytesConsumed);
  }
}

class _HuffmanTable {
  _HuffmanTable(this.maxBits)
      : symbol = Uint8List(1 << maxBits),
        nbBits = Uint8List(1 << maxBits);
  final int maxBits;
  final Uint8List symbol;
  final Uint8List nbBits;

  factory _HuffmanTable.fromWeights(List<int> weights) {
    var sum = 0;
    for (final w in weights) {
      if (w > 0) sum += 1 << (w - 1);
    }
    if (sum == 0) throw ZstdFormatException('empty Huffman weights');
    final maxBits = _highBit(sum) + 1;
    final leftover = (1 << maxBits) - sum;
    if (leftover & (leftover - 1) != 0) {
      throw ZstdFormatException('Huffman weights do not complete a tree');
    }
    final all = [...weights, _highBit(leftover) + 1];
    if (maxBits > 11) throw ZstdFormatException('Huffman code too long');
    final table = _HuffmanTable(maxBits);
    var pos = 0;
    for (var w = 1; w <= maxBits; w++) {
      final span = 1 << (w - 1);
      final bits = maxBits + 1 - w;
      for (var s = 0; s < all.length; s++) {
        if (all[s] != w) continue;
        table.symbol.fillRange(pos, pos + span, s);
        table.nbBits.fillRange(pos, pos + span, bits);
        pos += span;
      }
    }
    return table;
  }

  /// Reads a Huffman tree description; returns the table and its byte size.
  static (_HuffmanTable, int) read(Uint8List data, int start, int end) {
    final header = data[start];
    final weights = <int>[];
    int consumed;
    if (header < 128) {
      final compressedEnd = start + 1 + header;
      if (compressedEnd > end) throw ZstdFormatException('truncated weights');
      final (fse, tableSize) =
          _FseTable.read(data, start + 1, compressedEnd, 6, 255);
      final bits = _BackwardBits(data, start + 1 + tableSize, compressedEnd);
      var state1 = bits.read(fse.accuracyLog);
      var state2 = bits.read(fse.accuracyLog);
      while (weights.length < 255) {
        weights.add(fse.symbol[state1]);
        state1 = fse.base[state1] + bits.read(fse.nbBits[state1]);
        if (bits.overflowed) {
          weights.add(fse.symbol[state2]);
          break;
        }
        weights.add(fse.symbol[state2]);
        state2 = fse.base[state2] + bits.read(fse.nbBits[state2]);
        if (bits.overflowed) {
          weights.add(fse.symbol[state1]);
          break;
        }
      }
      consumed = 1 + header;
    } else {
      final count = header - 127;
      final bytes = (count + 1) >> 1;
      if (start + 1 + bytes > end) throw ZstdFormatException('truncated weights');
      for (var i = 0; i < count; i++) {
        final b = data[start + 1 + (i >> 1)];
        weights.add(i.isEven ? b >> 4 : b & 0xF);
      }
      consumed = 1 + bytes;
    }
    return (_HuffmanTable.fromWeights(weights), consumed);
  }

  void decodeStream(
    Uint8List data,
    int start,
    int end,
    Uint8List out,
    int outStart,
    int outEnd,
  ) {
    final bits = _BackwardBits(data, start, end);
    for (var i = outStart; i < outEnd; i++) {
      final index = bits.peek(maxBits);
      out[i] = symbol[index];
      bits.skip(nbBits[index]);
    }
    if (!bits.finished) throw ZstdFormatException('Huffman stream size mismatch');
  }
}

class _FrameDecoder {
  _FrameDecoder(this.data);
  final Uint8List data;
  int pos = 0;

  // State that lives for the duration of one frame.
  late _Output out;
  int frameStart = 0;
  _HuffmanTable? huffman;
  _FseTable? llTable;
  _FseTable? ofTable;
  _FseTable? mlTable;
  final List<int> rep = [1, 4, 8];

  int _u8() => data[pos++];
  int _le16(int at) => data[at] | (data[at + 1] << 8);
  int _le24(int at) => _le16(at) | (data[at + 2] << 16);
  int _le32(int at) => _le24(at) + data[at + 3] * 16777216;

  Uint8List decodeAll() {
    out = _Output(data.length * 4);
    while (pos < data.length) {
      if (data.length - pos < 4) throw ZstdFormatException('trailing bytes');
      final magic = _le32(pos);
      if ((magic & 0xFFFFFFF0) == 0x184D2A50) {
        final size = _le32(pos + 4);
        pos += 8 + size;
        continue;
      }
      if (magic != _zstdMagic) throw ZstdFormatException('not a zstd frame');
      pos += 4;
      _decodeFrame();
    }
    return out.toBytes();
  }

  void _decodeFrame() {
    final descriptor = _u8();
    final fcsFlag = descriptor >> 6;
    final singleSegment = (descriptor >> 5) & 1 == 1;
    final hasChecksum = (descriptor >> 2) & 1 == 1;
    final dictIdFlag = descriptor & 3;
    if (descriptor & 0x08 != 0) throw ZstdFormatException('reserved bit set');
    if (!singleSegment) pos++; // Window descriptor; history is kept whole.
    const dictIdSizes = [0, 1, 2, 4];
    var dictId = 0;
    for (var i = 0; i < dictIdSizes[dictIdFlag]; i++) {
      dictId |= data[pos + i] << (8 * i);
    }
    pos += dictIdSizes[dictIdFlag];
    if (dictId != 0) throw ZstdFormatException('dictionaries are unsupported');
    final fcsSize = switch (fcsFlag) {
      0 => singleSegment ? 1 : 0,
      1 => 2,
      2 => 4,
      _ => 8,
    };
    var contentSize = -1;
    if (fcsSize == 1) contentSize = data[pos];
    if (fcsSize == 2) contentSize = _le16(pos) + 256;
    if (fcsSize == 4) contentSize = _le32(pos);
    if (fcsSize == 8) contentSize = _le32(pos) + _le32(pos + 4) * 4294967296;
    pos += fcsSize;
    if (contentSize > 0 && out.length == 0 && contentSize < 1 << 30) {
      out = _Output(contentSize);
    }

    frameStart = out.length;
    huffman = null;
    llTable = ofTable = mlTable = null;
    rep
      ..[0] = 1
      ..[1] = 4
      ..[2] = 8;

    var last = false;
    while (!last) {
      final header = _le24(pos);
      pos += 3;
      last = header & 1 == 1;
      final type = (header >> 1) & 3;
      final size = header >> 3;
      switch (type) {
        case 0:
          out.addRange(data, pos, pos + size);
          pos += size;
        case 1:
          out.addRepeated(data[pos], size);
          pos += 1;
        case 2:
          _decodeCompressedBlock(pos, pos + size);
          pos += size;
        default:
          throw ZstdFormatException('reserved block type');
      }
    }
    if (hasChecksum) pos += 4;
  }

  void _decodeCompressedBlock(int start, int end) {
    final (literals, afterLiterals) = _decodeLiterals(start, end);
    _decodeSequences(afterLiterals, end, literals);
  }

  (Uint8List, int) _decodeLiterals(int start, int end) {
    final b0 = data[start];
    final type = b0 & 3;
    final sizeFormat = (b0 >> 2) & 3;
    if (type == 0 || type == 1) {
      int regenerated;
      int headerSize;
      switch (sizeFormat) {
        case 0 || 2:
          regenerated = b0 >> 3;
          headerSize = 1;
        case 1:
          regenerated = (b0 >> 4) + (data[start + 1] << 4);
          headerSize = 2;
        default:
          regenerated =
              (b0 >> 4) + (data[start + 1] << 4) + (data[start + 2] << 12);
          headerSize = 3;
      }
      final from = start + headerSize;
      if (type == 0) {
        return (Uint8List.sublistView(data, from, from + regenerated),
            from + regenerated);
      }
      return (Uint8List(regenerated)..fillRange(0, regenerated, data[from]),
          from + 1);
    }

    int regenerated;
    int compressed;
    int headerSize;
    final b1 = data[start + 1];
    final b2 = data[start + 2];
    switch (sizeFormat) {
      case 0 || 1:
        final v = b0 | (b1 << 8) | (b2 << 16);
        regenerated = (v >> 4) & 0x3FF;
        compressed = (v >> 14) & 0x3FF;
        headerSize = 3;
      case 2:
        final b3 = data[start + 3];
        regenerated = (b0 >> 4) | (b1 << 4) | ((b2 & 0x3) << 12);
        compressed = (b2 >> 2) | (b3 << 6);
        headerSize = 4;
      default:
        final b3 = data[start + 3];
        final b4 = data[start + 4];
        regenerated = (b0 >> 4) | (b1 << 4) | ((b2 & 0x3F) << 12);
        compressed = (b2 >> 6) | (b3 << 2) | (b4 << 10);
        headerSize = 5;
    }
    final singleStream = sizeFormat == 0;
    var streamStart = start + headerSize;
    final streamsEnd = streamStart + compressed;
    if (streamsEnd > end) throw ZstdFormatException('literals overrun block');
    if (type == 2) {
      final (table, size) = _HuffmanTable.read(data, streamStart, streamsEnd);
      huffman = table;
      streamStart += size;
    }
    final table = huffman;
    if (table == null) throw ZstdFormatException('treeless literals first');
    final literals = Uint8List(regenerated);
    if (singleStream) {
      table.decodeStream(data, streamStart, streamsEnd, literals, 0, regenerated);
    } else {
      final s1 = _le16(streamStart);
      final s2 = _le16(streamStart + 2);
      final s3 = _le16(streamStart + 4);
      final p1 = streamStart + 6;
      final p2 = p1 + s1;
      final p3 = p2 + s2;
      final p4 = p3 + s3;
      if (p4 > streamsEnd) throw ZstdFormatException('bad jump table');
      final segment = (regenerated + 3) >> 2;
      table.decodeStream(data, p1, p2, literals, 0, segment);
      table.decodeStream(data, p2, p3, literals, segment, 2 * segment);
      table.decodeStream(data, p3, p4, literals, 2 * segment, 3 * segment);
      table.decodeStream(
          data, p4, streamsEnd, literals, 3 * segment, regenerated);
    }
    return (literals, streamsEnd);
  }

  _FseTable _readTable(
    int mode,
    int maxLog,
    int maxSymbol,
    List<int> defaults,
    int defaultLog,
    _FseTable? previous,
    int end,
  ) {
    switch (mode) {
      case 0:
        return _FseTable.fromDistribution(defaults, defaultLog);
      case 1:
        return _FseTable.rle(data[pos++]);
      case 2:
        final (table, size) = _FseTable.read(data, pos, end, maxLog, maxSymbol);
        pos += size;
        return table;
      default:
        if (previous == null) throw ZstdFormatException('repeat without table');
        return previous;
    }
  }

  void _decodeSequences(int start, int end, Uint8List literals) {
    final saved = pos;
    pos = start;
    var count = data[pos++];
    if (count == 0) {
      out.addRange(literals, 0, literals.length);
      pos = saved;
      return;
    }
    if (count == 255) {
      count = data[pos] + (data[pos + 1] << 8) + 0x7F00;
      pos += 2;
    } else if (count >= 128) {
      count = ((count - 128) << 8) + data[pos++];
    }
    final modes = data[pos++];
    if (modes & 3 != 0) throw ZstdFormatException('reserved sequence bits');
    final ll = llTable =
        _readTable(modes >> 6, 9, 35, _llDefaultDist, 6, llTable, end);
    final of = ofTable =
        _readTable((modes >> 4) & 3, 8, 31, _ofDefaultDist, 5, ofTable, end);
    final ml = mlTable =
        _readTable((modes >> 2) & 3, 9, 52, _mlDefaultDist, 6, mlTable, end);

    final bits = _BackwardBits(data, pos, end);
    var llState = bits.read(ll.accuracyLog);
    var ofState = bits.read(of.accuracyLog);
    var mlState = bits.read(ml.accuracyLog);
    var literalPos = 0;

    for (var i = 0; i < count; i++) {
      final ofCode = of.symbol[ofState];
      final mlCode = ml.symbol[mlState];
      final llCode = ll.symbol[llState];
      if (ofCode > 31 || mlCode > 52 || llCode > 35) {
        throw ZstdFormatException('invalid sequence code');
      }
      var offsetValue = _pow2(ofCode) + bits.read(ofCode);
      final matchLength = _mlBase[mlCode] + bits.read(_mlBits[mlCode]);
      final literalLength = _llBase[llCode] + bits.read(_llBits[llCode]);

      int offset;
      if (offsetValue > 3) {
        offset = offsetValue - 3;
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
      } else {
        if (literalLength == 0) offsetValue++;
        switch (offsetValue) {
          case 1:
            offset = rep[0];
          case 2:
            offset = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
          case 3:
            offset = rep[2];
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
          default:
            offset = rep[0] - 1;
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
        }
      }

      if (literalPos + literalLength > literals.length) {
        throw ZstdFormatException('literal length overruns literals');
      }
      out.addRange(literals, literalPos, literalPos + literalLength);
      literalPos += literalLength;
      out.copyMatch(offset, matchLength, frameStart);

      if (i != count - 1) {
        llState = ll.base[llState] + bits.read(ll.nbBits[llState]);
        mlState = ml.base[mlState] + bits.read(ml.nbBits[mlState]);
        ofState = of.base[ofState] + bits.read(of.nbBits[ofState]);
      }
    }
    if (!bits.finished) throw ZstdFormatException('sequence stream mismatch');
    out.addRange(literals, literalPos, literals.length);
    pos = saved;
  }

  static int _pow2(int n) => n < 31 ? 1 << n : 2147483648;
}
