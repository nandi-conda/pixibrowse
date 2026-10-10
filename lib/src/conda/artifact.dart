import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../codec/zstd.dart';
import 'models.dart';
import 'repodata.dart';

/// Downloads an artifact and reads its `info/` section.
///
/// A `.conda` archive is a zip whose `info-*.tar.zst` member holds the
/// metadata, so only that member is decompressed. A `.tar.bz2` archive has to
/// be decompressed whole.
Future<ArtifactContents> loadArtifactContents(
  http.Client client,
  PackageRecord record,
) async {
  final bytes = await fetchBytes(client, record.url);
  return compute(
    _readArtifact,
    (bytes: bytes, conda: record.fileName.endsWith('.conda')),
  );
}

ArtifactContents _readArtifact(({Uint8List bytes, bool conda}) input) =>
    readArtifactBytes(input.bytes, conda: input.conda);

ArtifactContents readArtifactBytes(Uint8List bytes, {required bool conda}) {
  final infoFiles = <String, Uint8List>{};
  if (conda) {
    final zip = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? info;
    for (final file in zip.files) {
      if (file.name.startsWith('info-') && file.name.endsWith('.tar.zst')) {
        info = file;
      }
    }
    if (info == null) throw RepodataException('no info section in archive');
    final tar = TarDecoder().decodeBytes(zstdDecode(info.content));
    for (final file in tar.files) {
      if (file.isFile) infoFiles[_clean(file.name)] = file.content;
    }
  } else {
    final tar = TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
    for (final file in tar.files) {
      final name = _clean(file.name);
      if (file.isFile && name.startsWith('info/')) {
        infoFiles[name] = file.content;
      }
    }
  }
  return contentsFromInfoFiles(infoFiles);
}

String _clean(String name) => name.startsWith('./') ? name.substring(2) : name;

Map<String, Object?>? _json(Map<String, Uint8List> files, String path) {
  final bytes = files[path];
  if (bytes == null) return null;
  try {
    final value = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    return value is Map<String, Object?> ? value : null;
  } on FormatException {
    return null;
  }
}

ArtifactContents contentsFromInfoFiles(Map<String, Uint8List> infoFiles) {
  final files = <PackageFile>[];
  final paths = _json(infoFiles, 'info/paths.json');
  final entries = paths?['paths'];
  if (entries is List) {
    for (final entry in entries) {
      if (entry is! Map) continue;
      files.add(PackageFile(
        path: '${entry['_path']}',
        sizeInBytes: (entry['size_in_bytes'] as num?)?.toInt(),
        sha256: entry['sha256'] as String?,
        pathType: entry['path_type'] as String?,
        noLink: entry['no_link'] == true,
        prefixPlaceholder: entry['prefix_placeholder'] as String?,
        fileMode: entry['file_mode'] as String?,
      ));
    }
  } else if (infoFiles['info/files'] case final list?) {
    // Old artifacts list their files without any detail.
    for (final line in const LineSplitter().convert(utf8.decode(list))) {
      if (line.trim().isNotEmpty) files.add(PackageFile(path: line.trim()));
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return ArtifactContents(
    files: files,
    infoFiles: Map.fromEntries(
      infoFiles.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    indexJson: _json(infoFiles, 'info/index.json'),
    aboutJson: _json(infoFiles, 'info/about.json'),
    runExports: _json(infoFiles, 'info/run_exports.json'),
  );
}

// Fields that legitimately differ between an archive's index.json and the
// channel's record, or that only the channel adds.
const Set<String> _patchIgnoredFields = {
  'md5',
  'sha256',
  'size',
  'fn',
  'url',
  'channel',
  'run_exports',
  'legacy_bz2_md5',
  'legacy_bz2_size',
  'attestations_sha256',
  // Derived from the subdir; sharded repodata leaves them out.
  'arch',
  'platform',
};

String _fieldText(Object? value) {
  if (value == null) return '—';
  if (value is List) return value.isEmpty ? '[]' : value.join('\n');
  if (value is Map) return const JsonEncoder.withIndent('  ').convert(value);
  return '$value';
}

/// Rows where the channel's repodata disagrees with the archive's own
/// `info/index.json`, i.e. where the channel patched the metadata.
List<PatchRow> repodataPatches(
  Map<String, Object?> indexJson,
  PackageRecord record,
) {
  final keys = {...indexJson.keys, ...record.raw.keys}
    ..removeAll(_patchIgnoredFields);
  final rows = <PatchRow>[];
  for (final key in keys.toList()..sort()) {
    final original = indexJson[key];
    final patched = record.raw[key];
    if (original == null && patched == null) continue;
    if (original == null && patched is List && patched.isEmpty) continue;
    if (patched == null && original is List && original.isEmpty) continue;
    if (original is List && patched is List) {
      final a = original.map((e) => '$e').toSet();
      final b = patched.map((e) => '$e').toSet();
      if (a.length == b.length && a.containsAll(b)) continue;
    } else if (_fieldText(original) == _fieldText(patched)) {
      continue;
    }
    rows.add(PatchRow(key, _fieldText(original), _fieldText(patched)));
  }
  return rows;
}
