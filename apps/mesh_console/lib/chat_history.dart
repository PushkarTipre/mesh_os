import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

int _messageIdCounter = 0;

/// A locally-unique id for a new [ChatMessageRecord] -- lets an outgoing
/// message's status be updated later (sending -> delivered/failed) by id
/// rather than by list position, since an incoming message can be
/// inserted concurrently and shift positional indices.
String newChatMessageId() {
  _messageIdCounter += 1;
  return '${DateTime.now().microsecondsSinceEpoch}-$_messageIdCounter';
}

/// One chat message, sent or received. Chat history is a `mesh_console`
/// (app-level) concern, not something the MeshOS SDK persists itself --
/// per ARCHITECTURE.md's own framing, MeshOS is a networking platform,
/// not a chat app.
class ChatMessageRecord {
  ChatMessageRecord({
    required this.id,
    required this.outgoing,
    required this.text,
    required this.timestamp,
    required this.status,
  });

  final String id;
  final bool outgoing;
  final String text;
  final DateTime timestamp;

  /// 'sending' | 'delivered' | 'failed' | 'received'
  final String status;

  ChatMessageRecord copyWith({String? status}) => ChatMessageRecord(
        id: id,
        outgoing: outgoing,
        text: text,
        timestamp: timestamp,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'outgoing': outgoing,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        'status': status,
      };

  factory ChatMessageRecord.fromJson(Map<String, dynamic> json) => ChatMessageRecord(
        // Older saved history predates the id field -- a synthesized
        // fallback is fine since a historical entry never needs its
        // status updated again.
        id: json['id'] as String? ?? 'legacy-${json['timestamp']}-${json['outgoing']}',
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
/// Owns an in-memory cache plus a live [updates] stream so every screen
/// that cares about chat history -- not just whichever [ChatScreen]
/// happens to be open for a given peer right now -- sees every message
/// the moment it's persisted. This replaced an earlier design where
/// incoming messages were handled *inside* ChatScreen's own
/// `mesh.messages` listener: a message from a peer whose chat wasn't
/// currently the open screen had nothing listening for it at all (a
/// broadcast StreamController drops events with no active listener) and
/// was lost outright -- even though the underlying mesh_core session had
/// already ACKed it, which is why the sender still saw "delivered." See
/// NEXT_STEPS.md. `HomeScreen` now owns the one `mesh.messages` listener
/// that matters (alive for as long as the app is in the foreground,
/// regardless of which screen is on top) and persists every incoming
/// message through this store; `ChatScreen` just renders its current
/// state.
///
/// A simple whole-blob JSON store is enough for a dev harness; a real
/// product would use the SQLite storage landing in a later checkpoint
/// (ARCHITECTURE.md §17, ROADMAP.md Checkpoint 5).
class ChatHistoryStore {
  ChatHistoryStore({FlutterSecureStorage? storage, this.key = 'mesh_console.chat_history'})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final String key;

  Map<String, List<ChatMessageRecord>> _cache = {};
  final StreamController<Map<String, List<ChatMessageRecord>>> _updates =
      StreamController<Map<String, List<ChatMessageRecord>>>.broadcast();
  bool _loaded = false;

  /// Emits the full history map every time it changes -- broadcast, so
  /// it never blocks on a slow listener and works fine with zero
  /// listeners (nothing breaks if no screen happens to be subscribed
  /// when a message arrives; the write to storage still happens).
  Stream<Map<String, List<ChatMessageRecord>>> get updates => _updates.stream;

  /// Every message stored for [nodeId], oldest first. Safe to call any
  /// time after [init] with no further `await` needed.
  List<ChatMessageRecord> forPeer(String nodeId) => List.unmodifiable(_cache[nodeId] ?? const []);

  /// Loads persisted history into the in-memory cache. Call once, before
  /// relying on [forPeer] -- `HomeScreen` does this during bootstrap,
  /// before its `mesh.messages` listener can receive anything.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _storage.read(key: key);
    if (raw != null) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _cache = decoded.map(
        (nodeId, list) => MapEntry(
          nodeId,
          (list as List)
              .map((e) => ChatMessageRecord.fromJson(e as Map<String, dynamic>))
              .toList(),
        ),
      );
    }
    _updates.add(_cache);
  }

  Future<void> add(String peerNodeId, ChatMessageRecord record) async {
    (_cache[peerNodeId] ??= []).add(record);
    await _persist();
  }

  /// Updates a message already in history by [id] -- see [newChatMessageId].
  Future<void> updateStatus(String peerNodeId, String id, String status) async {
    final list = _cache[peerNodeId];
    if (list == null) return;
    final index = list.indexWhere((m) => m.id == id);
    if (index == -1) return;
    list[index] = list[index].copyWith(status: status);
    await _persist();
  }

  Future<void> _persist() async {
    final encoded = _cache.map(
      (nodeId, list) => MapEntry(nodeId, list.map((m) => m.toJson()).toList()),
    );
    await _storage.write(key: key, value: jsonEncode(encoded));
    _updates.add(_cache);
  }
}
