import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

void main() {
  group('PacketDedupCache', () {
    test('a fresh packet id is reported as new', () {
      final cache = PacketDedupCache();
      expect(cache.checkAndRecord('aaaa'), isTrue);
    });

    test('the same packet id seen again is a duplicate', () {
      final cache = PacketDedupCache();
      final now = DateTime.utc(2026, 1, 1);
      expect(cache.checkAndRecord('aaaa', now: now), isTrue);
      expect(cache.checkAndRecord('aaaa', now: now), isFalse);
      expect(
        cache.checkAndRecord('aaaa', now: now.add(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('an entry is treated as new again after it expires', () {
      final cache = PacketDedupCache(entryLifetime: const Duration(minutes: 1));
      final now = DateTime.utc(2026, 1, 1);

      expect(cache.checkAndRecord('aaaa', now: now), isTrue);
      expect(
        cache.checkAndRecord('aaaa', now: now.add(const Duration(minutes: 2))),
        isTrue,
      );
    });

    test('capacity eviction drops the oldest entry once full', () {
      final cache = PacketDedupCache(capacity: 3, entryLifetime: const Duration(days: 1));
      final now = DateTime.utc(2026, 1, 1);

      expect(cache.checkAndRecord('a', now: now), isTrue);
      expect(cache.checkAndRecord('b', now: now), isTrue);
      expect(cache.checkAndRecord('c', now: now), isTrue);
      // still within capacity: 'b' is a genuine duplicate
      expect(cache.checkAndRecord('b', now: now), isFalse);

      // a 4th distinct id pushes the oldest entry ('a') out, even though
      // it hasn't expired
      expect(cache.checkAndRecord('d', now: now), isTrue);

      // 'a' was evicted by capacity, so it's treated as new again
      expect(cache.checkAndRecord('a', now: now), isTrue);
    });
  });
}
