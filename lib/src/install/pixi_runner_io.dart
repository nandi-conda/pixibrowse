import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pixi_runner.dart';

PixiRunner? pixiRunner() => _ProcessPixiRunner();

class _ProcessPixiRunner implements PixiRunner {
  @override
  Future<PixiRun> start(List<String> args) async {
    final env = {'NO_COLOR': '1', 'CLICOLOR': '0'};
    Process? process;
    for (final pixi in _candidates()) {
      try {
        process = await Process.start(pixi, args, environment: env);
        break;
      } on ProcessException {
        continue;
      }
    }
    if (process == null) throw PixiNotFound();
    final lines = StreamController<String>();
    var open = 2;
    void listen(Stream<List<int>> s) => s
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (chunk) => terminalLines(chunk).forEach(lines.add),
          onDone: () {
            if (--open == 0) lines.close();
          },
        );
    listen(process.stdout);
    listen(process.stderr);
    final started = process;
    return PixiRun(
      output: lines.stream,
      exitCode: started.exitCode,
      kill: () => started.kill(),
    );
  }

  /// `pixi` from PATH, then the installer's default location, which a
  /// desktop launcher's PATH often lacks.
  Iterable<String> _candidates() sync* {
    yield 'pixi';
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return;
    final sep = Platform.pathSeparator;
    final exe = Platform.isWindows ? 'pixi.exe' : 'pixi';
    final path = '$home$sep.pixi${sep}bin$sep$exe';
    if (File(path).existsSync()) yield path;
  }
}
