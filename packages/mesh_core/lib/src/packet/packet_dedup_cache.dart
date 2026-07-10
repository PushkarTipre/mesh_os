import 'dart:collection';

/// Tracks recently-seen packet IDs so a relay can flood a packet at most
/// once instead of re-broadcasting it forever (ARCHITECTURE.md §13, §15).
///
/// Entries expire after [entryLifetime] of inactivity, and the cache is
/// additionally capped at [capacity] as a safety valve against unbounded
/// memory growth from a flood of unique IDs before their natural expiry.
class PacketDedupCache {
  PacketDedupCache({
    this.capacity = 1024,
    this.entryLifetime = const Duration(minutes: 5),
  });

  final int capacity;
  final Duration entryLifetime;

  // Insertion order == chronological order, since a duplicate hit never
  // re-inserts/reorders an existing key. That lets eviction stop at the
  // first non-expired entry instead of scanning the whole map.
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  /// Records [packetIdHex] as seen and returns true if it's new (should be
  /// relayed), or false if it's a duplicate seen within [entryLifetime]
  /// (should be dropped).
  bool checkAndRecord(String packetIdHex, {DateTime? now}) {
    final currentTime = now ?? DateTime.now();
    _evictExpired(currentTime);

    if (_seen.containsKey(packetIdHex)) {
      return false;
    }

    _seen[packetIdHex] = currentTime;
    if (_seen.length > capacity) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  void _evictExpired(DateTime now) {
    while (_seen.isNotEmpty) {
      final oldestKey = _seen.keys.first;
      final oldestSeenAt = _seen[oldestKey]!;
      if (now.difference(oldestSeenAt) > entryLifetime) {
        _seen.remove(oldestKey);
      } else {
        break;
      }
    }
  }
}
