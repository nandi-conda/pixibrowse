import 'dart:convert';

import 'package:web/web.dart' as web;

import 'channel_store.dart';

ChannelStore? channelStore() => LocalStorageChannelStore();

class LocalStorageChannelStore implements ChannelStore {
  static const key = 'pixibrowse.channels';

  @override
  List<String>? load() {
    try {
      final raw = web.window.localStorage.getItem(key);
      return raw == null ? null : decodeChannels(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  void save(List<String> channels) {
    try {
      web.window.localStorage.setItem(key, jsonEncode(channels));
    } catch (_) {
      // Storage can be disabled or full; the channels just aren't kept.
    }
  }
}
