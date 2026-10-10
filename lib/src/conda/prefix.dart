import 'dart:convert';

import 'package:http/http.dart' as http;

import 'channeldata.dart';
import 'repodata.dart';
import 'version.dart';

/// prefix.dev indexes channels with rattler-index, which writes no
/// `channeldata.json`; its GraphQL API is where package summaries live.
const String prefixDevGraphqlUrl = 'https://prefix.dev/api/graphql';

const String _packageQuery = r'''
query Package($channel: String!, $name: String!) {
  package(channelName: $channel, name: $name) {
    name
    description
    variants(limit: 10) {
      page { version rawIndex rawAbout }
    }
  }
}''';

/// The channel's name on prefix.dev when [channel] is hosted there
/// (`https://prefix.dev/nandi-testing` or `https://repo.prefix.dev/...`),
/// else `null`.
String? prefixDevChannelName(String channel) {
  final uri = Uri.tryParse(channelUrl(channel));
  if (uri == null) return null;
  if (uri.host != 'prefix.dev' && !uri.host.endsWith('.prefix.dev')) {
    return null;
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? null : segments.last;
}

/// Asks prefix.dev about [name] on [channel], or returns `null` when the
/// channel is not on prefix.dev or does not have the package.
Future<ChannelPackage?> fetchPrefixDevPackage(
  http.Client client,
  String channel,
  String name,
) async {
  final channelName = prefixDevChannelName(channel);
  if (channelName == null) return null;
  final response = await client.post(
    Uri.parse(prefixDevGraphqlUrl),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'query': _packageQuery,
      'variables': {'channel': channelName, 'name': name},
    }),
  );
  if (response.statusCode != 200) {
    throw HttpStatusException(prefixDevGraphqlUrl, response.statusCode);
  }
  return parsePrefixDevPackage(
    jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true)),
    name: name,
    channel: channel,
  );
}

/// Turns a GraphQL `package` response into what channeldata would have
/// said, taking the about and index records of the newest variant listed.
ChannelPackage? parsePrefixDevPackage(
  Object? response, {
  required String name,
  required String channel,
}) {
  if (response is! Map) return null;
  final errors = response['errors'];
  final data = response['data'];
  final package = data is Map ? data['package'] : null;
  if (package is! Map) {
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      throw PrefixDevException(first is Map ? '${first['message']}' : '$first');
    }
    return null;
  }
  final variants = package['variants'];
  final page = variants is Map ? variants['page'] : null;
  Map<Object?, Object?>? newest;
  CondaVersion? newestVersion;
  for (final variant in page is List ? page : const []) {
    if (variant is! Map || variant['version'] is! String) continue;
    final version = CondaVersion.parse(variant['version'] as String);
    if (newestVersion == null || version.compareTo(newestVersion) > 0) {
      newest = variant;
      newestVersion = version;
    }
  }
  final about = _object(newest?['rawAbout']);
  final index = _object(newest?['rawIndex']);
  return ChannelPackage.fromJson(name, {
    ...index,
    ...about,
    'description': about['description'] ?? package['description'],
    'license': about['license'] ?? index['license'],
    // Ten variants need not hold the newest version or every platform;
    // the records say both.
    'version': null,
    'subdirs': null,
  }, channel: channel);
}

/// `rawAbout` and `rawIndex` are JSON scalars: an object, or that object
/// encoded as a string.
Map<Object?, Object?> _object(Object? value) {
  if (value is Map) return value;
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded;
    } on FormatException {
      return const {};
    }
  }
  return const {};
}

class PrefixDevException implements Exception {
  PrefixDevException(this.message);
  final String message;
  @override
  String toString() => 'prefix.dev: $message';
}

const String _searchQuery = r'''
query Search($query: String!, $limit: Int!) {
  packages(
    filters: { name: { contains: $query } }
    orderBy: { bySimilarity: { field: NAME, matches: $query, direction: DESC } }
    limit: $limit
  ) {
    totalCount
    page {
      name
      summary
      platforms
      channel { name baseUrl }
    }
  }
}''';

/// One package found by searching every channel on prefix.dev.
class PrefixDevHit {
  const PrefixDevHit({
    required this.name,
    required this.channelName,
    required this.channelUrl,
    this.summary,
    this.platforms = const [],
  });

  final String name;
  final String channelName;

  /// Where the channel's repodata lives, such as
  /// `https://prefix.dev/conda-forge`.
  final String channelUrl;
  final String? summary;
  final List<String> platforms;

  /// Tells apart packages of the same name on different channels.
  String get key => '$channelName/$name';
}

/// Searches package names across every public channel prefix.dev knows,
/// most similar first (larger channels win ties).
Future<({List<PrefixDevHit> hits, int total})> searchPrefixDev(
  http.Client client,
  String query, {
  int limit = 50,
}) async {
  final response = await client.post(
    Uri.parse(prefixDevGraphqlUrl),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'query': _searchQuery,
      'variables': {'query': query, 'limit': limit},
    }),
  );
  if (response.statusCode != 200) {
    throw HttpStatusException(prefixDevGraphqlUrl, response.statusCode);
  }
  return parsePrefixDevSearch(
    jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true)),
  );
}

({List<PrefixDevHit> hits, int total}) parsePrefixDevSearch(Object? response) {
  final data = response is Map ? response['data'] : null;
  final packages = data is Map ? data['packages'] : null;
  if (packages is! Map) {
    final errors = response is Map ? response['errors'] : null;
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      throw PrefixDevException(first is Map ? '${first['message']}' : '$first');
    }
    return (hits: const <PrefixDevHit>[], total: 0);
  }
  final hits = <PrefixDevHit>[];
  final page = packages['page'];
  for (final package in page is List ? page : const []) {
    if (package is! Map || package['name'] is! String) continue;
    final channel = package['channel'];
    final channelName = channel is Map ? channel['name'] : null;
    if (channelName is! String) continue;
    final baseUrl = channel['baseUrl'];
    final summary = package['summary'];
    final platforms = package['platforms'];
    hits.add(
      PrefixDevHit(
        name: package['name'] as String,
        channelName: channelName,
        channelUrl: baseUrl is String && baseUrl.isNotEmpty
            ? baseUrl.replaceFirst(RegExp(r'/+$'), '')
            : 'https://prefix.dev/$channelName',
        summary: summary is String && summary.trim().isNotEmpty
            ? summary.trim()
            : null,
        platforms: [
          for (final p in platforms is List ? platforms : const [])
            if (p is String) p,
        ],
      ),
    );
  }
  final total = packages['totalCount'];
  return (hits: hits, total: total is int ? total : hits.length);
}
