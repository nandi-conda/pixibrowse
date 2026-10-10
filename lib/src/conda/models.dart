import 'dart:typed_data';

import 'version.dart';

/// One artifact as the channel's repodata describes it.
class PackageRecord {
  PackageRecord({
    required this.name,
    required this.version,
    required this.build,
    required this.buildNumber,
    required this.subdir,
    required this.fileName,
    required this.channel,
    required this.url,
    required this.raw,
  }) : parsedVersion = CondaVersion.parse(version);

  final String name;
  final String version;
  final CondaVersion parsedVersion;
  final String build;
  final int buildNumber;
  final String subdir;
  final String fileName;

  /// The channel name or URL as the user gave it.
  final String channel;

  /// Where the artifact can be downloaded.
  final String url;

  /// The record exactly as the repodata served it, with binary checksums
  /// already converted to hex strings.
  final Map<String, Object?> raw;

  factory PackageRecord.fromRepodata(
    Map<Object?, Object?> source, {
    required String fileName,
    required String subdir,
    required String channel,
    required String baseUrl,
  }) {
    final raw = <String, Object?>{};
    source.forEach((key, value) {
      raw['$key'] = value is Uint8List ? hex(value) : value;
    });
    return PackageRecord(
      name: '${raw['name'] ?? ''}',
      version: '${raw['version'] ?? ''}',
      build: '${raw['build'] ?? ''}',
      buildNumber: (raw['build_number'] as num?)?.toInt() ?? 0,
      subdir: '${raw['subdir'] ?? subdir}',
      fileName: fileName,
      channel: channel,
      url: '$baseUrl$fileName',
      raw: raw,
    );
  }

  List<String> get depends => _strings(raw['depends']);
  List<String> get constrains => _strings(raw['constrains']);
  String? get license => raw['license'] as String?;
  int? get size => (raw['size'] as num?)?.toInt();
  String? get sha256 => raw['sha256'] as String?;
  String? get md5 => raw['md5'] as String?;

  DateTime? get timestamp => parseTimestamp(raw['timestamp']);

  Map<String, List<String>> get extraDepends {
    final value = raw['extra_depends'];
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries) '${entry.key}': _strings(entry.value),
    };
  }

  /// `run_exports` as served by sharded repodata, if present.
  Map<String, List<String>> get runExports {
    final value = raw['run_exports'];
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries) '${entry.key}': _strings(entry.value),
    };
  }

  bool get isCondaFormat => fileName.endsWith('.conda');

  /// Newest version first, then highest build number, then build string.
  static int newestFirst(PackageRecord a, PackageRecord b) {
    final c = b.parsedVersion.compareTo(a.parsedVersion);
    if (c != 0) return c;
    final n = b.buildNumber.compareTo(a.buildNumber);
    if (n != 0) return n;
    final t = (b.timestamp?.millisecondsSinceEpoch ?? 0)
        .compareTo(a.timestamp?.millisecondsSinceEpoch ?? 0);
    if (t != 0) return t;
    return a.build.compareTo(b.build);
  }
}

List<String> _strings(Object? value) {
  if (value is List) return [for (final v in value) '$v'];
  return const [];
}

/// Conda timestamps are milliseconds since the epoch, though some older
/// records use seconds.
DateTime? parseTimestamp(Object? value) {
  if (value is! num) return null;
  var ms = value.toInt();
  if (ms < 100000000000) ms *= 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

String hex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// One entry of an artifact's `info/paths.json`.
class PackageFile {
  const PackageFile({
    required this.path,
    this.sizeInBytes,
    this.sha256,
    this.pathType,
    this.noLink = false,
    this.prefixPlaceholder,
    this.fileMode,
  });

  final String path;
  final int? sizeInBytes;
  final String? sha256;
  final String? pathType;
  final bool noLink;
  final String? prefixPlaceholder;
  final String? fileMode;

  bool get isSymlink => pathType == 'softlink';
}

/// What reading an artifact's `info/` section revealed.
class ArtifactContents {
  ArtifactContents({
    required this.files,
    required this.infoFiles,
    this.indexJson,
    this.aboutJson,
    this.runExports,
  });

  final List<PackageFile> files;

  /// Every file under `info/`, by path, decoded as text where possible.
  final Map<String, Uint8List> infoFiles;
  final Map<String, Object?>? indexJson;
  final Map<String, Object?>? aboutJson;
  final Map<String, Object?>? runExports;
}

/// A difference between the archive's own `index.json` and the repodata.
class PatchRow {
  const PatchRow(this.label, this.original, this.patched);
  final String label;
  final String original;
  final String patched;
}
