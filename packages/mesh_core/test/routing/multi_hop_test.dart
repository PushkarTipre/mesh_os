import 'dart:async';
import 'dart:convert';

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

/// Makes contacts of [a] and [b] via a direct connection (so each has the
/// other's public key on file), then disconnects them -- so a later test
/// scenario can have them meet again only indirectly, through a relay.
Future<void> _becomeContactsThenDisconnect(
  FakeTransportNetwork network,
  MeshLink linkA,
  FakeTransport transportA,
  String aId,
  MeshLink linkB,
  FakeTransport transportB,
  String bId,
) async {
  await _connect(transportA, transportB, aId: aId, bId: bId);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await transportA.disconnect(bId);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('multi-hop routing: A -- B -- C, A and C never directly connected', () {
    test('a message from A reaches C through relay B, and B never sees the plaintext',
        () async {
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

      // A and C must already be contacts (met before, directly or via a
      // relay) to route to each other -- sendToNode requires their public
      // key on file. Introduce them via a direct connection, then move
      // apart (out of range of each other) so only B can bridge them.
      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );

      // Now build the real topology: A--B and B--C, but NOT A--C.
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bSawAnything = <InboundMessage>[];
      linkB.messages.listen(bSawAnything.add);

      final cReceived = linkC.messages.first;
      final status = await linkA
          .sendToNode(identityC.nodeId, utf8.encode('hello from far away'))
          .timeout(const Duration(seconds: 2));

      expect(status, equals(DeliveryStatus.delivered));

      final message = await cReceived.timeout(const Duration(seconds: 2));
      expect(message.senderNodeId, equals(identityA.nodeId));
      expect(utf8.decode(message.plaintext), equals('hello from far away'));

      // B relayed opaque bytes only -- it was never the addressed
      // recipient, so it never decrypted or surfaced anything.
      expect(bSawAnything, isEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });

    test('the end-to-end ack also routes back through B, resolving A\'s send', () async {
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

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // If the ack didn't make it back, this would hang until B/C's
      // internal state is cleaned up rather than resolving quickly.
      final status = await linkA
          .sendToNode(identityC.nodeId, utf8.encode('ping'))
          .timeout(const Duration(seconds: 2));

      expect(status, equals(DeliveryStatus.delivered));

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });
  });

  group('store-and-forward: C is offline when A sends, reachable later', () {
    test('B holds the packet and delivers it once C reconnects', () async {
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

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );

      // Only A--B is up right now; C is nowhere nearby.
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final sendFuture = linkA.sendToNode(identityC.nodeId, utf8.encode('are you there?'));

      // give the flood-to-B a moment; it has nowhere else to send it yet.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Now C wanders into range of B.
      final cReceived = linkC.messages.first;
      await _connect(transportB, transportC, aId: 'B', bId: 'C');

      final message = await cReceived.timeout(const Duration(seconds: 2));
      expect(utf8.decode(message.plaintext), equals('are you there?'));

      final status = await sendFuture.timeout(const Duration(seconds: 2));
      expect(status, equals(DeliveryStatus.delivered));

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });

    test('a routed send that never finds a path fails once it expires', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();

      final linkA = MeshLink(
        transport: transportA,
        identity: identityA,
        storeAndForwardExpiry: const Duration(milliseconds: 50),
      )..start();
      final linkC = MeshLink(transport: transportC, identity: identityC)..start();

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );
      // A has no connected peers at all now -- nowhere to even start
      // flooding, and its own store-and-forward expiry is tiny.

      final status = await linkA
          .sendToNode(identityC.nodeId, utf8.encode('into the void'))
          .timeout(const Duration(seconds: 2));

      expect(status, equals(DeliveryStatus.failed));

      await linkA.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportC.dispose();
    });
  });

  group('trust enforcement for routed traffic', () {
    test('a routed message from a sender the recipient has blocked is silently dropped',
        () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();
      final trustStoreC = InMemoryTrustStore();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();
      final linkC = MeshLink(transport: transportC, identity: identityC, trustStore: trustStoreC)
        ..start();

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );

      // C blocks A after having met them.
      final contactA = (await trustStoreC.getContact(identityA.nodeId))!;
      await trustStoreC.upsertContact(contactA.copyWith(trustLevel: TrustLevel.blocked));

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cSawAnything = <InboundMessage>[];
      linkC.messages.listen(cSawAnything.add);

      unawaited(linkA.sendToNode(identityC.nodeId, utf8.encode('hi')));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(cSawAnything, isEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });
  });

  group('relay policy', () {
    test('RelayPolicy.disabled never forwards anyone\'s traffic', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();

      // B refuses to relay, so A's send can only ever resolve via its own
      // store-and-forward expiry -- keep it short so the test doesn't
      // have to wait out the 24h default.
      final linkA = MeshLink(
        transport: transportA,
        identity: identityA,
        storeAndForwardExpiry: const Duration(milliseconds: 100),
      )..start();
      final linkB = MeshLink(
        transport: transportB,
        identity: identityB,
        relayPolicy: RelayPolicy.disabled,
      )..start();
      final linkC = MeshLink(transport: transportC, identity: identityC)..start();

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cSawAnything = <InboundMessage>[];
      linkC.messages.listen(cSawAnything.add);

      final status = await linkA
          .sendToNode(identityC.nodeId, utf8.encode('can you hear me?'))
          .timeout(const Duration(seconds: 2));

      expect(status, equals(DeliveryStatus.failed));
      expect(cSawAnything, isEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('RelayPolicy.trustedContactsOnly refuses to relay for a merely-known peer',
        () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final transportC = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();
      final identityC = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      // B has never explicitly trusted A -- just "known" from the direct
      // handshake, which is not enough under this policy.
      final linkB = MeshLink(
        transport: transportB,
        identity: identityB,
        relayPolicy: RelayPolicy.trustedContactsOnly,
      )..start();
      final linkC = MeshLink(transport: transportC, identity: identityC)..start();

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cSawAnything = <InboundMessage>[];
      linkC.messages.listen(cSawAnything.add);

      unawaited(linkA.sendToNode(identityC.nodeId, utf8.encode('relay this?')));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(cSawAnything, isEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });
  });

  group('relay rate limiting', () {
    test('a single source cannot use a relay to flood unbounded traffic', () async {
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

      await _becomeContactsThenDisconnect(
        network, linkA, transportA, 'A', linkC, transportC, 'C',
      );
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cReceivedCount = <InboundMessage>[];
      linkC.messages.listen(cReceivedCount.add);

      // Fire well more than the per-window relay cap in quick succession.
      for (var i = 0; i < 30; i++) {
        unawaited(linkA.sendToNode(identityC.nodeId, utf8.encode('msg $i')));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Some got through, but not all 30 -- B's rate limit capped it.
      expect(cReceivedCount.length, lessThan(30));
      expect(cReceivedCount, isNotEmpty);

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });
  });
}
