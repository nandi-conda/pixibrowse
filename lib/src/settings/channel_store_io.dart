import 'dart:convert';
import 'dart:io';

import 'channel_store.dart';

ChannelStore? channelStore() {
  final dir = configDirectory(Platform.environment);
  return dir == null ? null : FileChannelStore(File('$dir/channels.json'));
}

/// Where settings go, following each platform's convention.
String? configDirectory(Map<String, String> env) {
  String? nonEmpty(String? v) => v == null || v.isEmpty ? null : v;
  final override = nonEmpty(env['PIXIBROWSE_CONFIG_DIR']);
  if (override != null) return override;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final appData = nonEmpty(env['APPDATA']);
    return appData == null ? null : '$appData${sep}pixibrowse';
  }
  final home = nonEmpty(env['HOME']);
  if (Platform.isMacOS) {
    return home == null ? null : '$home/Library/Application Support/pixibrowse';
  }
  final xdg = nonEmpty(env['XDG_CONFIG_HOME']);
  if (xdg != null) return '$xdg/pixibrowse';
  return home == null ? null : '$home/.config/pixibrowse';
}

/// A small JSON list of channel names. Failing to read or write is never
/// fatal: the app just starts on the default channel.
class FileChannelStore implements ChannelStore {
  FileChannelStore(this.file);

  final File file;

  @override
  List<String>? load() {
    try {
      return decodeChannels(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  @override
  void save(List<String> channels) {
    try {
      file.parent.createSync(recursive: true);
      // Write beside and rename, so a crash never leaves half a file.
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(channels), flush: true);
      tmp.renameSync(file.path);
    } catch (_) {
      // A read-only disk only means the channels aren't remembered.
    }
  }
}
