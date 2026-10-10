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
              'Browse conda packages: pick a package, then an artifact.',
            ),
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
        _ContentsBanner(
          state: state,
          purpose: 'its files, about.json and repodata patches',
        ),
        Expanded(
          child: ArtifactView(
            key: ValueKey(record.url),
            state: state,
            record: record,
          ),
        ),
      ],
    );
  }
}

class _KeyValueTable extends StatelessWidget {
  const _KeyValueTable({
    required this.rows,
    this.header = const [],
    this.footer = const [],
  });
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
          style: mono(
            context,
            color: KitTheme.of(context).accent,
          ).copyWith(decoration: TextDecoration.underline),
        ),
      ),
    );
  }
}

/// Explains why part of the view needs the artifact itself, and offers to load
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
    Widget links(List<String> urls) =>
        Wrap(spacing: 12, children: [for (final u in urls) _Link(u, u)]);
    final versions = [
      for (final v in {for (final r in records) r.version}) v,
    ];
    final platforms = info != null && info.subdirs.isNotEmpty
        ? ([...info.subdirs]..sort(comparePlatforms))
        : ({for (final r in records) r.subdir}.toList()
            ..sort(comparePlatforms));
    final rows = <(String, Widget)>[
      ('Latest version', text(info?.version ?? newest?.version)),
      ('License', text(info?.license ?? newest?.license)),
      if (info?.licenseFamily != null)
        ('License family', text(info!.licenseFamily)),
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
        (
          'Last updated',
          text(formatTimestamp(info?.timestamp ?? newest?.timestamp)),
        ),
      if (info != null && info.home.isNotEmpty) ('Homepage', links(info.home)),
      if (info != null && info.devUrl.isNotEmpty)
        ('Repository', links(info.devUrl)),
      if (info != null && info.docUrl.isNotEmpty)
        ('Documentation', links(info.docUrl)),
      if (info?.sourceGitUrl != null)
        ('Source', links([info!.sourceGitUrl!]))
      else if (info != null && info.sourceUrl.isNotEmpty)
        ('Source', links(info.sourceUrl)),
      if (info != null && info.keywords.isNotEmpty)
        ('Keywords', text(info.keywords)),
    ];
    final String? note;
    if (info != null) {
      note = null;
    } else if (state.loadingChannelData) {
      note = 'Loading the summary from channeldata.json…';
    } else if (state.channelInfo.isEmpty) {
      note =
          'This channel serves no channeldata.json; showing the newest '
          'artifact\'s record.';
    } else {
      note =
          'channeldata.json has no entry for $name; showing the newest '
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
                  child: Text(
                    info!.summary!,
                    style: KitText.heading(context).copyWith(fontSize: 15),
                  ),
                ),
              if (info?.description != null &&
                  info!.description != info.summary)
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

/// Everything about one artifact on a single scrollable page: a dense
/// metadata grid, then dependencies, about, patches and files, each under a
/// header that folds it away (keys 1 – 5).
class ArtifactView extends StatefulWidget {
  const ArtifactView({super.key, required this.state, required this.record});
  final BrowserState state;
  final PackageRecord record;

  @override
  State<ArtifactView> createState() => _ArtifactViewState();
}

class _ArtifactViewState extends State<ArtifactView> {
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  String _query = '';
  bool _info = false;
  bool _aboutJson = false;

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  BrowserState get state => widget.state;
  PackageRecord get record => widget.record;

  @override
  Widget build(BuildContext context) {
    final contents = state.contents;
    final deps = _dependencyGroups();
    final depCount = deps.fold(0, (n, g) => n + g.$2.length);
    final index = contents?.indexJson;
    final patches = index == null ? null : repodataPatches(index, record);
    final about = contents?.aboutJson;
    final slivers = <Widget>[
      ..._section(
        DetailSection.metadata,
        'Metadata',
        null,
        () => [_MetadataGrid(state: state, record: record)],
      ),
      ..._section(
        DetailSection.dependencies,
        'Dependencies',
        '$depCount',
        () => [
          if (deps.isEmpty) _note('No dependencies.'),
          for (final (title, lines) in deps) ...[
            _subheading(title, lines.length),
            _ColumnGrid(
              minCell: 220,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    style: mono(context),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ],
        ],
      ),
      ..._section(
        DetailSection.about,
        'About',
        null,
        () => contents == null
            ? [_note('Needs the artifact contents.')]
            : about == null
            ? [_note('This artifact has no about.json.')]
            : _aboutBody(about),
      ),
      ..._section(
        DetailSection.patches,
        'Patches',
        patches == null
            ? null
            : patches.isEmpty
            ? '✓'
            : '${patches.length}',
        () => contents == null
            ? [_note('Needs the artifact contents.')]
            : patches == null
            ? [_note('This artifact has no index.json.')]
            : _patchesBody(patches),
      ),
      ..._filesSlivers(),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
    return SelectionArea(child: CustomScrollView(slivers: slivers));
  }

  /// A header, plus [body] laid out under it unless the user folded it.
  List<Widget> _section(
    DetailSection section,
    String title,
    String? count,
    List<Widget> Function() body,
  ) {
    final open = !state.collapsedSections.contains(section);
    return [
      SliverToBoxAdapter(
        child: _SectionHeader(
          number: section.index + 1,
          title: title,
          count: count,
          open: open,
          onToggle: () => state.toggleSection(section),
        ),
      ),
      if (open)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          sliver: SliverList.list(children: body()),
        ),
    ];
  }

  Widget _note(String text) => Text(text, style: dim(context));

  Widget _subheading(String title, int count) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 2),
    child: Text(
      '$title ($count)',
      style: KitText.small(
        context,
        color: KitTheme.of(context).textDim,
      ).copyWith(fontWeight: FontWeight.w600),
    ),
  );

  List<(String, List<String>)> _dependencyGroups() {
    final runExports = <String, List<String>>{...record.runExports};
    final fromArchive = state.contents?.runExports;
    if (runExports.isEmpty && fromArchive != null) {
      fromArchive.forEach((key, value) {
        if (value is List) runExports[key] = [for (final v in value) '$v'];
      });
    }
    return [
      ('Depends', record.depends),
      ('Constrains', record.constrains),
      for (final entry in record.extraDepends.entries)
        ('Extra: ${entry.key}', entry.value),
      (
        'Run exports',
        [
          for (final entry in runExports.entries)
            for (final value in entry.value) '${entry.key}: $value',
        ],
      ),
    ].where((g) => g.$2.isNotEmpty).toList();
  }

  List<Widget> _aboutBody(Map<String, Object?> about) {
    final summary = (about['summary'] as String?)?.trim();
    final description = (about['description'] as String?)?.trim();
    final rest = Map<String, Object?>.of(about)
      ..remove('summary')
      ..remove('description');
    return [
      if (summary != null && summary.isNotEmpty)
        Text(summary, style: KitText.heading(context)),
      if (description != null && description.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(description),
      ],
      if (rest.isNotEmpty) ...[
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: KitButton.ghost(
            _aboutJson ? '▾ about.json' : '▸ about.json (${rest.length} keys)',
            onPressed: () => setState(() => _aboutJson = !_aboutJson),
          ),
        ),
        if (_aboutJson)
          Text(
            const JsonEncoder.withIndent('  ').convert(rest),
            style: mono(context, size: 12),
          ),
      ],
    ];
  }

  List<Widget> _patchesBody(List<PatchRow> rows) {
    if (rows.isEmpty) {
      return [
        _note(
          'Not patched: the channel serves the metadata of '
          'info/index.json unchanged.',
        ),
      ];
    }
    final c = KitTheme.of(context);
    Widget cell(String text, {Color? color, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        text,
        style: mono(
          context,
          color: color,
          weight: bold ? FontWeight.bold : null,
        ),
      ),
    );
    return [
      Table(
        columnWidths: const {
          0: IntrinsicColumnWidth(),
          1: FlexColumnWidth(),
          2: FlexColumnWidth(),
        },
        border: TableBorder.all(color: c.border),
        children: [
          TableRow(
            children: [
              cell('Field', bold: true),
              cell('index.json', bold: true),
              cell('repodata (${channelUrl(record.channel)})', bold: true),
            ],
          ),
          for (final row in rows)
            TableRow(
              children: [
                cell(row.label),
                cell(row.original, color: c.danger),
                cell(row.patched, color: c.success),
              ],
            ),
        ],
      ),
    ];
  }

  List<Widget> _filesSlivers() {
    final contents = state.contents;
    const section = DetailSection.files;
    final open = !state.collapsedSections.contains(section);
    final header = SliverToBoxAdapter(
      child: _SectionHeader(
        number: section.index + 1,
        title: 'Files',
        count: contents == null ? null : '${contents.files.length}',
        open: open,
        onToggle: () => state.toggleSection(section),
      ),
    );
    if (!open) return [header];
    if (contents == null) {
      return [
        header,
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          sliver: SliverToBoxAdapter(
            child: _note('Needs the artifact contents.'),
          ),
        ),
      ];
    }
    final c = KitTheme.of(context);
    final infoPaths = contents.infoFiles.keys.toList();
    final controls = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
        child: Row(
          children: [
            KitSegmented<bool>(
              segments: [
                (false, 'Package (${contents.files.length})'),
                (true, 'info/ (${infoPaths.length})'),
              ],
              selected: _info,
              onChanged: (info) => setState(() => _info = info),
            ),
            Expanded(
              child: SearchField(
                controller: _filter,
                focusNode: _filterFocus,
                hint: 'Filter files',
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
          ],
        ),
      ),
    );
    Widget list;
    if (_info) {
      final shown = substringFilter(_query, infoPaths, (p) => p);
      list = SliverFixedExtentList.builder(
        itemExtent: kitRowHeight,
        itemCount: shown.length,
        itemBuilder: (context, index) {
          final path = shown[index];
          final bytes = contents.infoFiles[path]!;
          return KitListRow(
            onTap: () => showInfoFileDialog(context, path, bytes),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    path,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context),
                  ),
                ),
                Text(formatBytes(bytes.length), style: dim(context)),
              ],
            ),
          );
        },
      );
    } else {
      final shown = substringFilter(_query, contents.files, (f) => f.path);
      list = SliverFixedExtentList.builder(
        itemExtent: kitRowHeight,
        itemCount: shown.length,
        itemBuilder: (context, index) {
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
                    child: Text(
                      file.path,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context),
                    ),
                  ),
                ),
                if (tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      tags.join(' '),
                      style: KitText.small(context, color: c.accent),
                    ),
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
    return [
      header,
      controls,
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        sliver: list,
      ),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.number,
    required this.title,
    required this.count,
    required this.open,
    required this.onToggle,
  });
  final int number;
  final String title;
  final String? count;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Pressable(
      onPressed: onToggle,
      builder: (context, s) => Container(
        height: kitRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: s.hovered ? c.hover : c.surface,
          border: Border(
            top: BorderSide(color: c.border),
            bottom: BorderSide(color: c.border),
          ),
        ),
        child: Row(
          children: [
            Text(open ? '▾' : '▸', style: dim(context)),
            const SizedBox(width: 6),
            Text(
              title,
              style: KitText.body(context)
                  .copyWith(fontWeight: FontWeight.w600, color: c.accent),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text(count!, style: dim(context)),
            ],
            const Spacer(),
            Text('$number', style: dim(context)),
          ],
        ),
      ),
    );
  }
}

/// Lays [children] out row by row in as many equal columns as fit, each at
/// least [minCell] wide.
class _ColumnGrid extends StatelessWidget {
  const _ColumnGrid({required this.children, this.minCell = 260});
  final List<Widget> children;
  final double minCell;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / minCell).floor().clamp(1, 4);
        final width = constraints.maxWidth / columns;
        return Wrap(
          children: [
            for (final child in children)
              SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, top: 1, bottom: 1),
                  child: child,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetadataGrid extends StatelessWidget {
  const _MetadataGrid({required this.state, required this.record});
  final BrowserState state;
  final PackageRecord record;

  @override
  Widget build(BuildContext context) {
    final raw = record.raw;
    Widget text(Object? value) => Text(
      _value(value),
      style: mono(context),
      overflow: TextOverflow.ellipsis,
    );
    Widget pair(String label, Widget value, {double labelWidth = 92}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(
            label,
            style: dim(context),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(child: value),
      ],
    );
    final about = state.contents?.aboutJson;
    final extra = about?['extra'];
    final maintainers = extra is Map
        ? _urls(extra['recipe-maintainers'])
        : const <String>[];
    final remote = extra is Map ? extra['remote_url'] as String? : null;
    final sha = extra is Map ? extra['sha'] as String? : null;

    final short = <(String, Object?)>[
      if (state.selectedPackage != record.name)
        ('Package', state.selectedPackage),
      ('Version', record.version),
      ('Build', record.build),
      ('Build no.', record.buildNumber),
      ('Subdir', record.subdir),
      ('Size', formatBytes(record.size)),
      ('Built', formatTimestamp(record.timestamp)),
      ('License', raw['license']),
      if (raw['license_family'] != null) ('Lic. family', raw['license_family']),
      if (raw['noarch'] != null) ('NoArch', raw['noarch']),
      if (raw['arch'] != null) ('Arch', raw['arch']),
      if (raw['platform'] != null) ('Platform', raw['platform']),
      if (raw['features'] != null) ('Features', raw['features']),
      if (raw['track_features'] != null) ('Track feat.', raw['track_features']),
      if (raw['legacy_bz2_size'] != null)
        ('.tar.bz2 size', formatBytes((raw['legacy_bz2_size'] as num).toInt())),
    ];
    final long = <(String, Widget)>[
      ('File', text(record.fileName)),
      ('URL', _Link(record.url, record.url)),
      if (raw['python_site_packages_path'] != null)
        ('Site-packages', text(raw['python_site_packages_path'])),
      ('SHA256', text(raw['sha256'])),
      ('MD5', text(raw['md5'])),
      if (raw['legacy_bz2_md5'] != null)
        ('.tar.bz2 MD5', text(raw['legacy_bz2_md5'])),
      for (final (label, key) in const [
        ('Homepage', 'home'),
        ('Repository', 'dev_url'),
        ('Docs', 'doc_url'),
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
          'Maintainers',
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
        ('Provenance', _provenance(remote, sha)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ColumnGrid(
          minCell: 250,
          children: [for (final (l, v) in short) pair(l, text(v))],
        ),
        const SizedBox(height: 4),
        for (final (l, v) in long)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: pair(l, v),
          ),
      ],
    );
  }

  Widget _provenance(String remote, String sha) {
    final match = RegExp(r'github\.com[:/]([^/]+/[^/]+?)(\.git)?$')
        .firstMatch(remote);
    final label =
        '${match?.group(1) ?? remote}@${sha.length > 12 ? sha.substring(0, 12) : sha}';
    if (match == null) {
      return Builder(builder: (c) => Text(label, style: mono(c)));
    }
    return _Link(label, 'https://github.com/${match.group(1)}/commit/$sha');
  }
}
