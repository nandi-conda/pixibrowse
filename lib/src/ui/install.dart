import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../conda/repodata.dart';
import 'details.dart';
import 'theme.dart';

const _condaForge = {
  'https://conda.anaconda.org/conda-forge',
  'https://prefix.dev/conda-forge',
  'https://repo.prefix.dev/conda-forge',
};

/// What to pass to pixi's `-c` for [channel], or `null` when it is
/// conda-forge, which pixi uses when no channel is given.
String? installChannel(String? channel) {
  if (channel == null || channel.trim().isEmpty) return null;
  final url = channelUrl(channel);
  if (_condaForge.contains(url)) return null;
  final trimmed = channel.trim();
  return trimmed.startsWith('http://') || trimmed.startsWith('https://')
      ? url
      : trimmed;
}

/// Ready-to-run commands that add [name] to a pixi workspace and install it
/// globally, pinned to [version] when one is given.
///
/// `pixi add` has no `-c`, so a channel other than conda-forge is added to
/// the workspace first.
List<(String, String)> installCommands(
  String name, {
  String? channel,
  String? version,
}) {
  final spec = version == null ? name : '$name==$version';
  final c = installChannel(channel);
  return [
    (
      'pixi add',
      c == null
          ? 'pixi add $spec'
          : 'pixi workspace channel add $c && pixi add $spec',
    ),
    (
      'pixi global install',
      c == null
          ? 'pixi global install $spec'
          : 'pixi global install -c $c $spec',
    ),
  ];
}

/// The install commands, one per line in monospace, each with a copy button.
class InstallCommands extends StatelessWidget {
  const InstallCommands(
    this.name, {
    super.key,
    this.channel,
    this.version,
  });

  final String name;
  final String? channel;
  final String? version;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, command) in installCommands(
          name,
          channel: channel,
          version: version,
        ))
          Row(
            children: [
              Expanded(
                child: Text(
                  command,
                  style: mono(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              KitIconButton.compact(
                Icons.content_copy,
                tooltip: 'Copy $label command',
                onPressed: () => copyText(context, command, 'Copied $command'),
              ),
            ],
          ),
      ],
    );
  }
}
