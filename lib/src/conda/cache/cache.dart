import 'dart:typed_data';

import 'cache_stub.dart' if (dart.library.io) 'cache_io.dart' as platform;

/// A response kept from an earlier run.
class CachedResponse {
  const CachedResponse({
    required this.statusCode,
    required this.bytes,
    required this.fetchedAt,
    this.etag,
    this.lastModified,
  });

  final int statusCode;
  final Uint8List bytes;
  final DateTime fetchedAt;
  final String? etag;
  final String? lastModified;
}

/// Somewhere to keep downloaded channel data between runs.
abstract class ByteCache {
  Future<CachedResponse?> read(String url);
  Future<void> write(String url, CachedResponse response);

  /// A cache on disk where the platform has one (not on the web, where the
  /// browser's HTTP cache does the job), or `null`.
  ///
  /// It lives in `$PIXIBROWSE_CACHE_DIR`, or the user's cache directory
  /// (`~/.cache/pixibrowse` on Linux).
  static ByteCache? disk() => platform.diskCache();
}

/// Keeps responses in memory, for tests.
class MemoryCache implements ByteCache {
  final Map<String, CachedResponse> entries = {};

  @override
  Future<CachedResponse?> read(String url) async => entries[url];

  @override
  Future<void> write(String url, CachedResponse response) async =>
      entries[url] = response;
}
