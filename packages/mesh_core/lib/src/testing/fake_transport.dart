import 'dart:async';
import 'dart:typed_data';

import '../transport/transport.dart';

/// In-memory shared medium for [FakeTransport] instances -- lets tests
/// (and `MeshSimulatorScreen`-style in-app demos) wire up two or more
/// simulated nodes without any real radio, mirroring what a production
/// Transport (Nearby, BLE) does over the air.
class FakeTransportNetwork {
  final Map<String, FakeTransport> _advertising = {};
  final Set<FakeTransport> _discovering = {};

  void _startAdvertising(String localId, FakeTransport transport) {
    _advertising[localId] = transport;
  }

  void _stopAdvertising(String localId) {
    final advertiser = _advertising.remove(localId);
    if (advertiser == null) return;
    for (final discoverer in _discovering) {
      if (discoverer != advertiser) {
        discoverer._onPeerLost(localId);
      }
    }
  }

  void _startDiscovery(FakeTransport transport) {
    _discovering.add(transport);
    for (final entry in _advertising.entries) {
      if (entry.value != transport) {
        transport._onPeerFound(entry.key);
      }
    }
  }

  void _stopDiscovery(FakeTransport transport) {
    _discovering.remove(transport);
  }

  FakeTransport? _lookupAdvertiser(String remoteId) => _advertising[remoteId];
}

/// A [Transport] test double backed by [FakeTransportNetwork] instead of a
/// real radio. Lets the session/handshake/routing layers -- and a full
/// multi-node mesh -- run and be observed with zero hardware, whether
/// from `dart test` or from a real Flutter app (see
/// `mesh_console`'s Mesh Simulator screen).
///
/// **What this proves and what it doesn't:** everything above the
/// transport layer (crypto, handshake, routing, relay, trust,
/// broadcast/pub-sub, file transfer) runs against this exactly as it
/// would against a real radio -- `MeshLink` never knows the difference.
/// What it *cannot* prove is that `NearbyTransport`/`BleTransport`
/// themselves work, because that specifically requires two distinct
/// physical radios talking to each other over the air; there is no
/// single-device substitute for that. See ARCHITECTURE.md and
/// NEXT_STEPS.md.
class FakeTransport implements Transport {
  FakeTransport(this.network, {this.maxPayloadSize = 32000, this.name = 'fake'});

  final FakeTransportNetwork network;

  @override
  final int maxPayloadSize;

  @override
  final String name;

  String? _localId;
  final Map<String, FakeTransport> _pendingIncoming = {};
  final Map<String, FakeTransport> _connected = {};
  int _dropNextSends = 0;

  /// Test hook: the next [count] calls to [send] are silently swallowed,
  /// as if the packet never arrived -- simulates radio packet loss for
  /// exercising retry/reliability logic.
  void dropNextSends(int count) {
    _dropNextSends += count;
  }

  final _deviceEvents = StreamController<DeviceEvent>.broadcast();
  final _connectionEvents = StreamController<ConnectionEvent>.broadcast();
  final _dataEvents = StreamController<DataEvent>.broadcast();

  @override
  Stream<DeviceEvent> get deviceEvents => _deviceEvents.stream;
  @override
  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override
  Stream<DataEvent> get dataEvents => _dataEvents.stream;

  @override
  Future<void> startAdvertising({required String localId}) async {
    _localId = localId;
    network._startAdvertising(localId, this);
  }

  @override
  Future<void> stopAdvertising() async {
    if (_localId != null) network._stopAdvertising(_localId!);
  }

  @override
  Future<void> startDiscovery({required String localId}) async {
    _localId ??= localId;
    network._startDiscovery(this);
  }

  @override
  Future<void> stopDiscovery() async {
    network._stopDiscovery(this);
  }

  void _onPeerFound(String remoteId) {
    _deviceEvents.add(
      DeviceEvent(remoteId: remoteId, type: DeviceEventType.found, advertisedName: remoteId),
    );
  }

  void _onPeerLost(String remoteId) {
    _deviceEvents.add(DeviceEvent(remoteId: remoteId, type: DeviceEventType.lost));
  }

  @override
  Future<void> connect(String remoteId) async {
    final peer = network._lookupAdvertiser(remoteId);
    if (peer == null) {
      _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.failed));
      return;
    }
    peer._receiveConnectionRequest(fromId: _localId!, fromTransport: this);
  }

  void _receiveConnectionRequest({required String fromId, required FakeTransport fromTransport}) {
    _pendingIncoming[fromId] = fromTransport;
    _connectionEvents.add(ConnectionEvent(remoteId: fromId, type: ConnectionEventType.incomingRequest));
  }

  @override
  Future<void> respondToConnectionRequest(String remoteId, {required bool accept}) async {
    final requester = _pendingIncoming.remove(remoteId);
    if (requester == null) return;

    if (accept) {
      _connected[remoteId] = requester;
      requester._connected[_localId!] = this;
      _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.connected));
      requester._connectionEvents.add(ConnectionEvent(remoteId: _localId!, type: ConnectionEventType.connected));
    } else {
      requester._connectionEvents.add(ConnectionEvent(remoteId: _localId!, type: ConnectionEventType.failed));
    }
  }

  @override
  Future<void> disconnect(String remoteId) async {
    final peer = _connected.remove(remoteId);
    if (peer == null) return;
    peer._connected.remove(_localId);
    _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.disconnected));
    peer._connectionEvents.add(ConnectionEvent(remoteId: _localId!, type: ConnectionEventType.disconnected));
  }

  @override
  Future<void> send(String remoteId, Uint8List data) async {
    final peer = _connected[remoteId];
    if (peer == null) {
      throw StateError('FakeTransport($_localId): not connected to $remoteId');
    }
    if (_dropNextSends > 0) {
      _dropNextSends -= 1;
      return;
    }
    peer._dataEvents.add(DataEvent(remoteId: _localId!, data: data));
  }

  @override
  Future<void> dispose() async {
    if (_localId != null) {
      network._stopAdvertising(_localId!);
    }
    network._stopDiscovery(this);
    await _deviceEvents.close();
    await _connectionEvents.close();
    await _dataEvents.close();
  }
}
