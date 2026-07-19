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

void main() {
  group('MeshLinkStats: single-hop', () {
    test('activeSessions reflects the live session count', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      expect(linkA.stats.activeSessions, equals(0));

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(linkA.stats.activeSessions, equals(1));
      expect(linkB.stats.activeSessions, equals(1));

      await transportA.disconnect('B');
      await Future<void>.delayed(Duration.zero);

      expect(linkA.stats.activeSessions, equals(0));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('sending and receiving a message increments packet and byte counters', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final beforeA = linkA.stats;
      final beforeB = linkB.stats;

      final status = await linkA
          .sendData('B', utf8.encode('hello, stats'))
          .timeout(const Duration(seconds: 2));
      expect(status, equals(DeliveryStatus.delivered));

      final afterA = linkA.stats;
      final afterB = linkB.stats;

      // A sent the data packet and received B's ack back.
      expect(afterA.packetsSent, greaterThan(beforeA.packetsSent));
      expect(afterA.packetsReceived, greaterThan(beforeA.packetsReceived));
      expect(afterA.bytesSent, greaterThan(beforeA.bytesSent));

      // B received the data packet and sent an ack back.
      expect(afterB.packetsReceived, greaterThan(beforeB.packetsReceived));
      expect(afterB.packetsSent, greaterThan(beforeB.packetsSent));
      expect(afterB.bytesReceived, greaterThan(beforeB.bytesReceived));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('statsUpdates emits a fresh snapshot as activity happens', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      final updates = <MeshLinkStats>[];
      linkA.statsUpdates.listen(updates.add);

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(updates, isNotEmpty);
      expect(updates.last.activeSessions, equals(1));

      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });
  });

  group('MeshLinkStats: relaying and store-and-forward', () {
    test('a relay increments packetsRelayed on the middle node only', () async {
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

      // A and C must already be contacts to route to each other.
      await _connect(transportA, transportC, aId: 'A', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await transportA.disconnect('C');
      await Future<void>.delayed(Duration.zero);

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final beforeB = linkB.stats.packetsRelayed;
      final beforeA = linkA.stats.packetsRelayed;
      final beforeC = linkC.stats.packetsRelayed;

      final status = await linkA
          .sendToNode(identityC.nodeId, utf8.encode('via the middle'))
          .timeout(const Duration(seconds: 2));
      expect(status, equals(DeliveryStatus.delivered));

      // B relayed both the data packet and C's ack back -- A and C, the
      // endpoints, never relay anything for this exchange.
      expect(linkB.stats.packetsRelayed, greaterThan(beforeB));
      expect(linkA.stats.packetsRelayed, equals(beforeA));
      expect(linkC.stats.packetsRelayed, equals(beforeC));

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });

    test('storedRelayPackets reflects packets held for later delivery', () async {
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

      await _connect(transportA, transportC, aId: 'A', bId: 'C');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await transportA.disconnect('C');
      await Future<void>.delayed(Duration.zero);

      // Only A--B is up right now; C is nowhere nearby.
      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(linkB.stats.storedRelayPackets, equals(0));

      final sendFuture = linkA.sendToNode(identityC.nodeId, utf8.encode('waiting for C'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // B is holding the packet with nowhere else to send it yet.
      expect(linkB.stats.storedRelayPackets, greaterThan(0));

      // Now C wanders into range of B -- the packet gets delivered and
      // (eventually) evicted from the store.
      await _connect(transportB, transportC, aId: 'B', bId: 'C');
      final status = await sendFuture.timeout(const Duration(seconds: 2));
      expect(status, equals(DeliveryStatus.delivered));

      await linkA.dispose();
      await linkB.dispose();
      await linkC.dispose();
      await transportA.dispose();
      await transportB.dispose();
      await transportC.dispose();
    });
  });
}
