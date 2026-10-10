import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons, SelectableText;
import 'package:flutter/widgets.dart';

import '../search.dart';
import '../state.dart';
import 'theme.dart';

/// Taps on a row hand the keyboard back to list navigation.
VoidCallback _unfocusThen(VoidCallback action) => () {
      FocusManager.instance.primaryFocus?.unfocus();
      action();
    };

class PaneHeader extends StatelessWidget {
  const PaneHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing = const [],
    this.active = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> trailing;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: active ? c.accent : c.border,
            width: active ? 2 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          ?leading,
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(context, size: 14, weight: FontWeight.bold),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dim(context),
                  ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: KitTextField(
        controller: controller,
        focusNode: focusNode,
        hint: hint,
        prefixIcon: Icons.search,
        style: mono(context),
        trailing: ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : KitIconButton.compact(
                  Icons.clear,
                  tooltip: 'Clear',
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                    focusNode.requestFocus();
                  },
                ),
        ),
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted?.call(),
      ),
    );
  }
}

class CenteredMessage extends StatelessWidget {
  const CenteredMessage(this.message, {super.key, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SelectableText(
          message,
          textAlign: TextAlign.center,
          style: KitText.body(context)
              .copyWith(color: error ? c.danger : c.textDim),
        ),
      ),
    );
  }
}

/// A small label after a search hit that matched outside the name.
class _MatchBadge extends StatelessWidget {
  const _MatchBadge(this.kind, {required this.strong});
  final MatchKind kind;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final color = strong ? c.onAccent : c.accent;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        kind == MatchKind.summary ? 'summary' : 'description',
        style: KitText.small(context, color: color).copyWith(fontSize: 10),
      ),
    );
  }
}

class PackagesPane extends StatelessWidget {
  const PackagesPane({
    super.key,
    required this.state,
    required this.searchController,
    required this.searchFocus,
  });

  final BrowserState state;
  final TextEditingController searchController;
  final FocusNode searchFocus;

  @override
  Widget build(BuildContext context) {
    final active = state.focusedPane == Pane.packages;
    final c = KitTheme.of(context);
    Widget body;
    if (state.error != null) {
      body = CenteredMessage(state.error!, error: true);
    } else if (state.loadingChannels && state.totalPackages == 0) {
      body = CenteredMessage(state.status ?? 'Loading…');
    } else if (state.packages.isEmpty) {
      body = CenteredMessage(
        state.packageQuery.isEmpty
            ? 'No packages.'
            : 'No package matches "${state.packageQuery}".',
      );
    } else {
      body = KitSelectionList(
        itemCount: state.packages.length,
        selectedIndex: state.packageIndex,
        itemBuilder: (context, index, selected) {
          final name = state.packages[index];
          final open = name == state.selectedPackage;
          final strong = selected && active;
          final summary = state.infoFor(name)?.summary;
          final match = state.packageMatches[name];
          return KitListRow(
            selected: selected,
            active: active,
            onTap: _unfocusThen(() {
              state.focusPane(Pane.packages);
              state.openPackage(name);
            }),
            child: Row(
              children: [
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(
                        context,
                        color: strong ? c.onAccent : c.text,
                        weight: open ? FontWeight.bold : null,
                      ),
                    ),
                  ),
                ),
                if (match != null) _MatchBadge(match, strong: strong),
                const SizedBox(width: 10),
                Expanded(
                  child: summary == null
                      ? const SizedBox.shrink()
                      : Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: KitText.small(context,
                              color: strong ? c.onAccent : c.textDim),
                        ),
                ),
                if (open)
                  Icon(Icons.chevron_right,
                      size: 16, color: strong ? c.onAccent : c.accent),
              ],
            ),
          );
        },
      );
    }
    final showSummaryToggle =
        state.channelInfo.isNotEmpty || state.loadingChannelData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          title: 'Packages',
          subtitle: state.totalPackages == 0
              ? null
              : state.packageQuery.isEmpty
                  ? '${state.totalPackages} packages'
                  : '${state.packages.length} of ${state.totalPackages}',
          active: active,
          trailing: [
            if (showSummaryToggle)
              KitTooltip(
                message: state.loadingChannelData
                    ? 'Loading summaries from channeldata.json…'
                    : 'Also match package summaries and descriptions',
                child: KitCheckbox(
                  value: state.searchSummaries,
                  label: 'Summaries',
                  onChanged: state.loadingChannelData
                      ? null
                      : state.setSearchSummaries,
                ),
              ),
            const SizedBox(width: 4),
          ],
        ),
        SearchField(
          controller: searchController,
          focusNode: searchFocus,
          hint: 'Search packages  ( / )',
          onChanged: state.setPackageQuery,
          onSubmitted: () {
            if (state.packages.isNotEmpty) {
              searchFocus.unfocus();
              state.openPackage(state.packages[state.packageIndex]);
            }
          },
        ),
        Expanded(child: body),
      ],
    );
  }
}

class VersionsPane extends StatelessWidget {
  const VersionsPane({
    super.key,
    required this.state,
    required this.searchController,
    required this.searchFocus,
    this.showBack = false,
  });

  final BrowserState state;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final active = state.focusedPane == Pane.versions;
    final c = KitTheme.of(context);
    final name = state.selectedPackage;
    if (name == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(title: 'Versions', active: active),
          const Expanded(
            child: CenteredMessage('Select a package to see its versions.'),
          ),
        ],
      );
    }
    Widget body;
    if (state.recordsError != null) {
      body = CenteredMessage(state.recordsError!, error: true);
    } else if (state.loadingRecords) {
      body = const CenteredMessage('Loading versions…');
    } else if (state.versionRows.isEmpty) {
      body = CenteredMessage(state.versionQuery.isEmpty
          ? 'No artifacts on the selected platforms.'
          : 'No artifact matches "${state.versionQuery}".');
    } else {
      final versionWidth = state.records
          .fold<int>(0, (w, r) => r.version.length > w ? r.version.length : w);
      body = KitSelectionList(
        itemCount: state.versionRows.length,
        selectedIndex: state.versionIndex,
        itemBuilder: (context, index, selected) {
          final row = state.versionRows[index];
          final strong = selected && active;
          final tap = _unfocusThen(() {
            state.focusPane(Pane.versions);
            state.activateVersionRow(index);
          });
          if (row.isSection) {
            final collapsed = state.collapsedSubdirs.contains(row.subdir);
            return KitListRow(
              selected: selected,
              active: active,
              onTap: tap,
              child: Text(
                '${collapsed ? '▸' : '▾'} ${row.subdir} (${row.count})',
                style: mono(
                  context,
                  weight: FontWeight.bold,
                  color: strong ? c.onAccent : c.accent,
                ),
              ),
            );
          }
          final record = row.record!;
          final open = identical(record, state.selectedRecord);
          return KitListRow(
            selected: selected,
            active: active,
            onTap: tap,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text(
                  record.version.padRight(versionWidth),
                  style: mono(
                    context,
                    color: strong ? c.onAccent : c.text,
                    weight: open ? FontWeight.bold : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    record.build,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(
                      context,
                      color: strong ? c.onAccent : c.textDim,
                      weight: open ? FontWeight.bold : null,
                    ),
                  ),
                ),
                if (state.channels.length > 1)
                  Text(
                    record.channel,
                    style: KitText.small(context,
                        color: strong ? c.onAccent : c.textDim),
                  ),
              ],
            ),
          );
        },
      );
    }
    final summary = state.infoFor(name)?.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          title: name,
          subtitle: state.loadingRecords
              ? 'Loading…'
              : '${state.records.length} artifact${state.records.length == 1 ? '' : 's'}'
                  '${summary == null ? '' : ' · $summary'}',
          active: active,
          leading: showBack
              ? KitIconButton(
                  Icons.arrow_back,
                  tooltip: 'Back',
                  onPressed: state.back,
                )
              : null,
        ),
        SearchField(
          controller: searchController,
          focusNode: searchFocus,
          hint: 'Filter versions and builds',
          onChanged: state.setVersionQuery,
          onSubmitted: () {
            searchFocus.unfocus();
            state.activateVersionRow(state.versionIndex);
          },
        ),
        Expanded(child: body),
      ],
    );
  }
}
