import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum LogLevel { info, warning, error }

class LogEntry {
  LogEntry({required this.timestamp, required this.level, required this.message});

  final DateTime timestamp;
  final LogLevel level;
  final String message;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'level': level.name,
        'message': message,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        timestamp: DateTime.parse(json['timestamp'] as String),
        level: LogLevel.values.byName(json['level'] as String),
        message: json['message'] as String,
      );

  String format() => '[${timestamp.toIso8601String()}] ${level.name.toUpperCase()}: $message';
}

/// A small, on-device, persistent error/diagnostics log -- exists
/// specifically so a problem on a real phone (permission dialogs,
/// Bluetooth/Nearby stack quirks, anything platform-specific that
/// doesn't reproduce on the developer's own device) leaves a trail the
/// person holding that phone can actually read and share, without
/// needing `adb logcat` or a computer at all.
///
/// Captures three things: explicit [log] calls made by app code (see
/// `HomeScreen`'s use of `MeshOS.diagnostics`), uncaught Flutter
/// framework errors (via `FlutterError.onError`), and uncaught Dart
/// errors anywhere in the app (via `runZonedGuarded` in `main.dart`).
/// Persisted to `SharedPreferences` after every entry so it survives an
/// app restart -- including, as far as any Dart-level logging can, a
/// process kill shortly after a log line was written. A native crash
/// happening entirely outside the Dart VM (no Dart exception ever
/// raised) is the one class of failure this cannot see or explain.
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const _prefsKey = 'mesh_console.app_log.v1';
  static const _maxEntries = 500;

  final List<LogEntry> _entries = [];
  final StreamController<List<LogEntry>> _updates = StreamController<List<LogEntry>>.broadcast();
  SharedPreferences? _prefs;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  Stream<List<LogEntry>> get updates => _updates.stream;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_prefsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _entries.addAll(decoded.map((e) => LogEntry.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        // Corrupt/old-format log -- start fresh rather than crash on our
        // own diagnostics tool.
      }
    }
    _updates.add(entries);
  }

  void log(String message, {LogLevel level = LogLevel.info}) {
    _entries.add(LogEntry(timestamp: DateTime.now(), level: level, message: message));
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

  void clear() {
    _entries.clear();
    _updates.add(entries);
    unawaited(_prefs?.remove(_prefsKey));
  }

  String formatAll() => _entries.map((e) => e.format()).join('\n');
}
