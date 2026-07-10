import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

/// Asserts that decoding [bytes] either throws a [PacketDecodeException]
/// (the contract for malformed input) or succeeds without crashing when
/// its fields are touched. It must never let any other exception type --
/// RangeError, FormatException, etc -- escape.
void _decodeNeverCrashes(List<int> bytes) {
  try {
    final decoded = MeshPacket.decode(bytes);
    // Successful decode of fuzzed input should still be a well-formed
    // object -- touching its fields must not itself crash.
    // ignore: unused_local_variable
    final touch = '${decoded.type}${decoded.ttl}${decoded.hopCount}'
        '${decoded.payload.length}${decoded.packetIdHex}';
  } on PacketDecodeException {
    // expected outcome for malformed input
  } catch (e) {
    fail('decode() leaked a non-PacketDecodeException error: $e');
  }
}

void main() {
  group('fuzz: truncated buffers', () {
    test('every truncation of a valid packet is rejected cleanly', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.data,
        tempSourceId: Uint8List(8),
        tempDestId: Uint8List(8),
        payload: utf8.encode('a reasonably long payload to truncate'),
      );
      final full = packet.toBytes();

      for (var length = 0; length < full.length; length++) {
        final truncated = full.sublist(0, length);
        expect(
          () => MeshPacket.decode(truncated),
          throwsA(isA<PacketDecodeException>()),
          reason: 'truncating to $length bytes should be rejected',
        );
      }
    });

    test('empty buffer is rejected cleanly', () {
      expect(
        () => MeshPacket.decode(const []),
        throwsA(isA<PacketDecodeException>()),
      );
    });
  });

  group('fuzz: corrupted bytes never crash the decoder', () {
    test('random single-byte corruption', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.data,
        tempSourceId: Uint8List(8),
        tempDestId: Uint8List(8),
        payload: utf8.encode('corrupt me in various ways'),
      );
      final original = packet.toBytes();
      final random = Random(1234);

      for (var trial = 0; trial < 500; trial++) {
        final corrupted = Uint8List.fromList(original);
        final position = random.nextInt(corrupted.length);
        corrupted[position] ^= 1 + random.nextInt(255);
        _decodeNeverCrashes(corrupted);
      }
    });

    test('random multi-byte corruption', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.broadcast,
        tempSourceId: Uint8List(8),
        tempDestId: MeshPacket.broadcastDestination,
        payload: utf8.encode('another payload for good measure'),
      );
      final original = packet.toBytes();
      final random = Random(5678);

      for (var trial = 0; trial < 500; trial++) {
        final corrupted = Uint8List.fromList(original);
        final corruptionCount = 1 + random.nextInt(5);
        for (var i = 0; i < corruptionCount; i++) {
          final position = random.nextInt(corrupted.length);
          corrupted[position] ^= 1 + random.nextInt(255);
        }
        _decodeNeverCrashes(corrupted);
      }
    });
  });

  group('fuzz: pure random garbage', () {
    test('random-length random-content buffers never crash the decoder', () {
      final random = Random(91011);

      for (var trial = 0; trial < 1000; trial++) {
        final length = random.nextInt(300);
        final garbage = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        _decodeNeverCrashes(garbage);
      }
    });
  });
}
