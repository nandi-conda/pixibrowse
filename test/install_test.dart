import 'package:flutter_test/flutter_test.dart';
import 'package:pixibrowse/src/ui/install.dart';

void main() {
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
}
