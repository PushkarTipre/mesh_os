import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class BroadcastEntry {
  BroadcastEntry({required this.senderNodeId, required this.text, required this.timestamp});

  final String senderNodeId;
  final String text;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'senderNodeId': senderNodeId,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      };

  factory BroadcastEntry.fromJson(Map<String, dynamic> json) => BroadcastEntry(
        senderNodeId: json['senderNodeId'] as String,
        text: json['text'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

/// Persistent, always-listening broadcast log -- same reasoning as
/// `ChatHistoryStore`. `BroadcastScreen` used to hold its own list of
/// received broadcasts in local State, fed by its own `mesh.messages`
/// listener, so a broadcast that arrived while some other screen was on
/// top had nothing listening for it and was lost outright. This is owned
/// and fed by `HomeScreen` instead (alive for as long as the app is in
/// the foreground); `BroadcastScreen` just renders it.
class BroadcastLog {
  static const _prefsKey = 'mesh_console.broadcast_log.v1';
  static const _maxEntries = 200;

  final List<BroadcastEntry> _entries = [];
  final StreamController<List<BroadcastEntry>> _updates =
      StreamController<List<BroadcastEntry>>.broadcast();
  SharedPreferences? _prefs;

  List<BroadcastEntry> get entries => List.unmodifiable(_entries);

  Stream<List<BroadcastEntry>> get updates => _updates.stream;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_prefsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _entries.addAll(decoded.map((e) => BroadcastEntry.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        // Corrupt/old-format log -- start fresh rather than crash on our
        // own broadcast history.
      }
    }
    _updates.add(entries);
  }

  void add(BroadcastEntry entry) {
    _entries.add(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    _updates.add(entries);
    unawaited(_persist());
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(_prefsKey, jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }
}
