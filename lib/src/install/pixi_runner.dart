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

  /// The desktop runner, or `null` on the web where nothing can run.
  /// Tests replace it.
  static PixiRunner? instance = platform.pixiRunner();
}

final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// Splits terminal output into lines, treating carriage returns (progress
/// bars redrawing themselves) as line ends and dropping colour codes.
List<String> terminalLines(String chunk) => [
  for (final line in chunk.replaceAll(_ansi, '').split(RegExp(r'\r\n|\r|\n')))
    if (line.trim().isNotEmpty) line.trimRight(),
];
