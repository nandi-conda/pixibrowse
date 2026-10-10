import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cache.dart';

ByteCache? diskCache() {
  final dir = cacheDirectory(Platform.environment);
  return dir == null ? null : DiskCache(Directory(dir));
}

/// Where the cache goes, following each platform's convention.
String? cacheDirectory(Map<String, String> env) {
  String? nonEmpty(String? v) => v == null || v.isEmpty ? null : v;
  final override = nonEmpty(env['PIXIBROWSE_CACHE_DIR']);
  if (override != null) return override;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final local = nonEmpty(env['LOCALAPPDATA']);
    return local == null ? null : '$local${sep}pixibrowse${sep}cache';
  }
  final home = nonEmpty(env['HOME']);
  if (Platform.isMacOS) {
    return home == null ? null : '$home/Library/Caches/pixibrowse';
  }
  final xdg = nonEmpty(env['XDG_CACHE_HOME']);
  if (xdg != null) return '$xdg/pixibrowse';
  return home == null ? null : '$home/.cache/pixibrowse';
}

/// One body file and one small JSON file of headers per URL. Failing to
/// read or write is never fatal: the app just downloads again.
class DiskCache implements ByteCache {
  DiskCache(this.directory);

  final Directory directory;

  String _key(String url) {
    final safe = url
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    if (safe.length <= 180) return safe;
    // Long URLs keep a readable start and a hash of the whole.
    var h = 0xcbf29ce484222325;
    for (final unit in url.codeUnits) {
      h = (h ^ unit) * 0x100000001b3;
    }
    return '${safe.substring(0, 140)}_${h.toUnsigned(64).toRadixString(16)}';
  }

  File _body(String url) => File('${directory.path}/${_key(url)}');
  File _meta(String url) => File('${directory.path}/${_key(url)}.meta.json');

  @override
  Future<CachedResponse?> read(String url) async {
    try {
      final meta = jsonDecode(await _meta(url).readAsString()) as Map;
      final body = _body(url);
      final status = meta['status'] as int;
      return CachedResponse(
        statusCode: status,
        bytes: status == 200 ? await body.readAsBytes() : Uint8List(0),
        fetchedAt: DateTime.parse(meta['fetched_at'] as String),
        etag: meta['etag'] as String?,
        lastModified: meta['last_modified'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String url, CachedResponse response) async {
    try {
      await directory.create(recursive: true);
      if (response.statusCode == 200) {
        // Write beside and rename, so a crash never leaves half a file.
        final tmp = File('${_body(url).path}.tmp');
        await tmp.writeAsBytes(response.bytes, flush: true);
        await tmp.rename(_body(url).path);
      }
      await _meta(url).writeAsString(jsonEncode({
        'url': url,
        'status': response.statusCode,
        'fetched_at': response.fetchedAt.toUtc().toIso8601String(),
        'etag': response.etag,
        'last_modified': response.lastModified,
      }));
    } catch (_) {
      // A read-only or full disk only costs a download next time.
    }
  }
}
