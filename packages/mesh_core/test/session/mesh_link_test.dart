import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import '../transport/fake_transport.dart';

/// Connects [a] to [b] over [network] (advertise/discover/connect/accept)
/// and returns once both sides report a live connection.
Future<void> _connect(FakeTransport a, FakeTransport b, {
  required String aId,
  required String bId,
}) async {
  await a.startAdvertising(localId: aId);
  await b.startDiscovery(localId: bId);
  await Future<void>.delayed(Duration.zero);

  final aConnected = a.connectionEvents.firstWhere(
    (e) => e.type == ConnectionEventType.connected,
  );
  final bConnected = b.connectionEvents.firstWhere(
    (e) => e.type == ConnectionEventType.connected,
  );

  a.connectionEvents
      .firstWhere((e) => e.type == ConnectionEventType.incomingRequest)
      .then((e) => a.respondToConnectionRequest(e.remoteId, accept: true));

  await b.connect(aId);
  await aConnected;
  await bConnected;
}

void main() {
  group('MeshLink end-to-end (FakeTransport, no hardware)', () {
    test('two peers complete the discovery handshake and exchange an '
        'encrypted, verified message', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');

      // let the automatic discovery handshake (triggered by the
      // 'connected' event on both sides) settle.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(linkA.hasSession('B'), isTrue);
      expect(linkB.hasSession('A'), isTrue);

      final received = linkA.messages.first;
      await linkB.sendData('A', utf8.encode('hello from B'));

      final message = await received.timeout(const Duration(seconds: 2));
      expect(message.remoteId, equals('B'));
      expect(utf8.decode(message.plaintext), equals('hello from B'));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('a message larger than the transport MTU is fragmented and '
        'reassembled correctly', () async {
      final network = FakeTransportNetwork();
      // Small MTU forces both the discovery handshake payload and the
      // test message below through the Fragmenter/Reassembler path.
      final transportA = FakeTransport(network, maxPayloadSize: 40);
      final transportB = FakeTransport(network, maxPayloadSize: 40);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(linkA.hasSession('B'), isTrue);
      expect(linkB.hasSession('A'), isTrue);

      final largeMessage = 'x' * 500; // well over the 40-byte MTU
      final received = linkA.messages.first;
      await linkB.sendData('A', utf8.encode(largeMessage));

      final message = await received.timeout(const Duration(seconds: 2));
      expect(utf8.decode(message.plaintext), equals(largeMessage));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('messages flow both directions once the session is established', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bReceived = linkB.messages.first;
      await linkA.sendData('B', utf8.encode('ping'));
      final pingMessage = await bReceived.timeout(const Duration(seconds: 2));
      expect(utf8.decode(pingMessage.plaintext), equals('ping'));

      final aReceived = linkA.messages.first;
      await linkB.sendData('A', utf8.encode('pong'));
      final pongMessage = await aReceived.timeout(const Duration(seconds: 2));
      expect(utf8.decode(pongMessage.plaintext), equals('pong'));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('sendData throws before a session is established', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final linkA = MeshLink(transport: transportA, identity: identityA)..start();

      expect(
        () => linkA.sendData('nobody', utf8.encode('hi')),
        throwsA(isA<StateError>()),
      );

      await linkA.dispose();
      await transportA.dispose();
    });

    test('disconnecting clears the session; reconnecting re-establishes it', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(linkA.hasSession('B'), isTrue);

      await transportA.disconnect('B');
      await Future<void>.delayed(Duration.zero);
      expect(linkA.hasSession('B'), isFalse);

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(linkA.hasSession('B'), isTrue);

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('a garbled byte blob from a connected peer is dropped, not crashed on', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      // transportB has no MeshLink -- it's a "malicious" or buggy peer
      // sending raw garbage instead of well-formed packets.

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(Duration.zero);

      await transportB.send('A', Uint8List.fromList(List<int>.filled(50, 0xFF)));
      await Future<void>.delayed(Duration.zero);

      // still alive and has no session for B (no valid discovery packet
      // was ever received from it)
      expect(linkA.hasSession('B'), isFalse);

      await linkA.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });
  });
}
