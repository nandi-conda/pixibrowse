import 'dart:async';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixibrowse/src/install/pixi_runner.dart';
import 'package:pixibrowse/src/ui/install.dart';

class FakeRunner implements PixiRunner {
  FakeRunner({this.found = true, this.installed = const {}});
  final bool found;
  Map<String, GlobalPackage> installed;
  int lists = 0;
  final args = <List<String>>[];
  final output = StreamController<String>();
  final exit = Completer<int>();
  bool killed = false;

  @override
  Future<Map<String, GlobalPackage>?> globalPackages() async {
    lists++;
    return found ? installed : null;
  }

  @override
  Future<PixiRun> start(List<String> args) async {
    this.args.add(args);
    if (!found) throw PixiNotFound();
    return PixiRun(
      output: output.stream,
      exitCode: exit.future,
      kill: () => killed = true,
    );
  }
}

Future<void> pumpCommands(WidgetTester tester, PixiRunner? runner) async {
  PixiRunner.instance = runner;
  InstalledPackages.instance = InstalledPackages();
  await tester.pumpWidget(MaterialApp(
    theme: KitTheme.material(KitColors.light),
    home: const Material(
      child: InstallCommands(
        'zumba',
        channel: 'https://prefix.dev/nandi-testing',
        version: '1.0.0',
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  final original = PixiRunner.instance;
  tearDown(() => PixiRunner.instance = original);

  test('conda-forge needs no channel', () {
    for (final c in [
      null,
      'conda-forge',
      'https://conda.anaconda.org/conda-forge/',
      'https://prefix.dev/conda-forge',
    ]) {
      expect(installCommands('numpy', channel: c), [
        ('pixi add', 'pixi add numpy'),
        ('pixi global install', 'pixi global install numpy'),
      ]);
    }
  });

  test('other channels are named, and versions pinned', () {
    expect(
      installCommands(
        'zumba',
        channel: 'https://prefix.dev/nandi-testing/',
        version: '1.0.0',
      ),
      [
        (
          'pixi add',
          'pixi workspace channel add https://prefix.dev/nandi-testing '
              '&& pixi add zumba==1.0.0',
        ),
        (
          'pixi global install',
          'pixi global install -c https://prefix.dev/nandi-testing '
              'zumba==1.0.0',
        ),
      ],
    );
    expect(
      installCommands('samtools', channel: 'bioconda').last.$2,
      'pixi global install -c bioconda samtools',
    );
  });

  test('reads pixi global list, preferring the eponymous environment', () {
    final packages = parseGlobalList('''[
      {"name": "tools", "dependencies": [{"name": "jq", "version": "1.7"}]},
      {"name": "jq", "dependencies": [{"name": "jq", "version": "1.8.2"}],
       "exposed": [{"exposed_name": "jq", "executable": "jq"}]},
      {"name": "broken"}
    ]''');
    expect(packages.keys, ['jq']);
    expect(packages['jq']!.version, '1.8.2');
    expect(packages['jq']!.environment, 'jq');
  });

  test('status compares the installed version', () {
    GlobalStatus of(String? have, {String? version, String? latest}) =>
        GlobalStatus.of(
          'jq',
          installed: have == null ? null : GlobalPackage('jq', have, 'jq'),
          version: version,
          latest: latest,
        );
    var s = of(null, latest: '1.8');
    expect([s.label, s.kind, s.action, s.args], [
      'Not installed',
      GlobalStatusKind.missing,
      'Install',
      ['global', 'install', 'jq'],
    ]);
    s = of('1.8', latest: '1.8');
    expect([s.label, s.action, s.args], [
      'Installed 1.8',
      'Reinstall',
      ['global', 'install', 'jq', '--force-reinstall'],
    ]);
    s = of('1.7', latest: '1.10');
    expect([s.label, s.kind, s.action, s.args], [
      'Update available: 1.7 → 1.10',
      GlobalStatusKind.outdated,
      'Update to 1.10',
      ['global', 'install', 'jq'],
    ]);
    s = of('1.8', version: '1.7', latest: '1.8');
    expect([s.label, s.action, s.args], [
      'Installed 1.8',
      'Install 1.7 instead',
      ['global', 'install', 'jq==1.7'],
    ]);
  });

  test('terminal output is split into clean lines', () {
    expect(
      terminalLines('\x1B[32m✔\x1B[0m one\r\ntwo\rthree\n\n'),
      ['✔ one', 'two', 'three'],
    );
  });

  testWidgets('no run button where pixi cannot run', (tester) async {
    await pumpCommands(tester, null);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsNWidgets(2));
  });

  testWidgets('runs pixi global install and reports success', (tester) async {
    final runner = FakeRunner();
    await pumpCommands(tester, runner);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(runner.args.single, [
      'global',
      'install',
      '-c',
      'https://prefix.dev/nandi-testing',
      'zumba==1.0.0',
    ]);
    expect(find.text('Install zumba'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    runner.output.add('✔ The zumba environment has been installed.');
    await tester.pump();
    expect(
      find.text('✔ The zumba environment has been installed.'),
      findsOneWidget,
    );

    runner.exit.complete(0);
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.text('Install zumba'), findsNothing);
    expect(find.text('Installed zumba with pixi global'), findsOneWidget);
    expect(runner.killed, isFalse);
    expect(runner.lists, 2);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('shows the installed version and offers a reinstall',
      (tester) async {
    final runner = FakeRunner(
      installed: {'zumba': const GlobalPackage('zumba', '1.0.0', 'zumba')},
    );
    await pumpCommands(tester, runner);
    expect(find.text('pixi global: Installed 1.0.0'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(runner.args.single.last, '--force-reinstall');
  });

  testWidgets('no status when pixi is missing', (tester) async {
    await pumpCommands(tester, FakeRunner(found: false));
    expect(find.textContaining('pixi global:'), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('cancelling stops pixi', (tester) async {
    final runner = FakeRunner();
    await pumpCommands(tester, runner);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(runner.killed, isTrue);
    expect(find.text('Install zumba'), findsNothing);
  });

  testWidgets('says so when pixi is missing', (tester) async {
    await pumpCommands(tester, FakeRunner(found: false));
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('pixi was not found'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.text('Could not install zumba'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
