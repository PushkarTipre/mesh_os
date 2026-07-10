import 'dart:typed_data';

import 'fragment.dart';

class _PendingMessage {
  _PendingMessage({required this.count, required this.receivedAt});

  final int count;
  DateTime receivedAt;
  final Map<int, Uint8List> chunks = {};
}

/// Accumulates [Fragment]s and reassembles them back into the original
/// bytes once every fragment for a message has arrived. Tolerates
/// out-of-order arrival and duplicate fragments; abandons an incomplete
/// message after [entryLifetime] of inactivity so a lost fragment doesn't
/// leak memory forever.
class Reassembler {
  Reassembler({this.entryLifetime = const Duration(minutes: 2)});

  final Duration entryLifetime;
  final Map<int, _PendingMessage> _pending = {};

  /// Feeds one fragment in. Returns the fully reassembled bytes once
  /// [fragment]'s message is complete, or null if it's still incomplete
  /// (or was dropped for being inconsistent with an in-progress message).
  Uint8List? add(Fragment fragment, {DateTime? now}) {
    final currentTime = now ?? DateTime.now();
    _evictExpired(currentTime);

    final pending = _pending.putIfAbsent(
      fragment.messageId,
      () => _PendingMessage(count: fragment.count, receivedAt: currentTime),
    );

    if (fragment.count != pending.count) {
      // Inconsistent count for a known messageId -- ignore rather than
      // corrupt the in-progress reassembly.
      return null;
    }

    pending.chunks[fragment.index] = fragment.data;
    pending.receivedAt = currentTime;

    if (pending.chunks.length < pending.count) {
      return null;
    }

    final builder = BytesBuilder();
    for (var i = 0; i < pending.count; i++) {
      builder.add(pending.chunks[i]!);
    }
    _pending.remove(fragment.messageId);
    return builder.toBytes();
  }

  void _evictExpired(DateTime now) {
    _pending.removeWhere(
      (_, pending) => now.difference(pending.receivedAt) > entryLifetime,
    );
  }
}
