import 'channel_store_stub.dart'
    if (dart.library.io) 'channel_store_io.dart'
    if (dart.library.js_interop) 'channel_store_web.dart' as platform;

/// Remembers the channels the user picked between runs.
abstract class ChannelStore {
  /// The saved channels, or `null` when none were saved or they can't be
  /// read.
  List<String>? load();
  void save(List<String> channels);

  /// A JSON file in the config directory on desktop, `localStorage` on the
  /// web, or `null` where neither exists.
  ///
  /// On desktop it lives in `$PIXIBROWSE_CONFIG_DIR`, or the user's config
  /// directory (`~/.config/pixibrowse/channels.json` on Linux).
  static ChannelStore? platformDefault() => platform.channelStore();
}

/// Keeps channels in memory, for tests.
class MemoryChannelStore implements ChannelStore {
  MemoryChannelStore([this.channels]);

  List<String>? channels;

  @override
  List<String>? load() => channels;

  @override
  void save(List<String> channels) => this.channels = [...channels];
}

/// Reads the saved JSON, ignoring anything that isn't a list of strings.
List<String>? decodeChannels(Object? json) {
  if (json is! List) return null;
  final channels = json.whereType<String>().toList();
  return channels.isEmpty ? null : channels;
}
