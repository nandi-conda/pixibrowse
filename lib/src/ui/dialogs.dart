import 'dart:convert';
import 'dart:typed_data';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons, SelectableText;
import 'package:flutter/widgets.dart';

import '../conda/repodata.dart';
import 'theme.dart';

/// Edits the list of channels being browsed. Returns the new list, or
/// `null` when cancelled.
Future<List<String>?> showChannelDialog(
  BuildContext context,
  List<String> channels,
) {
  return showKitDialog<List<String>>(
    context,
    (context) => _ChannelDialog(initial: channels),
  );
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog({required this.initial});
  final List<String> initial;

  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  late final List<String> _channels = [...widget.initial];
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      if (!_channels.contains(text)) _channels.add(text);
      _controller.clear();
    });
  }

  void _apply() {
    Navigator.of(context)
        .pop(normalizeChannels([..._channels, _controller.text]));
  }

  @override
  Widget build(BuildContext context) {
    return KitDialog(
      title: 'Channels',
      width: 500,
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        KitButton.primary('Apply', onPressed: _apply),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The package list and searches run against all of these.',
            style: dim(context),
          ),
          const SizedBox(height: 8),
          for (final channel in _channels)
            KitListRow(
              height: 44,
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(channel, style: mono(context)),
                        Text(channelUrl(channel), style: dim(context)),
                      ],
                    ),
                  ),
                  KitIconButton.compact(
                    Icons.close,
                    tooltip: _channels.length == 1
                        ? 'The last channel cannot be removed'
                        : 'Remove $channel',
                    onPressed: _channels.length == 1
                        ? null
                        : () => setState(() => _channels.remove(channel)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          KitTextField(
            controller: _controller,
            autofocus: true,
            style: mono(context),
            hint: 'Channel name or URL, e.g. bioconda',
            prefixIcon: Icons.add,
            onSubmitted: (_) => _add(),
          ),
        ],
      ),
    );
  }
}

/// Picks which platforms to browse. Returns the selection, or `null`.
Future<List<String>?> showPlatformDialog(
  BuildContext context, {
  required List<String> available,
  required List<String> selected,
}) {
  return showKitDialog<List<String>>(
    context,
    (context) => _PlatformDialog(available: available, initial: selected),
  );
}

class _PlatformDialog extends StatefulWidget {
  const _PlatformDialog({required this.available, required this.initial});
  final List<String> available;
  final List<String> initial;

  @override
  State<_PlatformDialog> createState() => _PlatformDialogState();
}

class _PlatformDialogState extends State<_PlatformDialog> {
  late final Set<String> _selected = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final allSelected = _selected.length == widget.available.length;
    return KitDialog(
      title: 'Platforms',
      width: 340,
      actions: [
        KitButton.ghost(
          allSelected ? 'Select none' : 'Select all',
          onPressed: () => setState(() {
            if (allSelected) {
              _selected.clear();
            } else {
              _selected.addAll(widget.available);
            }
          }),
        ),
        KitButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        KitButton.primary(
          'Apply',
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
        ),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final platform in widget.available)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: KitCheckbox(
                value: _selected.contains(platform),
                labelWidget: Text(platform, style: mono(context)),
                onChanged: (_) => setState(() {
                  if (!_selected.remove(platform)) _selected.add(platform);
                }),
              ),
            ),
        ],
      ),
    );
  }
}

const List<(String, String)> keybindings = [
  ('j / k', 'Move selection down / up'),
  ('h / l', 'Focus left / right pane'),
  ('g / G', 'Jump to top / bottom'),
  ('Ctrl+u / d', 'Page up / down'),
  ('Enter', 'Open / select'),
  ('Esc', 'Back, or leave the search field'),
  ('/', 'Search packages or versions'),
  ('s', 'Toggle searching summaries'),
  ('a', 'Toggle searching all channels on prefix.dev'),
  ('c', 'Select channels'),
  ('p', 'Select platforms'),
  ('r', 'Refresh channel data, skipping the cache'),
  ('d', 'Download the selected artifact'),
  ('y', 'Copy the package or artifact as JSON'),
  ('1 – 5', 'Fold or unfold a detail section'),
  ('?', 'Show this help'),
];

void showHelpDialog(BuildContext context) {
  showKitDialog<void>(
    context,
    (context) => KitDialog(
      title: 'Keyboard shortcuts',
      actions: [
        KitButton(
          'Close',
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (key, action) in keybindings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      key,
                      style: mono(context, weight: FontWeight.bold),
                    ),
                  ),
                  Expanded(child: Text(action)),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// Shows one file from an artifact's `info/` section.
void showInfoFileDialog(BuildContext context, String path, Uint8List bytes) {
  String text;
  final isBinary = bytes.take(4096).contains(0);
  if (isBinary) {
    text = 'Binary file, ${bytes.length} bytes.';
  } else {
    text = utf8.decode(bytes, allowMalformed: true);
    if (path.endsWith('.json')) {
      try {
        text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      } on FormatException {
        // Keep the text as it is.
      }
    }
  }
  showKitDialog<void>(
    context,
    (context) => KitDialog(
      title: path,
      width: 880,
      actions: [
        KitButton(
          'Close',
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      content: SelectableText(text, style: mono(context, size: 12)),
    ),
  );
}
