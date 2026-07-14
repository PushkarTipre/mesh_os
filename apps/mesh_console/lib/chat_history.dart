import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One chat message, sent or received. Chat history is a `mesh_console`
/// (app-level) concern, not something the MeshOS SDK persists itself --
/// per ARCHITECTURE.md's own framing, MeshOS is a networking platform,
/// not a chat app.
class ChatMessageRecord {
  ChatMessageRecord({
    required this.outgoing,
    required this.text,
    required this.timestamp,
    required this.status,
  });

  final bool outgoing;
  final String text;
  final DateTime timestamp;

  /// 'sending' | 'delivered' | 'failed' | 'received'
  final String status;

  ChatMessageRecord copyWith({String? status}) => ChatMessageRecord(
        outgoing: outgoing,
        text: text,
        timestamp: timestamp,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'outgoing': outgoing,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        'status': status,
      };

  factory ChatMessageRecord.fromJson(Map<String, dynamic> json) => ChatMessageRecord(
        outgoing: json['outgoing'] as bool,
        text: json['text'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        status: json['status'] as String,
      );
}

/// Persists chat history keyed by the peer's permanent Node ID (never by
/// the transport-level remoteId, which is ephemeral and changes across
/// reconnects -- see `PeerSession.nodeId`'s doc comment).
///
/// A simple whole-blob JSON store is enough for a dev harness; a real
/// product would use the SQLite storage landing in a later checkpoint
/// (ARCHITECTURE.md §17, ROADMAP.md Checkpoint 5).
class ChatHistoryStore {
  ChatHistoryStore({FlutterSecureStorage? storage, this.key = 'mesh_console.chat_history'})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final String key;

  Future<Map<String, List<ChatMessageRecord>>> loadAll() async {
    final raw = await _storage.read(key: key);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (nodeId, list) => MapEntry(
        nodeId,
        (list as List)
            .map((e) => ChatMessageRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
      ),
    );
  }

  Future<void> saveAll(Map<String, List<ChatMessageRecord>> history) async {
    final encoded = history.map(
      (nodeId, list) => MapEntry(nodeId, list.map((m) => m.toJson()).toList()),
    );
    await _storage.write(key: key, value: jsonEncode(encoded));
  }
}
