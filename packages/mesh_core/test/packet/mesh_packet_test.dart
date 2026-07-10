import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

Uint8List _tempId(int seed) => Uint8List.fromList(List<int>.filled(8, seed));

void main() {
  group('MeshPacket round-trip', () {
    for (final type in PacketType.values) {
      test('encodes and decodes a $type packet', () async {
        final sender = await NodeIdentity.generate();
        final payload = utf8.encode('payload for $type');
        final packet = await MeshPacket.create(
          signer: sender,
          type: type,
          tempSourceId: _tempId(1),
          tempDestId: _tempId(2),
          payload: payload,
          ttl: 5,
        );

        final decoded = MeshPacket.decode(packet.toBytes());

        expect(decoded.version, equals(MeshPacket.currentVersion));
        expect(decoded.type, equals(type));
        expect(decoded.packetId, equals(packet.packetId));
        expect(
          decoded.timestamp.millisecondsSinceEpoch,
          equals(packet.timestamp.millisecondsSinceEpoch),
        );
        expect(decoded.tempSourceId, equals(_tempId(1)));
        expect(decoded.tempDestId, equals(_tempId(2)));
        expect(decoded.priority, equals(PacketPriority.normal));
        expect(decoded.ttl, equals(5));
        expect(decoded.hopCount, equals(0));
        expect(decoded.signature, equals(packet.signature));
        expect(decoded.payload, equals(payload));
      });
    }

    test('round-trips an empty payload', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.heartbeat,
        tempSourceId: _tempId(1),
        tempDestId: MeshPacket.broadcastDestination,
        payload: const [],
      );

      final decoded = MeshPacket.decode(packet.toBytes());
      expect(decoded.payload, isEmpty);
      expect(decoded.tempDestId, equals(MeshPacket.broadcastDestination));
    });

    test('round-trips a large payload', () async {
      final sender = await NodeIdentity.generate();
      final payload = List<int>.generate(20000, (i) => i % 256);
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.file,
        tempSourceId: _tempId(1),
        tempDestId: _tempId(2),
        payload: payload,
      );

      final decoded = MeshPacket.decode(packet.toBytes());
      expect(decoded.payload, equals(payload));
    });
  });

  group('relaying: ttl/hopCount vs signature', () {
    test('forwarded() decrements ttl and increments hopCount', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.data,
        tempSourceId: _tempId(1),
        tempDestId: _tempId(2),
        payload: utf8.encode('hop me'),
        ttl: 2,
      );

      final hop1 = packet.forwarded()!;
      expect(hop1.ttl, equals(1));
      expect(hop1.hopCount, equals(1));

      final hop2 = hop1.forwarded()!;
      expect(hop2.ttl, equals(0));
      expect(hop2.hopCount, equals(2));

      expect(hop2.forwarded(), isNull);
    });

    test('a relayed packet\'s signature still verifies -- relays never '
        'held the private key and never re-signed it', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.data,
        tempSourceId: _tempId(1),
        tempDestId: _tempId(2),
        payload: utf8.encode('relay me'),
        ttl: 4,
      );

      var relayed = packet;
      for (var i = 0; i < 3; i++) {
        relayed = relayed.forwarded()!;
      }

      expect(await relayed.verifySignature(sender.signingPublicKey), isTrue);
      expect(relayed.hopCount, equals(3));

      // and it still round-trips through the wire after relaying, with a
      // freshly computed checksum for the new ttl/hopCount.
      final decoded = MeshPacket.decode(relayed.toBytes());
      expect(decoded.ttl, equals(1));
      expect(decoded.hopCount, equals(3));
      expect(await decoded.verifySignature(sender.signingPublicKey), isTrue);
    });

    test('signature fails against a different signer\'s public key', () async {
      final sender = await NodeIdentity.generate();
      final impostor = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.data,
        tempSourceId: _tempId(1),
        tempDestId: _tempId(2),
        payload: utf8.encode('hello'),
      );

      expect(await packet.verifySignature(impostor.signingPublicKey), isFalse);
    });

    test('signature fails if the payload is tampered with', () async {
      final sender = await NodeIdentity.generate();
      final packet = await MeshPacket.create(
        signer: sender,
        type: PacketType.data,
        tempSourceId: _tempId(1),
        tempDestId: _tempId(2),
        payload: utf8.encode('untouched'),
      );

      final decoded = MeshPacket.decode(packet.toBytes());
      decoded.payload[0] ^= 0xFF;

      expect(await decoded.verifySignature(sender.signingPublicKey), isFalse);
    });
  });

  group('input validation', () {
    test('create() rejects a tempSourceId of the wrong length', () async {
      final sender = await NodeIdentity.generate();
      expect(
        () => MeshPacket.create(
          signer: sender,
          type: PacketType.data,
          tempSourceId: [1, 2, 3],
          tempDestId: _tempId(2),
          payload: const [],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
