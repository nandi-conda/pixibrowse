import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pixi_runner.dart';

PixiRunner? pixiRunner() => _ProcessPixiRunner();

const _env = {'NO_COLOR': '1', 'CLICOLOR': '0'};

class _ProcessPixiRunner implements PixiRunner {
  @override
  Future<PixiRun> start(List<String> args) async {
    Process? process;
    for (final pixi in _candidates()) {
      try {
        process = await Process.start(pixi, args, environment: _env);
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

  @override
  Future<Map<String, GlobalPackage>?> globalPackages() async {
    for (final pixi in _candidates()) {
      try {
        final result = await Process.run(
          pixi,
          ['global', 'list', '--json'],
          environment: _env,
        );
        if (result.exitCode != 0) return null;
        return parseGlobalList(result.stdout as String);
      } on ProcessException {
        continue;
      } on FormatException {
        return null;
      }
    }
    return null;
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
