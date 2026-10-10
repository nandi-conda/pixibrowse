import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'src/conda/cache/cache.dart';
import 'src/conda/repodata.dart';
import 'src/settings/channel_store.dart';
import 'src/state.dart';
import 'src/ui/home.dart';

/// Desktop builds accept the TUI's startup flags:
/// `-c/--channel` (repeatable) and `-p/--platform` (repeatable). Channels
/// given with `-c` win over the saved ones for that run.
void main(List<String> args) {
  final options = parseArgs(args);
  runApp(
    PixiBrowseApp(
      state: BrowserState(
        client: RepodataClient(cache: ByteCache.disk()),
        channels: options.channels.isEmpty ? null : options.channels,
        platforms: options.platforms.isEmpty ? null : options.platforms,
        channelStore: ChannelStore.platformDefault(),
        // Without -c, start by searching every channel, like prefix.dev.
        searchAllChannels: options.channels.isEmpty,
      ),
    ),
  );
}

({List<String> channels, List<String> platforms}) parseArgs(List<String> args) {
  final channels = <String>[];
  final platforms = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? value(String long) {
      if (arg.startsWith('$long=')) return arg.substring(long.length + 1);
      return i + 1 < args.length ? args[++i] : null;
    }

    if (arg == '-c' || arg == '--channel' || arg.startsWith('--channel=')) {
      final v = value('--channel');
      if (v != null) channels.add(v);
    } else if (arg == '-p' ||
        arg == '--platform' ||
        arg.startsWith('--platform=')) {
      final v = value('--platform');
      if (v != null) platforms.add(v);
    }
  }
  return (channels: channels, platforms: platforms);
}

class PixiBrowseApp extends StatelessWidget {
  const PixiBrowseApp({super.key, required this.state, this.followKde = true});
  final BrowserState state;

  /// Whether to pick up the KDE Plasma colour scheme; tests turn it off.
  final bool followKde;

  @override
  Widget build(BuildContext context) {
    return KitSystemTheme(
      followKde: followKde,
      builder: (context, colors) => MaterialApp(
        title: 'pixibrowse',
        debugShowCheckedModeBanner: false,
        theme: KitTheme.material(colors),
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => KitTheme(
          colors: colors,
          child: Material(
            color: colors.background,
            child: DefaultTextStyle(
              style: TextStyle(fontSize: 13, color: colors.text, height: 1.3),
              child: child!,
            ),
          ),
        ),
        home: HomePage(state: state),
      ),
    );
  }
}
