import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

void main() {
  group('Fragment.toBytes / fromBytes', () {
    test('round-trips a single fragment', () {
      final fragment = Fragment(
        messageId: 42,
        index: 1,
        count: 3,
        data: Uint8List.fromList(utf8.encode('chunk')),
      );

      final decoded = Fragment.fromBytes(fragment.toBytes());

      expect(decoded.messageId, equals(42));
      expect(decoded.index, equals(1));
      expect(decoded.count, equals(3));
      expect(decoded.data, equals(utf8.encode('chunk')));
    });

    test('rejects a buffer shorter than the header', () {
      expect(
        () => Fragment.fromBytes([1, 2, 3]),
        throwsA(isA<PacketDecodeException>()),
      );
    });
  });

  group('Fragmenter.split', () {
    test('splits data into chunks of at most maxChunkSize', () {
      final data = List<int>.generate(25, (i) => i);
      final fragments = Fragmenter.split(data, maxChunkSize: 10);

      expect(fragments.length, equals(3));
      expect(fragments.every((f) => f.count == 3), isTrue);
      expect(fragments.every((f) => f.data.length <= 10), isTrue);
      expect(
        fragments.map((f) => f.index).toList(),
        equals([0, 1, 2]),
      );
      expect(
        fragments.expand((f) => f.data).toList(),
        equals(data),
      );
    });

    test('an empty message still produces exactly one fragment', () {
      final fragments = Fragmenter.split(const [], maxChunkSize: 10);
      expect(fragments, hasLength(1));
      expect(fragments.single.count, equals(1));
      expect(fragments.single.index, equals(0));
      expect(fragments.single.data, isEmpty);
    });

    test('rejects a non-positive maxChunkSize', () {
      expect(
        () => Fragmenter.split([1, 2, 3], maxChunkSize: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Reassembler', () {
    test('reassembles fragments received in order', () {
      final data = List<int>.generate(1000, (i) => i % 256);
      final fragments = Fragmenter.split(data, maxChunkSize: 64);
      final reassembler = Reassembler();

      Uint8List? result;
      for (final fragment in fragments) {
        result = reassembler.add(fragment);
      }

      expect(result, equals(data));
    });

    test('reassembles fragments received out of order', () {
      final data = List<int>.generate(500, (i) => 255 - (i % 256));
      final fragments = Fragmenter.split(data, maxChunkSize: 40)..shuffle(Random(7));
      final reassembler = Reassembler();

      Uint8List? result;
      for (final fragment in fragments) {
        result = reassembler.add(fragment);
      }

      expect(result, equals(data));
    });

    test('duplicate fragments do not break reassembly', () {
      final data = utf8.encode('duplicate one of my fragments please');
      final fragments = Fragmenter.split(data, maxChunkSize: 8);
      final reassembler = Reassembler();

      // Every fragment (including the completing one) is delivered twice.
      // Only the first delivery of the last fragment should complete the
      // message -- capture whichever delivery returns non-null.
      Uint8List? result;
      for (final fragment in fragments) {
        final firstDelivery = reassembler.add(fragment);
        reassembler.add(fragment); // duplicate delivery
        result ??= firstDelivery;
      }

      expect(result, equals(data));
    });

    test('an empty message completes on its single fragment', () {
      final fragments = Fragmenter.split(const [], maxChunkSize: 10);
      final reassembler = Reassembler();

      final result = reassembler.add(fragments.single);
      expect(result, isNotNull);
      expect(result, isEmpty);
    });

    test('returns null while a message is still incomplete', () {
      final data = List<int>.generate(100, (i) => i);
      final fragments = Fragmenter.split(data, maxChunkSize: 10);
      final reassembler = Reassembler();

      for (final fragment in fragments.take(fragments.length - 1)) {
        expect(reassembler.add(fragment), isNull);
      }
    });

    test('abandons an incomplete message after entryLifetime', () {
      final data = List<int>.generate(30, (i) => i);
      final fragments = Fragmenter.split(data, maxChunkSize: 10);
      expect(fragments, hasLength(3));

      final reassembler = Reassembler(entryLifetime: const Duration(minutes: 1));
      final t0 = DateTime.utc(2026, 1, 1);

      expect(reassembler.add(fragments[0], now: t0), isNull);
      // long enough for the pending message to be evicted
      final result = reassembler.add(
        fragments[1],
        now: t0.add(const Duration(minutes: 5)),
      );
      expect(result, isNull);

      // fragments[0] was evicted along with the rest of the pending
      // message, so delivering the remaining two isn't enough anymore --
      // the message must start over from scratch.
      final finalResult = reassembler.add(
        fragments[2],
        now: t0.add(const Duration(minutes: 5)),
      );
      expect(finalResult, isNull);
    });
  });
}
