import 'dart:convert';

import 'pixi_runner_stub.dart'
    if (dart.library.io) 'pixi_runner_io.dart' as platform;

/// A running pixi command.
class PixiRun {
  PixiRun({required this.output, required this.exitCode, required this.kill});

  /// stdout and stderr, one line at a time, without terminal escapes.
  final Stream<String> output;
  final Future<int> exitCode;
  final void Function() kill;
}

/// pixi is neither on `PATH` nor in `~/.pixi/bin`.
class PixiNotFound implements Exception {
  @override
  String toString() => 'pixi is not on PATH';
}

/// Runs pixi on this machine.
abstract class PixiRunner {
  /// Starts `pixi` with [args]; throws [PixiNotFound] when there is no pixi.
  Future<PixiRun> start(List<String> args);

  /// What `pixi global list --json` reports, keyed by package name, or
  /// `null` when pixi is missing or too old to list as JSON.
  Future<Map<String, GlobalPackage>?> globalPackages();

  /// The desktop runner, or `null` on the web where nothing can run.
  /// Tests replace it.
  static PixiRunner? instance = platform.pixiRunner();
}

/// A package installed explicitly into one of pixi's global environments.
class GlobalPackage {
  const GlobalPackage(this.name, this.version, this.environment);
  final String name;
  final String version;
  final String environment;
}

/// Reads `pixi global list --json`. A package in an environment named after
/// it wins over the same package in another environment.
Map<String, GlobalPackage> parseGlobalList(String json) {
  final result = <String, GlobalPackage>{};
  final decoded = jsonDecode(json);
  if (decoded is! List) return result;
  for (final env in decoded) {
    if (env is! Map) continue;
    final envName = env['name'];
    final deps = env['dependencies'];
    if (envName is! String || deps is! List) continue;
    for (final dep in deps) {
      if (dep is! Map) continue;
      final name = dep['name'];
      final version = dep['version'];
      if (name is! String || version is! String) continue;
      if (result[name]?.environment == name) continue;
      result[name] = GlobalPackage(name, version, envName);
    }
  }
  return result;
}

final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// Splits terminal output into lines, treating carriage returns (progress
/// bars redrawing themselves) as line ends and dropping colour codes.
List<String> terminalLines(String chunk) => [
  for (final line in chunk.replaceAll(_ansi, '').split(RegExp(r'\r\n|\r|\n')))
    if (line.trim().isNotEmpty) line.trimRight(),
];
