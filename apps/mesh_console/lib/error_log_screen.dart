import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

/// Shows [AppLog]'s persisted entries -- diagnostics from `MeshOS.start()`
/// (see `MeshOS.diagnostics`), uncaught Flutter/Dart errors, and anything
/// else the app explicitly logged. Exists so a problem on someone else's
/// phone can be read and shared without a computer or `adb` -- see
/// AppLog's own doc comment for the full rationale.
class ErrorLogScreen extends StatefulWidget {
  const ErrorLogScreen({super.key});

  @override
  State<ErrorLogScreen> createState() => _ErrorLogScreenState();
}

class _ErrorLogScreenState extends State<ErrorLogScreen> {
  List<LogEntry> _entries = const [];
  StreamSubscription<List<LogEntry>>? _sub;

  @override
  void initState() {
    super.initState();
    _entries = AppLog.instance.entries;
    _sub = AppLog.instance.updates.listen((entries) {
      if (!mounted) return;
      setState(() => _entries = entries);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: AppLog.instance.formatAll()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied all log entries to clipboard')),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear log?'),
        content: const Text('This removes every entry from this device. It cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) {
      AppLog.instance.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Newest first -- the most recent entries are almost always the
    // interesting ones (what just happened / what just failed).
    final reversed = _entries.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Error log (${_entries.length})'),
        actions: [
          IconButton(icon: const Icon(Icons.copy), onPressed: _copyAll, tooltip: 'Copy all'),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _clear, tooltip: 'Clear'),
        ],
      ),
      body: reversed.isEmpty
          ? const Center(child: Text('No log entries yet'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: reversed.length,
              separatorBuilder: (context, index) => const Divider(height: 16),
              itemBuilder: (context, index) => _buildEntry(reversed[index]),
            ),
    );
  }

  Widget _buildEntry(LogEntry entry) {
    final color = switch (entry.level) {
      LogLevel.error => Colors.red.shade700,
      LogLevel.warning => Colors.orange.shade800,
      LogLevel.info => Colors.black87,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${entry.timestamp.toIso8601String()} · ${entry.level.name.toUpperCase()}',
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        SelectableText(
          entry.message,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    );
  }
}
