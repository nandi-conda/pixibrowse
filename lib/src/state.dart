import 'dart:async';

import 'package:flutter/foundation.dart';

import 'conda/artifact.dart';
import 'conda/channeldata.dart';
import 'conda/models.dart';
import 'conda/prefix.dart';
import 'conda/repodata.dart';
import 'search.dart';
import 'settings/channel_store.dart';

enum Pane { packages, versions, details }

/// The collapsible sections of the artifact view, in on-screen order.
enum DetailSection { metadata, dependencies, about, patches, files }

/// A row of the version list: either a collapsible subdir header or one
/// artifact.
class VersionRow {
  const VersionRow.section(this.subdir, this.count) : record = null;
  const VersionRow.entry(PackageRecord this.record)
      : subdir = null,
        count = 0;

  final String? subdir;
  final int count;
  final PackageRecord? record;

  bool get isSection => record == null;
}

/// Artifacts above this size are only downloaded when asked for.
const int autoLoadContentsLimit = 25 * 1024 * 1024;

class BrowserState extends ChangeNotifier {
  BrowserState({
    RepodataClient? client,
    List<String>? channels,
    List<String>? platforms,
    this.channelStore,
  })  : client = client ?? RepodataClient(),
        channels = normalizeChannels(
            channels ?? channelStore?.load() ?? const [defaultChannel]),
        _requestedPlatforms = platforms {
    if (this.channels.isEmpty) this.channels = [defaultChannel];
  }

  final RepodataClient client;

  /// Where the user's channel choice is kept between runs, if anywhere.
  final ChannelStore? channelStore;
  List<String> channels;
  List<String>? _requestedPlatforms;

  List<String> availablePlatforms = const [];
  List<String> selectedPlatforms = const [];

  bool loadingChannels = false;
  String? status;
  String? error;

  List<String> _allPackages = const [];
  String packageQuery = '';
  List<String> packages = const [];

  /// Why each listed package matched the query, when it was not its name.
  Map<String, MatchKind> packageMatches = const {};

  /// What `channeldata.json` says about each package, the first channel
  /// that knows a package winning. Fills in after the package names.
  Map<String, ChannelPackage> channelInfo = const {};
  bool loadingChannelData = false;
  String? channelDataError;

  /// The channels that served a `channeldata.json`.
  Set<String> channelsWithChannelData = const {};

  /// Summaries looked up one package at a time from prefix.dev, whose
  /// channels have no channeldata.
  final Map<String, ChannelPackage> _prefixDevInfo = {};
  final Set<String> _prefixDevLookups = {};
  String? prefixDevError;

  /// Whether prefix.dev is still being asked about [name].
  bool lookingUp(String name) => _prefixDevLookups.contains(name);

  /// Whether the package search also looks at summaries and descriptions.
  bool searchSummaries = true;
  int packageIndex = 0;

  String? selectedPackage;
  List<PackageRecord> records = const [];
  bool loadingRecords = false;
  String? recordsError;
  String versionQuery = '';
  final Set<String> collapsedSubdirs = {};
  List<VersionRow> versionRows = const [];
  int versionIndex = 0;

  PackageRecord? selectedRecord;
  /// Sections the user folded away; kept while moving between artifacts.
  final Set<DetailSection> collapsedSections = {};
  ArtifactContents? contents;
  bool loadingContents = false;
  String? contentsError;

  Pane focusedPane = Pane.packages;

  int _generation = 0;

  int get totalPackages => _allPackages.length;

  Future<void> start() => loadChannels(channels);

  /// Switches to the channels the user chose and remembers them for the
  /// next run.
  Future<void> setChannels(List<String> newChannels) {
    final normalized = normalizeChannels(newChannels);
    if (normalized.isNotEmpty) channelStore?.save(normalized);
    return loadChannels(normalized);
  }

  Future<void> loadChannels(List<String> newChannels) async {
    final generation = ++_generation;
    channels = normalizeChannels(newChannels);
    if (channels.isEmpty) channels = [defaultChannel];
    loadingChannels = true;
    error = null;
    status = 'Discovering platforms of ${channels.join(', ')}…';
    _clearPackage();
    notifyListeners();
    channelInfo = const {};
    channelsWithChannelData = const {};
    channelDataError = null;
    _prefixDevInfo.clear();
    _prefixDevLookups.clear();
    prefixDevError = null;
    try {
      final platforms = await client.discoverPlatforms(
        channels,
        onProgress: (done, total) {
          if (generation != _generation) return;
          status = 'Discovering platforms ($done/$total)…';
          notifyListeners();
        },
      );
      if (generation != _generation) return;
      availablePlatforms = platforms;
      final requested = _requestedPlatforms;
      final keep = requested == null
          ? platforms
          : platforms.where(requested.contains).toList();
      selectedPlatforms = keep.isEmpty ? platforms : keep;
      await _loadPackageNames(generation);
      unawaited(_loadChannelData(generation));
    } catch (e) {
      if (generation != _generation) return;
      error = '$e';
      status = null;
      _allPackages = const [];
      _applyPackageFilter();
    } finally {
      if (generation == _generation) {
        loadingChannels = false;
        notifyListeners();
      }
    }
  }

  Future<void> setPlatforms(List<String> platforms) async {
    final generation = ++_generation;
    selectedPlatforms = [...platforms]..sort(comparePlatforms);
    loadingChannels = true;
    _clearPackage();
    notifyListeners();
    try {
      await _loadPackageNames(generation);
    } catch (e) {
      if (generation == _generation) error = '$e';
    } finally {
      if (generation == _generation) {
        loadingChannels = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadPackageNames(int generation) async {
    status = 'Loading package names…';
    notifyListeners();
    final names = await client.packageNames(channels, selectedPlatforms);
    if (generation != _generation) return;
    _allPackages = names;
    status = null;
    _applyPackageFilter();
  }

  Future<void> _loadChannelData(int generation) async {
    loadingChannelData = true;
    notifyListeners();
    final merged = <String, ChannelPackage>{};
    final served = <String>{};
    final errors = <String>[];
    for (final channel in channels) {
      try {
        final info = await client.channelData(channel);
        if (generation != _generation) return;
        if (info.isNotEmpty) served.add(channel);
        for (final entry in info.entries) {
          merged.putIfAbsent(entry.key, () => entry.value);
        }
      } catch (e) {
        errors.add('$channel: $e');
      }
    }
    if (generation != _generation) return;
    channelInfo = merged;
    channelsWithChannelData = served;
    channelDataError = errors.isEmpty ? null : errors.join('\n');
    loadingChannelData = false;
    if (packageQuery.trim().isNotEmpty) _applyPackageFilter(keepSelection: true);
    notifyListeners();
  }

  /// What the channel says about [name], from its channeldata or, on
  /// prefix.dev, its GraphQL API.
  ChannelPackage? infoFor(String name) =>
      channelInfo[name] ?? _prefixDevInfo[name];

  /// Asks prefix.dev about [name] when a channel is hosted there and no
  /// channeldata has an entry for it, trying channels in order.
  Future<void> _lookUpPrefixDev(String name) async {
    final hosted = [
      for (final channel in channels)
        if (prefixDevChannelName(channel) != null) channel,
    ];
    if (hosted.isEmpty ||
        channelInfo.containsKey(name) ||
        _prefixDevInfo.containsKey(name) ||
        !_prefixDevLookups.add(name)) {
      return;
    }
    final generation = _generation;
    prefixDevError = null;
    notifyListeners();
    try {
      for (final channel in hosted) {
        final info = await fetchPrefixDevPackage(client.client, channel, name);
        if (generation != _generation) return;
        if (info != null) {
          _prefixDevInfo[name] = info;
          break;
        }
      }
    } catch (e) {
      if (generation == _generation) prefixDevError = '$e';
    } finally {
      if (generation == _generation) {
        _prefixDevLookups.remove(name);
        notifyListeners();
      }
    }
  }

  /// Downloads everything again, ignoring what is cached, and keeps the
  /// current platform selection.
  Future<void> refresh() {
    client.refresh();
    if (selectedPlatforms.isNotEmpty) _requestedPlatforms = selectedPlatforms;
    return loadChannels(channels);
  }

  void setPackageQuery(String query) {
    packageQuery = query;
    _applyPackageFilter();
    notifyListeners();
  }

  void setSearchSummaries(bool value) {
    searchSummaries = value;
    _applyPackageFilter();
    notifyListeners();
  }

  void _applyPackageFilter({bool keepSelection = false}) {
    final current = keepSelection && packageIndex < packages.length
        ? packages[packageIndex]
        : null;
    final useInfo = searchSummaries && channelInfo.isNotEmpty;
    final hits = rankPackages(
      packageQuery,
      _allPackages,
      summary: useInfo ? (n) => channelInfo[n]?.summaryLower : null,
      description: useInfo ? (n) => channelInfo[n]?.descriptionLower : null,
    );
    packages = [for (final (name, _) in hits) name];
    packageMatches = {
      for (final (name, kind) in hits)
        if (kind != MatchKind.name) name: kind,
    };
    final keep = current == null ? -1 : packages.indexOf(current);
    packageIndex = keep < 0 ? 0 : keep;
  }

  void moveSelection(Pane pane, int delta) {
    switch (pane) {
      case Pane.packages:
        if (packages.isEmpty) return;
        packageIndex = (packageIndex + delta).clamp(0, packages.length - 1);
      case Pane.versions:
        if (versionRows.isEmpty) return;
        versionIndex = (versionIndex + delta).clamp(0, versionRows.length - 1);
      case Pane.details:
        return;
    }
    notifyListeners();
  }

  void jumpSelection(Pane pane, {required bool toEnd}) {
    switch (pane) {
      case Pane.packages:
        if (packages.isEmpty) return;
        packageIndex = toEnd ? packages.length - 1 : 0;
      case Pane.versions:
        if (versionRows.isEmpty) return;
        versionIndex = toEnd ? versionRows.length - 1 : 0;
      case Pane.details:
        return;
    }
    notifyListeners();
  }

  void focusPane(Pane pane) {
    focusedPane = pane;
    notifyListeners();
  }

  void _clearPackage() {
    selectedPackage = null;
    records = const [];
    versionRows = const [];
    recordsError = null;
    loadingRecords = false;
    _clearRecord();
  }

  void _clearRecord() {
    selectedRecord = null;
    contents = null;
    contentsError = null;
    loadingContents = false;
  }

  Future<void> openPackage(String name) async {
    final generation = _generation;
    if (packages.contains(name)) packageIndex = packages.indexOf(name);
    selectedPackage = name;
    records = const [];
    versionRows = const [];
    versionQuery = '';
    collapsedSubdirs.clear();
    recordsError = null;
    loadingRecords = true;
    _clearRecord();
    focusedPane = Pane.versions;
    notifyListeners();
    unawaited(_lookUpPrefixDev(name));
    try {
      final result =
          await client.records(name, channels, selectedPlatforms);
      if (generation != _generation || selectedPackage != name) return;
      records = result;
      _buildVersionRows();
      versionIndex = versionRows.length > 1 ? 1 : 0;
    } catch (e) {
      if (selectedPackage == name) recordsError = '$e';
    } finally {
      if (selectedPackage == name) {
        loadingRecords = false;
        notifyListeners();
      }
    }
  }

  void setVersionQuery(String query) {
    versionQuery = query;
    _buildVersionRows();
    versionIndex = versionRows.length > 1 ? 1 : 0;
    notifyListeners();
  }

  void toggleSubdir(String subdir) {
    if (!collapsedSubdirs.remove(subdir)) collapsedSubdirs.add(subdir);
    final current =
        versionIndex < versionRows.length ? versionRows[versionIndex] : null;
    _buildVersionRows();
    if (current != null) {
      final index = versionRows.indexWhere((row) =>
          row.subdir == current.subdir && row.record == current.record);
      versionIndex = index < 0 ? 0 : index;
    }
    notifyListeners();
  }

  /// Subdirs sorted by their newest version, then by name; artifacts newest
  /// first inside each.
  void _buildVersionRows() {
    final filtered = [
      ...substringFilter(
        versionQuery,
        records,
        (r) => '${r.version} ${r.build} ${r.fileName}',
      ),
    ]..sort(PackageRecord.newestFirst);
    final bySubdir = <String, List<PackageRecord>>{};
    for (final record in filtered) {
      bySubdir.putIfAbsent(record.subdir, () => []).add(record);
    }
    final subdirs = bySubdir.keys.toList()
      ..sort((a, b) {
        final c = bySubdir[b]!.first.parsedVersion
            .compareTo(bySubdir[a]!.first.parsedVersion);
        return c != 0 ? c : a.compareTo(b);
      });
    versionRows = [
      for (final subdir in subdirs) ...[
        VersionRow.section(subdir, bySubdir[subdir]!.length),
        if (!collapsedSubdirs.contains(subdir))
          for (final record in bySubdir[subdir]!) VersionRow.entry(record),
      ],
    ];
  }

  void activateVersionRow(int index) {
    if (index < 0 || index >= versionRows.length) return;
    versionIndex = index;
    final row = versionRows[index];
    if (row.isSection) {
      toggleSubdir(row.subdir!);
    } else {
      selectRecord(row.record!);
    }
  }

  void selectRecord(PackageRecord record) {
    selectedRecord = record;
    contents = null;
    contentsError = null;
    loadingContents = false;
    focusedPane = Pane.details;
    notifyListeners();
    if ((record.size ?? 0) <= autoLoadContentsLimit) {
      unawaited(loadContents());
    }
  }

  Future<void> loadContents() async {
    final record = selectedRecord;
    if (record == null || loadingContents || contents != null) return;
    loadingContents = true;
    contentsError = null;
    notifyListeners();
    try {
      final result = await loadArtifactContents(client.client, record);
      if (selectedRecord != record) return;
      contents = result;
    } catch (e) {
      if (selectedRecord == record) contentsError = '$e';
    } finally {
      if (selectedRecord == record) {
        loadingContents = false;
        notifyListeners();
      }
    }
  }

  void toggleSection(DetailSection section) {
    if (!collapsedSections.remove(section)) collapsedSections.add(section);
    notifyListeners();
  }

  /// Steps back one level: details → versions → packages.
  bool back() {
    if (selectedRecord != null) {
      _clearRecord();
      focusedPane = Pane.versions;
      notifyListeners();
      return true;
    }
    if (selectedPackage != null) {
      _clearPackage();
      focusedPane = Pane.packages;
      notifyListeners();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }
}
