import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../codec/msgpack.dart';
import '../codec/zstd.dart';
import 'cache/cache.dart';
import 'channeldata.dart';
import 'models.dart';

/// The channel the app browses when none is given.
const String defaultChannel = 'conda-forge';

/// Subdirs probed when discovering what a channel serves. `noarch` must
/// exist on every channel.
const List<String> knownPlatforms = [
  'noarch',
  'linux-64',
  'linux-aarch64',
  'linux-ppc64le',
  'linux-s390x',
  'linux-armv7l',
  'linux-32',
  'osx-64',
  'osx-arm64',
  'win-64',
  'win-arm64',
  'win-32',
  'emscripten-wasm32',
  'wasi-wasm32',
  'zos-z',
];

/// `noarch` sorts last, everything else alphabetically.
int comparePlatforms(String a, String b) {
  if (a == b) return 0;
  if (a == 'noarch') return 1;
  if (b == 'noarch') return -1;
  return a.compareTo(b);
}

/// Turns a channel name or URL into the channel's base URL.
String channelUrl(String channel) {
  final trimmed = channel.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
  return 'https://conda.anaconda.org/$trimmed';
}

/// Clean up a channel selection: strip, drop blanks and repeats, keep order.
List<String> normalizeChannels(Iterable<String> channels) {
  final result = <String>[];
  for (final channel in channels) {
    final cleaned = channel.trim();
    if (cleaned.isNotEmpty && !result.contains(cleaned)) result.add(cleaned);
  }
  return result;
}

class RepodataException implements Exception {
  RepodataException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The packages one channel serves for one subdir.
abstract class SubdirIndex {
  String get channel;
  String get subdir;
  Iterable<String> get packageNames;
  bool contains(String name);
  Future<List<PackageRecord>> records(String name);
}

/// Sharded repodata (CEP 16): a small index of package names, with each
/// package's records fetched on demand.
class ShardedSubdirIndex implements SubdirIndex {
  ShardedSubdirIndex({
    required this.channel,
    required this.subdir,
    required this.shards,
    required this.shardsBaseUrl,
    required this.packageBaseUrl,
    required this.fetch,
  });

  @override
  final String channel;
  @override
  final String subdir;
  final Map<String, String> shards;
  final String shardsBaseUrl;
  final String packageBaseUrl;

  /// Downloads a shard; shards are named by their hash, so they never go
  /// stale.
  final Future<Uint8List> Function(String url) fetch;
  final Map<String, Future<List<PackageRecord>>> _cache = {};

  @override
  Iterable<String> get packageNames => shards.keys;

  @override
  bool contains(String name) => shards.containsKey(name);

  @override
  Future<List<PackageRecord>> records(String name) {
    final hash = shards[name];
    if (hash == null) return Future.value(const []);
    return _cache[name] ??= _fetch(name, hash).catchError((Object e) {
      _cache.remove(name);
      throw e;
    });
  }

  Future<List<PackageRecord>> _fetch(String name, String hash) async {
    final bytes = await fetch('$shardsBaseUrl$hash.msgpack.zst');
    final decoded = msgpackDecode(zstdDecode(bytes));
    if (decoded is! Map) throw RepodataException('malformed shard for $name');
    return recordsFromRepodata(
      decoded,
      subdir: subdir,
      channel: channel,
      baseUrl: packageBaseUrl,
    );
  }
}

/// Classic `repodata.json`, for channels that do not serve shards.
class FullSubdirIndex implements SubdirIndex {
  FullSubdirIndex({
    required this.channel,
    required this.subdir,
    required this.byName,
  });

  @override
  final String channel;
  @override
  final String subdir;
  final Map<String, List<PackageRecord>> byName;

  @override
  Iterable<String> get packageNames => byName.keys;

  @override
  bool contains(String name) => byName.containsKey(name);

  @override
  Future<List<PackageRecord>> records(String name) =>
      Future.value(byName[name] ?? const []);
}

List<PackageRecord> recordsFromRepodata(
  Map<Object?, Object?> repodata, {
  required String subdir,
  required String channel,
  required String baseUrl,
}) {
  final records = <PackageRecord>[];
  for (final key in const ['packages', 'packages.conda']) {
    final packages = repodata[key];
    if (packages is! Map) continue;
    packages.forEach((fileName, record) {
      if (record is Map) {
        records.add(PackageRecord.fromRepodata(
          record,
          fileName: '$fileName',
          subdir: subdir,
          channel: channel,
          baseUrl: baseUrl,
        ));
      }
    });
  }
  return records;
}

Future<Uint8List> fetchBytes(http.Client client, String url) async {
  final response = await client.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw HttpStatusException(url, response.statusCode);
  }
  return response.bodyBytes;
}

class HttpStatusException implements Exception {
  HttpStatusException(this.url, this.statusCode);
  final String url;
  final int statusCode;
  @override
  String toString() => 'HTTP $statusCode for $url';
}

/// Resolves a CEP 16 `base_url` / `shards_base_url` against the index URL,
/// always ending in `/`.
String resolveBase(String indexUrl, Object? relative) {
  final index = Uri.parse(indexUrl);
  final directory = index.resolve('.').toString();
  final text = relative is String ? relative : '';
  if (text.isEmpty || text == '.' || text == './') return directory;
  final resolved = index.resolve(text).toString();
  return resolved.endsWith('/') ? resolved : '$resolved/';
}

// Decoding runs off the UI thread on native platforms (inline on the web).
Map<String, Object?> _decodeShardIndex(Uint8List bytes) {
  final decoded = msgpackDecode(zstdDecode(bytes));
  if (decoded is! Map) throw RepodataException('malformed shard index');
  final info = decoded['info'];
  final shards = decoded['shards'];
  if (info is! Map || shards is! Map) {
    throw RepodataException('malformed shard index');
  }
  return {
    'base_url': info['base_url'],
    'shards_base_url': info['shards_base_url'],
    'shards': {
      for (final entry in shards.entries)
        '${entry.key}': entry.value is Uint8List
            ? hex(entry.value as Uint8List)
            : '${entry.value}',
    },
  };
}

Map<String, Object?> _decodeRepodataJson(Uint8List bytes) {
  final raw = bytes.length >= 4 &&
          bytes[0] == 0x28 &&
          bytes[1] == 0xB5 &&
          bytes[2] == 0x2F &&
          bytes[3] == 0xFD
      ? zstdDecode(bytes)
      : bytes;
  return jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
}

Map<String, ChannelPackage> _decodeChannelData(
        ({Uint8List bytes, String channel}) input) =>
    parseChannelData(input.bytes, channel: input.channel);

/// Fetches and caches subdir indexes and channeldata for any number of
/// channels.
///
/// With a [cache], indexes and channeldata are kept between runs: reused
/// for [maxAge], then revalidated with `If-None-Match`/`If-Modified-Since`,
/// and served stale when the network is down. Shards never expire.
class RepodataClient {
  RepodataClient({
    http.Client? client,
    this.cache,
    this.maxAge = const Duration(hours: 1),
  }) : client = client ?? http.Client();

  final http.Client client;
  final ByteCache? cache;
  final Duration maxAge;
  final Map<String, Future<SubdirIndex?>> _indexes = {};
  final Map<String, Future<Map<String, ChannelPackage>>> _channelData = {};

  /// Cached responses fetched before this are revalidated before use.
  DateTime? _refreshedAt;

  /// Forgets everything downloaded so far, so the next request asks the
  /// channel again.
  void refresh() {
    _indexes.clear();
    _channelData.clear();
    _refreshedAt = DateTime.now();
  }

  /// Downloads [url] through the cache. Errors that are HTTP statuses are
  /// cached too, so probing for subdirs a channel lacks stays fast.
  Future<Uint8List> get(String url, {bool immutable = false}) async {
    final cache = this.cache;
    if (cache == null) return fetchBytes(client, url);
    final cached = await cache.read(url);
    if (cached != null) {
      final refreshed = _refreshedAt;
      final fresh = immutable ||
          ((refreshed == null || cached.fetchedAt.isAfter(refreshed)) &&
              DateTime.now().difference(cached.fetchedAt) < maxAge);
      if (fresh) return _result(url, cached);
    }
    http.Response response;
    try {
      response = await client.get(Uri.parse(url), headers: {
        if (cached?.statusCode == 200 && cached?.etag != null)
          'If-None-Match': cached!.etag!,
        if (cached?.statusCode == 200 && cached?.lastModified != null)
          'If-Modified-Since': cached!.lastModified!,
      });
    } catch (_) {
      // Offline: what we had is better than nothing.
      if (cached != null) return _result(url, cached);
      rethrow;
    }
    final now = DateTime.now();
    if (response.statusCode == 304 && cached != null) {
      await cache.write(
        url,
        CachedResponse(
          statusCode: 200,
          bytes: cached.bytes,
          fetchedAt: now,
          etag: response.headers['etag'] ?? cached.etag,
          lastModified: response.headers['last-modified'] ?? cached.lastModified,
        ),
      );
      return cached.bytes;
    }
    final entry = CachedResponse(
      statusCode: response.statusCode,
      bytes: response.statusCode == 200 ? response.bodyBytes : Uint8List(0),
      fetchedAt: now,
      etag: response.headers['etag'],
      lastModified: response.headers['last-modified'],
    );
    if (response.statusCode == 200 ||
        response.statusCode == 404 ||
        response.statusCode == 403) {
      await cache.write(url, entry);
    }
    return _result(url, entry);
  }

  Uint8List _result(String url, CachedResponse response) {
    if (response.statusCode != 200) {
      throw HttpStatusException(url, response.statusCode);
    }
    return response.bytes;
  }

  /// Package summaries, licences and links from `channeldata.json`, or an
  /// empty map when the channel does not serve one.
  Future<Map<String, ChannelPackage>> channelData(String channel) {
    final key = channelUrl(channel);
    return _channelData[key] ??= () async {
      Uint8List bytes;
      try {
        bytes = await get('$key/channeldata.json');
      } on HttpStatusException catch (e) {
        if (e.statusCode == 404 || e.statusCode == 403) return const <String, ChannelPackage>{};
        rethrow;
      }
      return compute(_decodeChannelData, (bytes: bytes, channel: channel));
    }()
        .catchError((Object e) {
      _channelData.remove(key);
      throw e;
    });
  }

  /// The index of [channel]/[subdir], or `null` if the channel does not
  /// serve that subdir.
  Future<SubdirIndex?> index(String channel, String subdir) {
    final key = '${channelUrl(channel)}/$subdir';
    return _indexes[key] ??= _loadIndex(channel, subdir).catchError((
      Object e,
    ) {
      _indexes.remove(key);
      throw e;
    });
  }

  Future<SubdirIndex?> _loadIndex(String channel, String subdir) async {
    final base = '${channelUrl(channel)}/$subdir';
    final shardUrl = '$base/repodata_shards.msgpack.zst';
    try {
      final bytes = await get(shardUrl);
      final parsed = await compute(_decodeShardIndex, bytes);
      return ShardedSubdirIndex(
        channel: channel,
        subdir: subdir,
        shards: (parsed['shards'] as Map).cast<String, String>(),
        shardsBaseUrl: resolveBase(shardUrl, parsed['shards_base_url']),
        packageBaseUrl: resolveBase(shardUrl, parsed['base_url']),
        fetch: (url) => get(url, immutable: true),
      );
    } on HttpStatusException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 403) rethrow;
    }

    for (final name in const ['repodata.json.zst', 'repodata.json']) {
      final url = '$base/$name';
      Uint8List bytes;
      try {
        bytes = await get(url);
      } on HttpStatusException catch (e) {
        if (e.statusCode == 404 || e.statusCode == 403) continue;
        rethrow;
      }
      final repodata = await compute(_decodeRepodataJson, bytes);
      final info = repodata['info'];
      final baseUrl = resolveBase(url, info is Map ? info['base_url'] : null);
      final byName = <String, List<PackageRecord>>{};
      for (final record in recordsFromRepodata(
        repodata,
        subdir: subdir,
        channel: channel,
        baseUrl: baseUrl,
      )) {
        byName.putIfAbsent(record.name, () => []).add(record);
      }
      return FullSubdirIndex(channel: channel, subdir: subdir, byName: byName);
    }
    return null;
  }

  /// Probes which platforms at least one of [channels] serves.
  ///
  /// A channel without `noarch` cannot be browsed at all, so its error is
  /// raised instead of silently dropping it.
  Future<List<String>> discoverPlatforms(
    List<String> channels, {
    void Function(int done, int total)? onProgress,
  }) async {
    final total = channels.length * knownPlatforms.length;
    var done = 0;
    final found = <String>{};
    await Future.wait([
      for (final channel in channels)
        for (final platform in knownPlatforms)
          () async {
            try {
              final index = await this.index(channel, platform);
              if (index != null) {
                found.add(platform);
              } else if (platform == 'noarch') {
                throw RepodataException(
                    'Channel "$channel" serves no noarch repodata.');
              }
            } catch (e) {
              if (platform == 'noarch') rethrow;
            } finally {
              onProgress?.call(++done, total);
            }
          }(),
    ]);
    return found.toList()..sort(comparePlatforms);
  }

  /// All package names across [channels] and [platforms], sorted.
  Future<List<String>> packageNames(
    List<String> channels,
    List<String> platforms,
  ) async {
    final names = <String>{};
    for (final channel in channels) {
      for (final platform in platforms) {
        final index = await this.index(channel, platform);
        if (index != null) names.addAll(index.packageNames);
      }
    }
    return names.toList()..sort();
  }

  /// Every record of [name], newest first.
  Future<List<PackageRecord>> records(
    String name,
    List<String> channels,
    List<String> platforms,
  ) async {
    final futures = <Future<List<PackageRecord>>>[];
    for (final channel in channels) {
      for (final platform in platforms) {
        futures.add(index(channel, platform).then((index) {
          if (index == null || !index.contains(name)) {
            return Future.value(const <PackageRecord>[]);
          }
          return index.records(name);
        }));
      }
    }
    final results = await Future.wait(futures);
    return [for (final list in results) ...list]
      ..sort(PackageRecord.newestFirst);
  }

  void dispose() => client.close();
}
