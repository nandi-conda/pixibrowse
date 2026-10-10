import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../state.dart';
import 'details.dart';
import 'dialogs.dart';
import 'panes.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});
  final BrowserState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BrowserState get state => widget.state;

  final _packageSearch = TextEditingController();
  final _packageSearchFocus = FocusNode(debugLabel: 'package search');
  final _versionSearch = TextEditingController();
  final _versionSearchFocus = FocusNode(debugLabel: 'version search');
  String? _shownPackage;
  bool _pendingG = false;

  @override
  void initState() {
    super.initState();
    state.addListener(_onState);
    // A global handler sees keys whatever holds focus, as in the TUI.
    HardwareKeyboard.instance.addHandler(_onKey);
    state.start();
  }

  void _onState() {
    // A new package starts with an empty version filter.
    if (state.selectedPackage != _shownPackage) {
      _shownPackage = state.selectedPackage;
      _versionSearch.clear();
    }
    if (state.packageQuery != _packageSearch.text) {
      _packageSearch.text = state.packageQuery;
    }
    setState(() {});
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _packageSearch.dispose();
    _packageSearchFocus.dispose();
    _versionSearch.dispose();
    _versionSearchFocus.dispose();
    super.dispose();
  }

  void _leaveTextField() => FocusManager.instance.primaryFocus?.unfocus();

  bool get _typing {
    // The focused node belongs to a Focus widget inside the EditableText.
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Future<void> _editChannels() async {
    final channels = await showChannelDialog(context, state.channels);
    _leaveTextField();
    if (channels != null && channels.isNotEmpty) {
      _packageSearch.clear();
      state.packageQuery = '';
      await state.setChannels(channels);
    }
  }

  Future<void> _editPlatforms() async {
    if (state.availablePlatforms.isEmpty) return;
    final platforms = await showPlatformDialog(
      context,
      available: state.availablePlatforms,
      selected: state.selectedPlatforms,
    );
    _leaveTextField();
    if (platforms != null && platforms.isNotEmpty) {
      await state.setPlatforms(platforms);
    }
  }

  Future<void> _refresh() async {
    showKitToast(context, 'Refreshing ${state.channels.join(', ')}…');
    await state.refresh();
  }

  void _activate() {
    switch (state.focusedPane) {
      case Pane.packages:
        if (state.packages.isNotEmpty) {
          state.openPackage(state.packages[state.packageIndex]);
        }
      case Pane.versions:
        state.activateVersionRow(state.versionIndex);
      case Pane.details:
        break;
    }
  }

  void _focusSearch() {
    if (state.focusedPane == Pane.packages || state.selectedPackage == null) {
      state.focusPane(Pane.packages);
      _packageSearchFocus.requestFocus();
    } else {
      state.focusPane(Pane.versions);
      _versionSearchFocus.requestFocus();
    }
  }

  void _movePane(int delta) {
    final panes = [
      Pane.packages,
      if (state.selectedPackage != null) Pane.versions,
      if (state.selectedRecord != null) Pane.details,
    ];
    final index = panes.indexOf(state.focusedPane);
    final next = (index + delta).clamp(0, panes.length - 1);
    state.focusPane(panes[next]);
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // Leave keys to dialogs while one is open.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final key = event.logicalKey;
    if (_typing) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        final versions = _versionSearchFocus.hasFocus;
        if (key == LogicalKeyboardKey.escape) {
          _leaveTextField();
        } else {
          state.moveSelection(
            versions ? Pane.versions : Pane.packages,
            key == LogicalKeyboardKey.arrowDown ? 1 : -1,
          );
        }
        return true;
      }
      return false;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      if (HardwareKeyboard.instance.isControlPressed) {
        if (key == LogicalKeyboardKey.keyD) {
          state.moveSelection(state.focusedPane, 20);
          return true;
        }
        if (key == LogicalKeyboardKey.keyU) {
          state.moveSelection(state.focusedPane, -20);
          return true;
        }
      }
      return false;
    }
    final char = event.character;
    final wasG = _pendingG;
    _pendingG = false;
    if (key == LogicalKeyboardKey.arrowDown || char == 'j') {
      state.moveSelection(state.focusedPane, 1);
    } else if (key == LogicalKeyboardKey.arrowUp || char == 'k') {
      state.moveSelection(state.focusedPane, -1);
    } else if (key == LogicalKeyboardKey.pageDown) {
      state.moveSelection(state.focusedPane, 20);
    } else if (key == LogicalKeyboardKey.pageUp) {
      state.moveSelection(state.focusedPane, -20);
    } else if (key == LogicalKeyboardKey.arrowLeft || char == 'h') {
      _movePane(-1);
    } else if (key == LogicalKeyboardKey.arrowRight || char == 'l') {
      _movePane(1);
    } else if (char == 'G' || key == LogicalKeyboardKey.end) {
      state.jumpSelection(state.focusedPane, toEnd: true);
    } else if (key == LogicalKeyboardKey.home) {
      state.jumpSelection(state.focusedPane, toEnd: false);
    } else if (char == 'g') {
      if (wasG) {
        state.jumpSelection(state.focusedPane, toEnd: false);
      } else {
        _pendingG = true;
      }
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activate();
    } else if (key == LogicalKeyboardKey.escape) {
      state.back();
    } else if (char == '/') {
      _focusSearch();
    } else if (char == 'c') {
      _editChannels();
    } else if (char == 'p') {
      _editPlatforms();
    } else if (char == '?') {
      showHelpDialog(context);
    } else if (char == 'd' && state.selectedRecord != null) {
      downloadRecord(context, state.selectedRecord!);
    } else if (char == 'y' && state.selectedPackage != null) {
      copyAsJson(context, state);
    } else if (char == 'r') {
      _refresh();
    } else if (char == 's') {
      state.setSearchSummaries(!state.searchSummaries);
    } else if (char != null &&
        state.selectedRecord != null &&
        RegExp(r'^[1-5]$').hasMatch(char)) {
      state.toggleSection(DetailSection.values[int.parse(char) - 1]);
    } else {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final busy = state.loadingChannels ||
        state.loadingRecords ||
        state.loadingContents ||
        state.loadingChannelData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          state: state,
          onChannels: _editChannels,
          onPlatforms: _editPlatforms,
          onRefresh: _refresh,
        ),
        // A static bar rather than a looping spinner.
        SizedBox(height: 2, child: busy ? ColoredBox(color: c.accent) : null),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 1000
                ? _wideLayout()
                : _narrowLayout(),
          ),
        ),
        _StatusBar(state: state),
      ],
    );
  }

  Widget _packagesPane() => PackagesPane(
        state: state,
        searchController: _packageSearch,
        searchFocus: _packageSearchFocus,
      );

  Widget _versionsPane({bool showBack = false}) => VersionsPane(
        state: state,
        searchController: _versionSearch,
        searchFocus: _versionSearchFocus,
        showBack: showBack,
      );

  Widget _wideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 360, child: _packagesPane()),
        const KitVerticalDivider(),
        SizedBox(width: 360, child: _versionsPane()),
        const KitVerticalDivider(),
        Expanded(child: DetailsPane(state: state)),
      ],
    );
  }

  /// One pane at a time, swapped instantly.
  Widget _narrowLayout() {
    if (state.selectedRecord != null) {
      return DetailsPane(state: state, showBack: true);
    }
    if (state.selectedPackage != null) return _versionsPane(showBack: true);
    return _packagesPane();
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.state,
    required this.onChannels,
    required this.onPlatforms,
    required this.onRefresh,
  });

  final BrowserState state;
  final VoidCallback onChannels;
  final VoidCallback onPlatforms;
  final VoidCallback onRefresh;

  String get _platformLabel {
    if (state.availablePlatforms.isEmpty) return 'Platforms';
    if (state.selectedPlatforms.length == state.availablePlatforms.length) {
      return 'All platforms';
    }
    return state.selectedPlatforms.length <= 2
        ? state.selectedPlatforms.join(', ')
        : '${state.selectedPlatforms.length} platforms';
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text('pixibrowse', style: mono(context, size: 16, weight: FontWeight.bold)),
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: KitButton.ghost(
              state.channels.join(', '),
              icon: Icons.hub_outlined,
              tooltip: 'Channels  ( c )',
              onPressed: onChannels,
            ),
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: KitButton.ghost(
              _platformLabel,
              icon: Icons.memory,
              tooltip: 'Platforms  ( p )',
              onPressed: onPlatforms,
            ),
          ),
          const SizedBox(width: 4),
          KitIconButton(
            Icons.refresh,
            tooltip: 'Refresh, skipping the cache  ( r )',
            onPressed: state.loadingChannels ? null : onRefresh,
          ),
          KitIconButton(
            Icons.keyboard_outlined,
            tooltip: 'Keyboard shortcuts  ( ? )',
            onPressed: () => showHelpDialog(context),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});
  final BrowserState state;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final summaries = state.loadingChannelData
        ? ' · loading summaries…'
        : state.channelInfo.isEmpty
            ? ''
            : ' · ${state.channelInfo.length} summaries';
    final text = state.status ??
        (state.error != null
            ? 'Error'
            : '${state.totalPackages} packages · '
                '${state.selectedPlatforms.length} platform'
                '${state.selectedPlatforms.length == 1 ? '' : 's'} · '
                '${state.channels.join(', ')}$summaries');
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: KitText.small(context),
            ),
          ),
          Flexible(
            child: Text(
              '/ search · j/k move · Enter open · Esc back · r refresh · ? help',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: dim(context),
            ),
          ),
        ],
      ),
    );
  }
}
