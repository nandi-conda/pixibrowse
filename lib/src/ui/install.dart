import 'dart:async';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons, SelectableText;
import 'package:flutter/widgets.dart';

import '../conda/repodata.dart';
import '../conda/version.dart';
import '../install/pixi_runner.dart';
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

String _spec(String name, String? version) =>
    version == null ? name : '$name==$version';

/// The arguments to `pixi` that install [name] globally.
List<String> globalInstallArgs(
  String name, {
  String? channel,
  String? version,
}) {
  final c = installChannel(channel);
  return [
    'global',
    'install',
    if (c != null) ...['-c', c],
    _spec(name, version),
  ];
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
  final spec = _spec(name, version);
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
      ['pixi', ...globalInstallArgs(name, channel: channel, version: version)]
          .join(' '),
    ),
  ];
}

/// The packages installed with `pixi global`, shared by every view and
/// read once, then again after each install from the app.
class InstalledPackages extends ValueNotifier<Map<String, GlobalPackage>?> {
  InstalledPackages() : super(null);

  /// Tests replace it.
  static InstalledPackages instance = InstalledPackages();

  bool _requested = false;

  /// Reads the list unless it already was.
  void ensureLoaded() {
    if (_requested) return;
    refresh();
  }

  Future<void> refresh() async {
    _requested = true;
    final runner = PixiRunner.instance;
    if (runner == null) return;
    try {
      value = await runner.globalPackages();
    } catch (_) {
      value = null;
    }
  }
}

/// What the run button does for an installed (or missing) package.
class GlobalStatus {
  const GlobalStatus(this.label, this.kind, this.action, this.args);

  final String label;
  final GlobalStatusKind kind;

  /// The run button's verb, e.g. "Install" or "Update to 2.0".
  final String action;
  final List<String> args;

  /// Compares what is installed with [version] (the selected artifact) or,
  /// without one, the [latest] version the channel serves.
  factory GlobalStatus.of(
    String name, {
    required GlobalPackage? installed,
    String? channel,
    String? version,
    String? latest,
  }) {
    List<String> install(String? v, {bool force = false}) => [
      ...globalInstallArgs(name, channel: channel, version: v),
      if (force) '--force-reinstall',
    ];
    if (installed == null) {
      return GlobalStatus(
        'Not installed',
        GlobalStatusKind.missing,
        'Install',
        install(version),
      );
    }
    final have = installed.version;
    final want = version ?? latest;
    final label = 'Installed $have';
    if (want == null || want == have) {
      return GlobalStatus(
        label,
        GlobalStatusKind.current,
        'Reinstall',
        install(version, force: true),
      );
    }
    final newer =
        CondaVersion.parse(want).compareTo(CondaVersion.parse(have)) > 0;
    if (version == null && newer) {
      return GlobalStatus(
        'Update available: $have → $want',
        GlobalStatusKind.outdated,
        'Update to $want',
        install(null),
      );
    }
    return GlobalStatus(
      label,
      GlobalStatusKind.other,
      'Install $want instead',
      install(want),
    );
  }
}

enum GlobalStatusKind { missing, current, outdated, other }

/// The install commands, one per line in monospace, each with a copy button.
/// On desktop it also says whether the package is installed globally, and
/// the global install can be run from here.
class InstallCommands extends StatefulWidget {
  const InstallCommands(
    this.name, {
    super.key,
    this.channel,
    this.version,
    this.latest,
  });

  final String name;
  final String? channel;

  /// The selected artifact's version, which the commands pin.
  final String? version;

  /// The newest version the channel serves, for spotting updates.
  final String? latest;

  @override
  State<InstallCommands> createState() => _InstallCommandsState();
}

class _InstallCommandsState extends State<InstallCommands> {
  @override
  void initState() {
    super.initState();
    if (PixiRunner.instance != null) InstalledPackages.instance.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final runner = PixiRunner.instance;
    final name = widget.name;
    final commands = installCommands(
      name,
      channel: widget.channel,
      version: widget.version,
    );
    Widget line(String command, List<Widget> buttons) => Row(
      children: [
        Expanded(
          child: Text(
            command,
            style: mono(context),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ...buttons,
      ],
    );
    Widget copy(String label, String command) => KitIconButton.compact(
      Icons.content_copy,
      tooltip: 'Copy $label command',
      onPressed: () => copyText(context, command, 'Copied $command'),
    );
    if (runner == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, command) in commands)
            line(command, [copy(label, command)]),
        ],
      );
    }
    return ValueListenableBuilder(
      valueListenable: InstalledPackages.instance,
      builder: (context, installed, _) {
        final status = installed == null
            ? null
            : GlobalStatus.of(
                name,
                installed: installed[name],
                channel: widget.channel,
                version: widget.version,
                latest: widget.latest,
              );
        final args =
            status?.args ??
            globalInstallArgs(
              name,
              channel: widget.channel,
              version: widget.version,
            );
        final action = status?.action ?? 'Install';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, command) in commands)
              line(command, [
                if (label == 'pixi global install')
                  KitIconButton.compact(
                    switch (status?.kind) {
                      GlobalStatusKind.current => Icons.refresh,
                      GlobalStatusKind.outdated => Icons.upgrade,
                      _ => Icons.play_arrow,
                    },
                    tooltip: '$action: pixi ${args.join(' ')}',
                    onPressed: () => showGlobalInstall(
                      context,
                      runner,
                      name: name,
                      args: args,
                    ),
                  ),
                copy(label, command),
              ]),
            if (status != null) _StatusBadge(status),
          ],
        );
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);
  final GlobalStatus status;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final color = switch (status.kind) {
      GlobalStatusKind.current => c.success,
      GlobalStatusKind.outdated => c.accent,
      GlobalStatusKind.other => c.text,
      GlobalStatusKind.missing => c.textDim,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            'pixi global: ${status.label}',
            style: KitText.small(context, color: color),
          ),
        ],
      ),
    );
  }
}

/// Runs `pixi [args]` in a dialog showing its output, then says in a toast
/// whether [name] installed.
Future<void> showGlobalInstall(
  BuildContext context,
  PixiRunner runner, {
  required String name,
  required List<String> args,
}) async {
  final ok = await showKitDialog<bool>(
    context,
    (_) => _InstallDialog(runner: runner, name: name, args: args),
  );
  unawaited(InstalledPackages.instance.refresh());
  if (!context.mounted || ok == null) return;
  showKitToast(
    context,
    ok ? 'Installed $name with pixi global' : 'Could not install $name',
  );
}

class _InstallDialog extends StatefulWidget {
  const _InstallDialog({
    required this.runner,
    required this.name,
    required this.args,
  });

  final PixiRunner runner;
  final String name;
  final List<String> args;

  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  final _lines = <String>[];
  final _scroll = ScrollController();
  PixiRun? _run;
  StreamSubscription<String>? _output;

  /// `null` while running, then whether pixi succeeded.
  bool? _ok;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final run = await widget.runner.start(widget.args);
      if (!mounted) return run.kill();
      _run = run;
      _output = run.output.listen((line) {
        setState(() => _lines.add(line));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      });
      final code = await run.exitCode;
      if (!mounted) return;
      setState(() {
        _ok = code == 0;
        if (code != 0) _error = 'pixi exited with code $code.';
      });
    } on PixiNotFound {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _error =
            'pixi was not found on PATH or in ~/.pixi/bin. '
            'Install it from https://pixi.sh and try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _error = 'Could not run pixi: $e';
      });
    }
  }

  @override
  void dispose() {
    if (_ok == null) _run?.kill();
    _output?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final running = _ok == null;
    return KitDialog(
      title: 'Install ${widget.name}',
      width: 620,
      actions: [
        if (running)
          KitButton('Cancel', onPressed: () => Navigator.of(context).pop())
        else
          KitButton.primary(
            'Close',
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(_ok),
          ),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (running) ...[
                const KitSpinner(size: 14),
                const SizedBox(width: 8),
              ] else ...[
                Icon(
                  _ok! ? Icons.check_circle : Icons.error,
                  size: 16,
                  color: _ok! ? c.success : c.danger,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  ['pixi', ...widget.args].join(' '),
                  style: mono(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: KitText.body(context).copyWith(color: c.danger)),
          ],
          const SizedBox(height: 8),
          Container(
            height: 260,
            decoration: BoxDecoration(
              color: c.background,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(kitRadius),
            ),
            child: _lines.isEmpty
                ? Center(
                    child: Text(
                      running ? 'Waiting for pixi…' : 'No output.',
                      style: dim(context),
                    ),
                  )
                : SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      _lines.join('\n'),
                      style: mono(context),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
