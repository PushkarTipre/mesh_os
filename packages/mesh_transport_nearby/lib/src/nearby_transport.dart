import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// [Transport] backed by Google Nearby Connections (ARCHITECTURE.md §11).
/// A thin platform-channel adapter -- it carries bytes and reports
/// connection-lifecycle events, nothing more; the handshake/crypto logic
/// lives in `mesh_core`'s `MeshLink`, transport-agnostic.
///
/// Every MeshOS node both advertises and discovers at once, since every
/// node is an equal peer. The plugin keeps separate callback slots
/// per role (advertiser vs discoverer) internally, so registering both
/// doesn't conflict -- both route into the same unified event streams
/// here, keyed by Nearby's `endpointId`.
///
/// [serviceId] scopes discovery to other MeshOS nodes only; devices
/// running unrelated apps that also use Nearby Connections won't appear.
///
/// Untestable without real Android hardware -- Nearby Connections has no
/// emulator support. Kept deliberately thin so this is the *only*
/// untested surface; everything it delegates to (`MeshLink`, `MeshPacket`,
/// `NodeIdentity`) is already covered by `mesh_core`'s test suite against
/// a fake `Transport`.
class NearbyTransport implements Transport {
  NearbyTransport({
    this.serviceId = 'org.meshos.mesh_os',
    this.strategy = Strategy.P2P_CLUSTER,
  });

  final String serviceId;
  final Strategy strategy;
  final Nearby _nearby = Nearby();

  @override
  String get name => 'nearby';

  @override
  // Nearby Connections doesn't document a hard ceiling for BYTES payloads
  // (it can upgrade the underlying link to Wi-Fi for bandwidth), but this
  // stays conservative -- see ARCHITECTURE.md §11 -- so fragmentation
  // kicks in defensively rather than a send failing outright. Revisit
  // once real-device testing gives a better number.
  int get maxPayloadSize => 32000;

  final StreamController<DeviceEvent> _deviceEvents = StreamController.broadcast();
  final StreamController<ConnectionEvent> _connectionEvents = StreamController.broadcast();
  final StreamController<DataEvent> _dataEvents = StreamController.broadcast();

  @override
  Stream<DeviceEvent> get deviceEvents => _deviceEvents.stream;
  @override
  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override
  Stream<DataEvent> get dataEvents => _dataEvents.stream;

  @override
  Future<void> startAdvertising({required String localId}) async {
    await _nearby.startAdvertising(
      localId,
      strategy,
      serviceId: serviceId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  @override
  Future<void> stopAdvertising() => _nearby.stopAdvertising();

  @override
  Future<void> startDiscovery({required String localId}) async {
    await _nearby.startDiscovery(
      localId,
      strategy,
      serviceId: serviceId,
      onEndpointFound: (id, name, foundServiceId) {
        _deviceEvents.add(
          DeviceEvent(remoteId: id, type: DeviceEventType.found, advertisedName: name),
        );
      },
      onEndpointLost: (id) {
        if (id == null) return;
        _deviceEvents.add(DeviceEvent(remoteId: id, type: DeviceEventType.lost));
      },
    );
  }

  @override
  Future<void> stopDiscovery() => _nearby.stopDiscovery();

  @override
  Future<void> connect(String remoteId) async {
    // The plugin's userNickName param here just labels this request on
    // the wire; MeshOS's actual identity travels in the discovery
    // handshake payload (MeshLink), so a fixed placeholder is fine.
    await _nearby.requestConnection(
      'mesh_os',
      remoteId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    _connectionEvents.add(
      ConnectionEvent(remoteId: endpointId, type: ConnectionEventType.incomingRequest),
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    switch (status) {
      case Status.CONNECTED:
        _connectionEvents.add(
          ConnectionEvent(remoteId: endpointId, type: ConnectionEventType.connected),
        );
      case Status.REJECTED:
      case Status.ERROR:
        _connectionEvents.add(
          ConnectionEvent(remoteId: endpointId, type: ConnectionEventType.failed),
        );
    }
  }

  void _onDisconnected(String endpointId) {
    _connectionEvents.add(
      ConnectionEvent(remoteId: endpointId, type: ConnectionEventType.disconnected),
    );
  }

  @override
  Future<void> respondToConnectionRequest(String remoteId, {required bool accept}) async {
    if (accept) {
      await _nearby.acceptConnection(remoteId, onPayLoadRecieved: _onPayloadReceived);
    } else {
      await _nearby.rejectConnection(remoteId);
    }
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    final bytes = payload.bytes;
    if (payload.type != PayloadType.BYTES || bytes == null) return;
    _dataEvents.add(DataEvent(remoteId: endpointId, data: bytes));
  }

  @override
  Future<void> send(String remoteId, Uint8List data) => _nearby.sendBytesPayload(remoteId, data);

  @override
  Future<void> disconnect(String remoteId) => _nearby.disconnectFromEndpoint(remoteId);

  @override
  Future<void> dispose() async {
    await _nearby.stopAllEndpoints();
    await _deviceEvents.close();
    await _connectionEvents.close();
    await _dataEvents.close();
  }
}
