import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'fake_transport.dart';

void main() {
  group('MultiTransport: discovery merging', () {
    test('a peer discovered on multiple transports surfaces as one device', () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();

      final aNearby = FakeTransport(nearbyNet, name: 'nearby');
      final aBle = FakeTransport(bleNet, name: 'ble');
      final bNearby = FakeTransport(nearbyNet, name: 'nearby');
      final bBle = FakeTransport(bleNet, name: 'ble');

      final multiA = MultiTransport([aNearby, aBle]);
      final multiB = MultiTransport([bNearby, bBle]);

      final events = <DeviceEvent>[];
      multiA.deviceEvents.listen(events.add);

      await multiB.startAdvertising(localId: 'B');
      await multiA.startDiscovery(localId: 'A');
      await Future<void>.delayed(Duration.zero);

      final foundEvents = events.where((e) => e.type == DeviceEventType.found).toList();
      expect(foundEvents, hasLength(1));
      expect(foundEvents.single.remoteId, equals('B'));

      await multiA.dispose();
      await multiB.dispose();
    });

    test('name is unavailable on neither transport -- MultiTransport.name joins both', () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();
      final multi = MultiTransport([
        FakeTransport(nearbyNet, name: 'nearby'),
        FakeTransport(bleNet, name: 'ble'),
      ]);

      expect(multi.name, equals('nearby+ble'));

      await multi.dispose();
    });

    test('maxPayloadSize is the minimum across every underlying transport', () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();
      final multi = MultiTransport([
        FakeTransport(nearbyNet, name: 'nearby', maxPayloadSize: 32000),
        FakeTransport(bleNet, name: 'ble', maxPayloadSize: 20),
      ]);

      expect(multi.maxPayloadSize, equals(20));

      await multi.dispose();
    });

    test('a peer only reachable on one transport is unaffected by the other having nothing',
        () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();

      final aBle = FakeTransport(bleNet, name: 'ble');
      final bBle = FakeTransport(bleNet, name: 'ble');
      final multiA = MultiTransport([FakeTransport(nearbyNet, name: 'nearby'), aBle]);

      final events = <DeviceEvent>[];
      multiA.deviceEvents.listen(events.add);

      await bBle.startAdvertising(localId: 'B');
      await multiA.startDiscovery(localId: 'A');
      await Future<void>.delayed(Duration.zero);

      expect(events.where((e) => e.type == DeviceEventType.found), hasLength(1));
      expect(events.single.remoteId, equals('B'));

      await multiA.dispose();
      await bBle.dispose();
    });
  });

  group('MultiTransport: transport selection', () {
    test('connect prefers the first-listed transport when the peer is reachable on both',
        () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();

      final aNearby = FakeTransport(nearbyNet, name: 'nearby');
      final aBle = FakeTransport(bleNet, name: 'ble');
      final bNearby = FakeTransport(nearbyNet, name: 'nearby');
      final bBle = FakeTransport(bleNet, name: 'ble');

      // Nearby listed first -- preferred for bandwidth, matching
      // ARCHITECTURE.md §11's transport priority.
      final multiA = MultiTransport([aNearby, aBle]);
      final multiB = MultiTransport([bNearby, bBle]);

      await multiB.startAdvertising(localId: 'B');
      await multiA.startDiscovery(localId: 'A');
      await Future<void>.delayed(Duration.zero);

      final nearbyIncoming = bNearby.connectionEvents.first;
      final bleSawAnything = <ConnectionEvent>[];
      bBle.connectionEvents.listen(bleSawAnything.add);

      await multiA.connect('B');
      await nearbyIncoming.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bleSawAnything, isEmpty);

      await multiA.dispose();
      await multiB.dispose();
    });

    test('connect falls back to the next transport when the peer is unreachable on the '
        'preferred one', () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();

      final aNearby = FakeTransport(nearbyNet, name: 'nearby');
      final aBle = FakeTransport(bleNet, name: 'ble');
      // B only exists on the ble network -- simulates "Nearby disabled
      // on one device" from ROADMAP.md Checkpoint 8's exit criterion.
      final bBle = FakeTransport(bleNet, name: 'ble');

      final multiA = MultiTransport([aNearby, aBle]);

      await bBle.startAdvertising(localId: 'B');
      await multiA.startDiscovery(localId: 'A');
      await Future<void>.delayed(Duration.zero);

      final bleIncoming = bBle.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.incomingRequest,
      );
      await multiA.connect('B');
      final event = await bleIncoming.timeout(const Duration(seconds: 1));
      expect(event.remoteId, equals('A'));

      await multiA.dispose();
      await bBle.dispose();
    });

    test('connecting to an unknown peer resolves failed rather than throwing or hanging',
        () async {
      final multi = MultiTransport([FakeTransport(FakeTransportNetwork(), name: 'nearby')]);

      final failed = multi.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.failed,
      );
      await multi.connect('nobody');
      final event = await failed.timeout(const Duration(seconds: 1));
      expect(event.remoteId, equals('nobody'));

      await multi.dispose();
    });
  });

  group('MultiTransport: end-to-end connect + send + receive', () {
    test('a full round trip works through the selected active transport', () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();

      final aNearby = FakeTransport(nearbyNet, name: 'nearby');
      final aBle = FakeTransport(bleNet, name: 'ble');
      final bNearby = FakeTransport(nearbyNet, name: 'nearby');
      final bBle = FakeTransport(bleNet, name: 'ble');

      final multiA = MultiTransport([aNearby, aBle]);
      final multiB = MultiTransport([bNearby, bBle]);

      // Symmetric, like real MeshOS usage: both sides advertise and
      // discover, so both correlate a clean synthetic id via the
      // advertised name rather than either falling back.
      await multiB.startAdvertising(localId: 'B');
      await multiA.startAdvertising(localId: 'A');
      await multiA.startDiscovery(localId: 'A');
      await multiB.startDiscovery(localId: 'B');
      await Future<void>.delayed(Duration.zero);

      final aConnected = multiA.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.connected,
      );
      final bConnected = multiB.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.connected,
      );

      multiB.connectionEvents
          .firstWhere((e) => e.type == ConnectionEventType.incomingRequest)
          .then((e) => multiB.respondToConnectionRequest(e.remoteId, accept: true));

      await multiA.connect('B');
      await aConnected;
      await bConnected;

      final received = multiB.dataEvents.first;
      await multiA.send('B', utf8.encode('hello over the mesh'));
      final event = await received.timeout(const Duration(seconds: 2));
      expect(event.remoteId, equals('A'));
      expect(utf8.decode(event.data), equals('hello over the mesh'));

      await multiA.dispose();
      await multiB.dispose();
    });

    test('an incoming connection with no prior discovery still gets a working synthetic id',
        () async {
      final net = FakeTransportNetwork();
      final aBle = FakeTransport(net, name: 'ble');
      final bBle = FakeTransport(net, name: 'ble');

      // multiB never calls startDiscovery -- it only learns about A once
      // A connects in, with no `found` event to correlate a name from.
      final multiB = MultiTransport([bBle]);
      await multiB.startAdvertising(localId: 'B');
      // Only to give A a _localId to report as the connection's source --
      // A never discovers or advertises meaningfully here.
      await aBle.startAdvertising(localId: 'A');

      final incoming = multiB.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.incomingRequest,
      );
      await aBle.connect('B');

      final requestEvent = await incoming.timeout(const Duration(seconds: 1));
      expect(requestEvent.remoteId, equals('ble:A')); // transport-namespaced fallback id

      final bConnected = multiB.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.connected,
      );
      await multiB.respondToConnectionRequest(requestEvent.remoteId, accept: true);
      await bConnected;

      final received = aBle.dataEvents.first;
      await multiB.send(requestEvent.remoteId, utf8.encode('hi from fallback id'));
      final dataEvent = await received.timeout(const Duration(seconds: 2));
      expect(utf8.decode(dataEvent.data), equals('hi from fallback id'));

      await multiB.dispose();
      await aBle.dispose();
    });

    test('disconnect targets the correct underlying transport', () async {
      final nearbyNet = FakeTransportNetwork();
      final bleNet = FakeTransportNetwork();

      final aNearby = FakeTransport(nearbyNet, name: 'nearby');
      final aBle = FakeTransport(bleNet, name: 'ble');
      final bBle = FakeTransport(bleNet, name: 'ble');
      // B is only reachable via ble -- forces multiA to select aBle.

      final multiA = MultiTransport([aNearby, aBle]);

      await bBle.startAdvertising(localId: 'B');
      await multiA.startDiscovery(localId: 'A');
      await Future<void>.delayed(Duration.zero);

      final aConnected = multiA.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.connected,
      );
      bBle.connectionEvents
          .firstWhere((e) => e.type == ConnectionEventType.incomingRequest)
          .then((e) => bBle.respondToConnectionRequest(e.remoteId, accept: true));
      await multiA.connect('B');
      await aConnected;

      final bDisconnected = bBle.connectionEvents.firstWhere(
        (e) => e.type == ConnectionEventType.disconnected,
      );
      await multiA.disconnect('B');
      await bDisconnected.timeout(const Duration(seconds: 1));

      await multiA.dispose();
      await bBle.dispose();
    });
  });

  group('MultiTransport: one transport failing does not block the others', () {
    test('startAdvertising on a broken transport does not prevent the healthy one', () async {
      final healthyNet = FakeTransportNetwork();
      final multi = MultiTransport([_ThrowingTransport(), FakeTransport(healthyNet, name: 'ok')]);

      // Should not throw despite the first transport always failing.
      await multi.startAdvertising(localId: 'A');

      final other = FakeTransport(healthyNet, name: 'ok');
      final found = other.deviceEvents.firstWhere((e) => e.type == DeviceEventType.found);
      await other.startDiscovery(localId: 'other');
      final event = await found.timeout(const Duration(seconds: 1));
      expect(event.remoteId, equals('A'));

      await multi.dispose();
      await other.dispose();
    });
  });
}

/// A [Transport] double that fails every operation -- stands in for "BLE
/// unsupported on this device" or similar hard transport-level failures.
class _ThrowingTransport implements Transport {
  @override
  String get name => 'throwing';

  @override
  int get maxPayloadSize => 100;

  @override
  Stream<DeviceEvent> get deviceEvents => const Stream.empty();
  @override
  Stream<ConnectionEvent> get connectionEvents => const Stream.empty();
  @override
  Stream<DataEvent> get dataEvents => const Stream.empty();

  @override
  Future<void> startAdvertising({required String localId}) async =>
      throw StateError('unsupported');
  @override
  Future<void> stopAdvertising() async => throw StateError('unsupported');
  @override
  Future<void> startDiscovery({required String localId}) async =>
      throw StateError('unsupported');
  @override
  Future<void> stopDiscovery() async => throw StateError('unsupported');
  @override
  Future<void> connect(String remoteId) async => throw StateError('unsupported');
  @override
  Future<void> respondToConnectionRequest(String remoteId, {required bool accept}) async =>
      throw StateError('unsupported');
  @override
  Future<void> disconnect(String remoteId) async => throw StateError('unsupported');
  @override
  Future<void> send(String remoteId, Uint8List data) async => throw StateError('unsupported');
  @override
  Future<void> dispose() async {}
}
