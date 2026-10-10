import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// What a channel's `channeldata.json` says about one package: the summary,
/// licence and links of its latest build, without downloading an artifact.
class ChannelPackage {
  ChannelPackage({
    required this.name,
    required this.channel,
    this.summary,
    this.description,
    this.license,
    this.licenseFamily,
    this.version,
    this.home = const [],
    this.devUrl = const [],
    this.docUrl = const [],
    this.sourceUrl = const [],
    this.sourceGitUrl,
    this.subdirs = const [],
    this.keywords = const [],
    this.timestamp,
  })  : summaryLower = summary?.toLowerCase() ?? '',
        descriptionLower = description?.toLowerCase() ?? '';

  final String name;

  /// The channel name or URL as the user gave it.
  final String channel;
  final String? summary;
  final String? description;
  final String? license;
  final String? licenseFamily;

  /// The newest version the channel serves.
  final String? version;
  final List<String> home;
  final List<String> devUrl;
  final List<String> docUrl;
  final List<String> sourceUrl;
  final String? sourceGitUrl;
  final List<String> subdirs;
  final List<String> keywords;
  final DateTime? timestamp;

  /// Lowercased once, so searching 30k packages per keystroke stays cheap.
  final String summaryLower;
  final String descriptionLower;

  factory ChannelPackage.fromJson(
    String name,
    Map<Object?, Object?> json, {
    required String channel,
  }) {
    return ChannelPackage(
      name: name,
      channel: channel,
      summary: _text(json['summary']),
      description: _text(json['description']),
      license: _text(json['license']),
      licenseFamily: _text(json['license_family']),
      version: _text(json['version']),
      home: _list(json['home']),
      devUrl: _list(json['dev_url']),
      docUrl: _list(json['doc_url']),
      sourceUrl: _list(json['source_url']),
      sourceGitUrl: _text(json['source_git_url']),
      subdirs: _subdirs(json['subdirs']),
      keywords: _list(json['keywords']),
      timestamp: parseTimestamp(json['timestamp']),
    );
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'channel': channel,
        'version': ?version,
        'summary': ?summary,
        'description': ?description,
        'license': ?license,
        'license_family': ?licenseFamily,
        if (home.isNotEmpty) 'home': home,
        if (devUrl.isNotEmpty) 'dev_url': devUrl,
        if (docUrl.isNotEmpty) 'doc_url': docUrl,
        if (sourceUrl.isNotEmpty) 'source_url': sourceUrl,
        'source_git_url': ?sourceGitUrl,
        if (subdirs.isNotEmpty) 'subdirs': subdirs,
        if (keywords.isNotEmpty) 'keywords': keywords,
        if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
      };
}

/// Fields vary in shape between channels: a string, a list, or missing.
String? _text(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is List && value.isNotEmpty) return _text(value.first);
  if (value is num || value is bool) return '$value';
  return null;
}

List<String> _list(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? const [] : [trimmed];
  }
  if (value is List) {
    return [
      for (final v in value)
        if (v != null && '$v'.trim().isNotEmpty) '$v'.trim(),
    ];
  }
  return const [];
}

/// `subdirs` is a list on most channels and a map keyed by subdir on some.
List<String> _subdirs(Object? value) {
  if (value is Map) return [for (final k in value.keys) '$k'];
  return _list(value);
}

/// Parses `channeldata.json`, keyed by package name.
Map<String, ChannelPackage> parseChannelData(
  Uint8List bytes, {
  required String channel,
}) {
  final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  if (decoded is! Map) return const {};
  final packages = decoded['packages'];
  if (packages is! Map) return const {};
  return {
    for (final entry in packages.entries)
      if (entry.value is Map)
        '${entry.key}': ChannelPackage.fromJson(
          '${entry.key}',
          entry.value as Map,
          channel: channel,
        ),
  };
}
