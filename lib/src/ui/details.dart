import 'dart:convert';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons, SelectionArea;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../conda/artifact.dart';
import '../conda/models.dart';
import '../conda/repodata.dart';
import '../search.dart';
import '../state.dart';
import 'dialogs.dart';
import 'panes.dart';
import 'theme.dart';

String formatBytes(int? bytes) {
  if (bytes == null) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? '$bytes' : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String formatTimestamp(DateTime? time) {
  if (time == null) return '—';
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)} UTC';
}

String _value(Object? value) {
  if (value == null) return '—';
  if (value is List) return value.isEmpty ? '—' : value.join(', ');
  if (value is String && value.isEmpty) return '—';
  return '$value';
}

List<String> _urls(Object? value) {
  if (value is String && value.isNotEmpty) return [value];
  if (value is List) return [for (final v in value) '$v'];
  return const [];
}

Future<void> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> downloadRecord(BuildContext context, PackageRecord record) async {
  await openUrl(record.url);
}

void copyText(BuildContext context, String text, String notice) {
  Clipboard.setData(ClipboardData(text: text));
  showKitToast(context, notice);
}

/// The selected artifact's repodata record, or what is known about the
/// selected package, as indented JSON.
String? selectionJson(BrowserState state) {
  final record = state.selectedRecord;
  final name = state.selectedPackage;
  if (record != null) {
    return const JsonEncoder.withIndent('  ')
        .convert({'url': record.url, 'channel': record.channel, ...record.raw});
  }
  if (name == null) return null;
  final newest = state.records.isEmpty ? null : state.records.first;
  return const JsonEncoder.withIndent('  ').convert({
    'name': name,
    ...?state.infoFor(name)?.toJson(),
    if (state.records.isNotEmpty) ...{
      'versions': {for (final r in state.records) r.version}.toList(),
      'platforms': ({for (final r in state.records) r.subdir}.toList()
        ..sort(comparePlatforms)),
    },
    if (state.infoFor(name)?.license == null && newest?.license != null)
      'license': newest!.license,
  });
}

void copyAsJson(BuildContext context, BrowserState state) {
  final json = selectionJson(state);
  if (json == null) return;
  copyText(
    context,
    json,
    state.selectedRecord == null
        ? 'Copied ${state.selectedPackage} as JSON'
        : 'Copied ${state.selectedRecord!.fileName} as JSON',
  );
}

class DetailsPane extends StatelessWidget {
  const DetailsPane({super.key, required this.state, this.showBack = false});

  final BrowserState state;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final record = state.selectedRecord;
    final active = state.focusedPane == Pane.details;
    if (record == null) {
      final name = state.selectedPackage;
      if (name != null) return PackageInfoView(state: state, name: name);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(title: 'Details', active: active),
          const Expanded(
            child: CenteredMessage(
                'Browse conda packages: pick a package, then an artifact.'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          title: '${record.name} ${record.version}',
          subtitle: '${record.build} · ${record.subdir} · ${record.channel}',
          active: active,
          leading: showBack
              ? KitIconButton(
                  Icons.arrow_back,
                  tooltip: 'Back',
                  onPressed: state.back,
                )
              : null,
          trailing: [
            KitIconButton(
              Icons.link,
              tooltip: 'Copy package URL',
              onPressed: () =>
                  copyText(context, record.url, 'Copied ${record.url}'),
            ),
            KitIconButton(
              Icons.data_object,
              tooltip: 'Copy record as JSON  ( y )',
              onPressed: () => copyAsJson(context, state),
            ),
            KitIconButton(
              Icons.download,
              tooltip: 'Download ${record.fileName}  ( d )',
              onPressed: () => downloadRecord(context, record),
            ),
          ],
        ),
        _TabBar(state: state),
        Expanded(
          child: switch (state.detailTab) {
            DetailTab.metadata => _MetadataTab(state: state, record: record),
            DetailTab.dependencies =>
              _DependenciesTab(state: state, record: record),
            DetailTab.files => _FilesTab(state: state),
            DetailTab.about => _AboutTab(state: state),
            DetailTab.patches => _PatchesTab(state: state, record: record),
          },
        ),
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.state});
  final BrowserState state;

  @override
  Widget build(BuildContext context) {
    final record = state.selectedRecord!;
    String label(DetailTab tab) => switch (tab) {
          DetailTab.metadata => 'Metadata',
          DetailTab.dependencies =>
            'Dependencies (${record.depends.length})',
          DetailTab.files => state.contents == null
              ? 'Files'
              : 'Files (${state.contents!.files.length})',
          DetailTab.about => 'About',
          DetailTab.patches => _patchLabel(state, record),
        };
    return KitTabs<DetailTab>(
      tabs: [
        for (final (i, tab) in DetailTab.values.indexed)
          (tab, '${i + 1} ${label(tab)}'),
      ],
      selected: state.detailTab,
      onChanged: state.setDetailTab,
    );
  }
}

String _patchLabel(BrowserState state, PackageRecord record) {
  final index = state.contents?.indexJson;
  if (index == null) return 'Patches';
  final count = repodataPatches(index, record).length;
  return count == 0 ? 'Patches ✓' : 'Patches ($count)';
}

class _KeyValueTable extends StatelessWidget {
  const _KeyValueTable({required this.rows, this.header = const [], this.footer = const []});
  final List<(String, Widget)> rows;
  final List<Widget> header;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ...header,
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 170,
                    child: Text(label, style: KitText.dim(context)),
                  ),
                  Expanded(child: value),
                ],
              ),
            ),
          ...footer,
        ],
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.label, this.url);
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => openUrl(url),
        child: Text(
          label,
          style: mono(context, color: KitTheme.of(context).accent)
              .copyWith(decoration: TextDecoration.underline),
        ),
      ),
    );
  }
}

class _MetadataTab extends StatelessWidget {
  const _MetadataTab({required this.state, required this.record});
  final BrowserState state;
  final PackageRecord record;

  @override
  Widget build(BuildContext context) {
    final raw = record.raw;
    Widget text(Object? value) => Text(_value(value), style: mono(context));
    final about = state.contents?.aboutJson;
    final extra = about?['extra'];
    final maintainers = extra is Map ? _urls(extra['recipe-maintainers']) : const <String>[];
    final remote = extra is Map ? extra['remote_url'] as String? : null;
    final sha = extra is Map ? extra['sha'] as String? : null;
    final rows = <(String, Widget)>[
      ('Package', text(state.selectedPackage)),
      ('Name', text(record.name)),
      ('Version', text(record.version)),
      ('Build', text(record.build)),
      ('Build Number', text(record.buildNumber)),
      ('Subdir', text(record.subdir)),
      ('File Name', text(record.fileName)),
      ('Channel', text(record.channel)),
      ('Size', text(formatBytes(record.size))),
      ('Timestamp', text(formatTimestamp(record.timestamp))),
      ('License', text(raw['license'])),
      ('License Family', text(raw['license_family'])),
      if (raw['arch'] != null) ('Arch', text(raw['arch'])),
      if (raw['platform'] != null) ('Platform', text(raw['platform'])),
      ('NoArch', text(raw['noarch'])),
      if (raw['features'] != null) ('Features', text(raw['features'])),
      if (raw['track_features'] != null)
        ('Track Features', text(raw['track_features'])),
      if (raw['python_site_packages_path'] != null)
        ('Python Site-Packages', text(raw['python_site_packages_path'])),
      ('MD5', text(raw['md5'])),
      ('SHA256', text(raw['sha256'])),
      if (raw['legacy_bz2_md5'] != null)
        ('Legacy .tar.bz2 MD5', text(raw['legacy_bz2_md5'])),
      if (raw['legacy_bz2_size'] != null)
        ('Legacy .tar.bz2 Size',
            text(formatBytes((raw['legacy_bz2_size'] as num).toInt()))),
      ('Package URL', _Link(record.url, record.url)),
      for (final (label, key) in const [
        ('Repository', 'dev_url'),
        ('Documentation', 'doc_url'),
        ('Homepage', 'home'),
      ])
        if (_urls(about?[key]).isNotEmpty)
          (
            label,
            Wrap(
              spacing: 12,
              children: [for (final u in _urls(about?[key])) _Link(u, u)],
            ),
          ),
      if (maintainers.isNotEmpty)
        (
          'Recipe maintainers',
          Wrap(
            spacing: 10,
            runSpacing: 2,
            children: [
              for (final handle in maintainers)
                _Link('@$handle', 'https://github.com/$handle'),
            ],
          ),
        ),
      if (remote != null && sha != null)
        (
          'Provenance',
          _provenance(remote, sha),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ContentsBanner(state: state, purpose: 'links from about.json'),
        Expanded(child: _KeyValueTable(rows: rows)),
      ],
    );
  }

  Widget _provenance(String remote, String sha) {
    final match =
        RegExp(r'github\.com[:/]([^/]+/[^/]+?)(\.git)?$').firstMatch(remote);
    final label = '${match?.group(1) ?? remote}@${sha.length > 12 ? sha.substring(0, 12) : sha}';
    if (match == null) return Builder(builder: (c) => Text(label, style: mono(c)));
    return _Link(label, 'https://github.com/${match.group(1)}/commit/$sha');
  }
}

/// Explains why part of a tab needs the artifact itself, and offers to load
/// it when it was too large to fetch automatically.
class _ContentsBanner extends StatelessWidget {
  const _ContentsBanner({required this.state, required this.purpose});
  final BrowserState state;
  final String purpose;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    if (state.contents != null) return const SizedBox.shrink();
    Widget content;
    if (state.loadingContents) {
      content = Text('Reading the artifact for $purpose…', style: dim(context));
    } else if (state.contentsError != null) {
      content = Row(
        children: [
          Expanded(
            child: Text(
              'Could not read the artifact: ${state.contentsError}',
              style: KitText.small(context, color: c.danger),
            ),
          ),
          KitButton.ghost('Retry', onPressed: state.loadContents),
        ],
      );
    } else {
      content = Row(
        children: [
          Expanded(
            child: Text(
              'The artifact is ${formatBytes(state.selectedRecord?.size)}; '
              'download it to see $purpose.',
              style: dim(context),
            ),
          ),
          KitButton.ghost('Load contents', onPressed: state.loadContents),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: c.hover,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: content,
    );
  }
}

class _FilteredLines extends StatefulWidget {
  const _FilteredLines({super.key, required this.sections});
  final List<(String, List<String>)> sections;

  @override
  State<_FilteredLines> createState() => _FilteredLinesState();
}

class _FilteredLinesState extends State<_FilteredLines> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final children = <Widget>[];
    for (final (title, lines) in widget.sections) {
      final shown = substringFilter(_query, lines, (l) => l);
      if (lines.isEmpty || (shown.isEmpty && _query.isNotEmpty)) continue;
      children.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          '$title (${shown.length})',
          style: KitText.heading(context).copyWith(color: c.accent),
        ),
      ));
      for (final line in shown) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(line, style: mono(context)),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchField(
          controller: _controller,
          focusNode: _focus,
          hint: 'Filter',
          onChanged: (q) => setState(() => _query = q),
        ),
        Expanded(
          child: children.isEmpty
              ? CenteredMessage(_query.isEmpty ? 'Nothing here.' : 'No match.')
              : SelectionArea(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: children,
                  ),
                ),
        ),
      ],
    );
  }
}

class _DependenciesTab extends StatelessWidget {
  const _DependenciesTab({required this.state, required this.record});
  final BrowserState state;
  final PackageRecord record;

  @override
  Widget build(BuildContext context) {
    final runExports = <String, List<String>>{...record.runExports};
    final fromArchive = state.contents?.runExports;
    if (runExports.isEmpty && fromArchive != null) {
      fromArchive.forEach((key, value) {
        if (value is List) runExports[key] = [for (final v in value) '$v'];
      });
    }
    return _FilteredLines(
      key: ValueKey(record.url),
      sections: [
        ('Dependencies', record.depends),
        ('Constraints', record.constrains),
        for (final entry in record.extraDepends.entries)
          ('Extra: ${entry.key}', entry.value),
        (
          'Run exports',
          [
            for (final entry in runExports.entries)
              for (final value in entry.value) '${entry.key}: $value',
          ],
        ),
      ],
    );
  }
}

class _FilesTab extends StatefulWidget {
  const _FilesTab({required this.state});
  final BrowserState state;

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  bool _info = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final contents = state.contents;
    final c = KitTheme.of(context);
    if (contents == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ContentsBanner(state: state, purpose: 'its files'),
          const Expanded(child: SizedBox()),
        ],
      );
    }
    final infoPaths = contents.infoFiles.keys.toList();
    Widget list;
    if (_info) {
      final shown = substringFilter(_query, infoPaths, (p) => p);
      list = KitSelectionList(
        itemCount: shown.length,
        selectedIndex: -1,
        itemBuilder: (context, index, _) {
          final path = shown[index];
          final bytes = contents.infoFiles[path]!;
          return KitListRow(
            onTap: () => showInfoFileDialog(context, path, bytes),
            child: Row(
              children: [
                Expanded(
                  child: Text(path,
                      overflow: TextOverflow.ellipsis, style: mono(context)),
                ),
                Text(formatBytes(bytes.length), style: dim(context)),
              ],
            ),
          );
        },
      );
    } else {
      final shown = substringFilter(_query, contents.files, (f) => f.path);
      list = KitSelectionList(
        itemCount: shown.length,
        selectedIndex: -1,
        itemBuilder: (context, index, _) {
          final file = shown[index];
          final tags = [
            if (file.isSymlink) 'symlink',
            if (file.prefixPlaceholder != null)
              'prefix:${file.fileMode ?? 'text'}',
            if (file.noLink) 'no-link',
          ];
          return KitListRow(
            child: Row(
              children: [
                Expanded(
                  child: KitTooltip(
                    message: file.sha256 == null
                        ? file.path
                        : '${file.path}\nsha256 ${file.sha256}',
                    child: Text(file.path,
                        overflow: TextOverflow.ellipsis, style: mono(context)),
                  ),
                ),
                if (tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(tags.join(' '),
                        style: KitText.small(context, color: c.accent)),
                  ),
                SizedBox(
                  width: 84,
                  child: Text(
                    formatBytes(file.sizeInBytes),
                    textAlign: TextAlign.right,
                    style: dim(context),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitSegmented<bool>(
              segments: [
                (false, 'Package (${contents.files.length})'),
                (true, 'info/ (${infoPaths.length})'),
              ],
              selected: _info,
              onChanged: (info) => setState(() => _info = info),
            ),
          ),
        ),
        SearchField(
          controller: _controller,
          focusNode: _focus,
          hint: 'Filter files',
          onChanged: (q) => setState(() => _query = q),
        ),
        Expanded(child: list),
      ],
    );
  }
}

class _AboutTab extends StatelessWidget {
  const _AboutTab({required this.state});
  final BrowserState state;

  @override
  Widget build(BuildContext context) {
    final about = state.contents?.aboutJson;
    if (about == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ContentsBanner(state: state, purpose: 'about.json'),
          Expanded(
            child: state.contents == null
                ? const SizedBox()
                : const CenteredMessage('This artifact has no about.json.'),
          ),
        ],
      );
    }
    final c = KitTheme.of(context);
    final summary = about['summary'] as String?;
    final description = about['description'] as String?;
    final rest = Map<String, Object?>.of(about)
      ..remove('summary')
      ..remove('description');
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (summary != null && summary.trim().isNotEmpty)
            Text(summary.trim(),
                style: KitText.heading(context).copyWith(fontSize: 15)),
          if (description != null && description.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(description.trim()),
          ],
          const SizedBox(height: 12),
          Text('about.json',
              style: KitText.heading(context).copyWith(color: c.accent)),
          const SizedBox(height: 4),
          Text(
            const JsonEncoder.withIndent('  ').convert(rest),
            style: mono(context, size: 12),
          ),
        ],
      ),
    );
  }
}

class _PatchesTab extends StatelessWidget {
  const _PatchesTab({required this.state, required this.record});
  final BrowserState state;
  final PackageRecord record;

  @override
  Widget build(BuildContext context) {
    final index = state.contents?.indexJson;
    if (index == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ContentsBanner(
            state: state,
            purpose: 'repodata patches against its index.json',
          ),
          Expanded(
            child: state.contents == null
                ? const SizedBox()
                : const CenteredMessage('This artifact has no index.json.'),
          ),
        ],
      );
    }
    final rows = repodataPatches(index, record);
    if (rows.isEmpty) {
      return const CenteredMessage(
        'Not patched: the channel serves the metadata of info/index.json '
        'unchanged.',
      );
    }
    final c = KitTheme.of(context);
    Widget cell(String text, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            text,
            style: mono(
              context,
              color: color,
              weight: bold ? FontWeight.bold : null,
            ),
          ),
        );
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'The channel rewrote ${rows.length} field${rows.length == 1 ? '' : 's'} '
            'of this artifact\'s info/index.json.',
          ),
          const SizedBox(height: 8),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
            },
            border: TableBorder.all(color: c.border),
            children: [
              TableRow(children: [
                cell('Field', bold: true),
                cell('index.json', bold: true),
                cell('repodata (${channelUrl(record.channel)})', bold: true),
              ]),
              for (final row in rows)
                TableRow(children: [
                  cell(row.label),
                  cell(row.original, color: c.danger),
                  cell(row.patched, color: c.success),
                ]),
            ],
          ),
        ],
      ),
    );
  }
}

/// What is known about a package before any artifact is picked: its
/// `channeldata.json` entry, filled in from the newest artifact's record
/// where the channel has none.
class PackageInfoView extends StatelessWidget {
  const PackageInfoView({super.key, required this.state, required this.name});

  final BrowserState state;
  final String name;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final info = state.infoFor(name);
    final records = state.records;
    final newest = records.isEmpty ? null : records.first;
    Widget text(Object? value) => Text(_value(value), style: mono(context));
    Widget links(List<String> urls) => Wrap(
          spacing: 12,
          children: [for (final u in urls) _Link(u, u)],
        );
    final versions = [for (final v in {for (final r in records) r.version}) v];
    final platforms = info != null && info.subdirs.isNotEmpty
        ? ([...info.subdirs]..sort(comparePlatforms))
        : ({for (final r in records) r.subdir}.toList()..sort(comparePlatforms));
    final rows = <(String, Widget)>[
      ('Latest version', text(info?.version ?? newest?.version)),
      ('License', text(info?.license ?? newest?.license)),
      if (info?.licenseFamily != null) ('License family', text(info!.licenseFamily)),
      ('Channel', text(info?.channel ?? newest?.channel)),
      if (platforms.isNotEmpty) ('Platforms', text(platforms)),
      if (versions.isNotEmpty)
        (
          'Versions',
          Text(
            versions.length > 30
                ? '${versions.take(30).join(', ')} … (${versions.length})'
                : versions.join(', '),
            style: mono(context),
          ),
        ),
      if (info?.timestamp != null || newest?.timestamp != null)
        ('Last updated', text(formatTimestamp(info?.timestamp ?? newest?.timestamp))),
      if (info != null && info.home.isNotEmpty) ('Homepage', links(info.home)),
      if (info != null && info.devUrl.isNotEmpty) ('Repository', links(info.devUrl)),
      if (info != null && info.docUrl.isNotEmpty) ('Documentation', links(info.docUrl)),
      if (info?.sourceGitUrl != null)
        ('Source', links([info!.sourceGitUrl!]))
      else if (info != null && info.sourceUrl.isNotEmpty)
        ('Source', links(info.sourceUrl)),
      if (info != null && info.keywords.isNotEmpty) ('Keywords', text(info.keywords)),
    ];
    final String? note;
    if (info != null) {
      note = null;
    } else if (state.loadingChannelData) {
      note = 'Loading the summary from channeldata.json…';
    } else if (state.channelInfo.isEmpty) {
      note = 'This channel serves no channeldata.json; showing the newest '
          'artifact\'s record.';
    } else {
      note = 'channeldata.json has no entry for $name; showing the newest '
          'artifact\'s record.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          title: name,
          subtitle: info?.summary ?? 'Package',
          active: state.focusedPane == Pane.details,
          trailing: [
            KitIconButton(
              Icons.data_object,
              tooltip: 'Copy package info as JSON  ( y )',
              onPressed: () => copyAsJson(context, state),
            ),
          ],
        ),
        Expanded(
          child: _KeyValueTable(
            header: [
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(note, style: dim(context)),
                ),
              if (info?.summary != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(info!.summary!,
                      style: KitText.heading(context).copyWith(fontSize: 15)),
                ),
              if (info?.description != null && info!.description != info.summary)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(info.description!),
                ),
            ],
            rows: rows,
            footer: [
              const SizedBox(height: 16),
              Text(
                'Pick an artifact to see its dependencies, files and patches.',
                style: KitText.small(context, color: c.textDim),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
