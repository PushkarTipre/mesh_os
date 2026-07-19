import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import '../transport/fake_transport.dart';

/// Connects [a] to [b] directly (advertise/discover/connect/accept) and
/// returns once both sides report a live connection.
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
  group('broadcast: A -- B -- C, no prior contact needed', () {
    test('a plain broadcast from A reaches C through relay B', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();
      final linkC = MeshLink(transport: transportC, identity: identityC)..start();

      // Unlike sendToNode, broadcast needs no prior contact -- it's
      // self-certifying, not encrypted for a specific recipient.
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cReceived = linkC.messages.first;
      await linkA.broadcast(utf8.encode('hello, mesh'));

      final message = await cReceived.timeout(const Duration(seconds: 2));
      expect(message.senderNodeId, equals(identityA.nodeId));
      expect(utf8.decode(message.plaintext), equals('hello, mesh'));
      expect(message.topic, equals('')); // plain broadcast -- empty topic

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });

    test('a node relays a broadcast even without ever seeing it before, and '
        'does not re-surface its own echo', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final aSawAnything = <InboundMessage>[];
      linkA.messages.listen(aSawAnything.add);

      final bReceived = linkB.messages.first;
      await linkA.broadcast(utf8.encode('one and only'));
      await bReceived.timeout(const Duration(seconds: 2));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(aSawAnything, isEmpty); // A never surfaces its own broadcast

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });
  });

  group('topic pub/sub', () {
    test('only a subscriber surfaces a topic publish on messages', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      linkB.subscribe('weather');

      final bReceived = linkB.messages.first;
      await linkA.publish('weather', utf8.encode('sunny'));

      final message = await bReceived.timeout(const Duration(seconds: 2));
      expect(utf8.decode(message.plaintext), equals('sunny'));
      expect(message.topic, equals('weather'));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('a node not subscribed to the topic does not surface it, but still '
        'relays it on to a subscriber further along', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      // B is not subscribed to anything -- it should relay blind.
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();
      final linkC = MeshLink(transport: transportC, identity: identityC)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      linkC.subscribe('news');

      final bSawAnything = <InboundMessage>[];
      linkB.messages.listen(bSawAnything.add);

      final cReceived = linkC.messages.first;
      await linkA.publish('news', utf8.encode('breaking'));

      final message = await cReceived.timeout(const Duration(seconds: 2));
      expect(utf8.decode(message.plaintext), equals('breaking'));
      expect(bSawAnything, isEmpty); // B relayed it, but never subscribed

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });

    test('a subscriber does not see a publish for a different topic', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      linkB.subscribe('sports');

      final bSawAnything = <InboundMessage>[];
      linkB.messages.listen(bSawAnything.add);

      await linkA.publish('weather', utf8.encode('rainy'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bSawAnything, isEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('unsubscribe stops future surfacing of that topic', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      linkB.subscribe('weather');
      final firstReceived = linkB.messages.first;
      await linkA.publish('weather', utf8.encode('sunny'));
      await firstReceived.timeout(const Duration(seconds: 2));

      linkB.unsubscribe('weather');
      final bSawAnything = <InboundMessage>[];
      linkB.messages.listen(bSawAnything.add);
      await linkA.publish('weather', utf8.encode('cloudy'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bSawAnything, isEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('publish rejects an empty topic (use broadcast instead)', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final linkA = MeshLink(transport: transportA, identity: identityA)..start();

      expect(
        () => linkA.publish('', utf8.encode('x')),
        throwsA(isA<ArgumentError>()),
      );

      await linkA.dispose();
      await transportA.dispose();
    });
  });

  group('broadcast signature integrity', () {
    test(
        'a broadcast whose embedded key does not match its actual signer is '
        'dropped, not surfaced or relayed', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();
      // The forged payload will claim to be from this identity, but the
      // packet is actually signed by identityA's key -- the signature
      // can't verify against an embedded key it wasn't made with.
      final impersonated = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();
      final linkC = MeshLink(transport: transportC, identity: identityC)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final forgedPayload = BytesBuilder()
        ..add(impersonated.signingPublicKey.bytes)
        ..addByte(0) // empty topic
        ..add(utf8.encode('forged'));
      final forged = await MeshPacket.create(
        signer: identityA,
        type: PacketType.broadcast,
        tempSourceId: identityA.routingAddress,
        tempDestId: MeshPacket.broadcastDestination,
        payload: forgedPayload.toBytes(),
      );

      final bSawAnything = <InboundMessage>[];
      final cSawAnything = <InboundMessage>[];
      linkB.messages.listen(bSawAnything.add);
      linkC.messages.listen(cSawAnything.add);

      // Bypass linkA.broadcast() (which always signs honestly) to inject
      // the forged packet directly, envelope-marker-prefixed the same way
      // MeshLink._sendBytes would.
      await transportA.send('B', Uint8List.fromList([0x00, ...forged.toBytes()]));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bSawAnything, isEmpty);
      expect(cSawAnything, isEmpty); // dropped at B -- never relayed onward

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });
  });
}
