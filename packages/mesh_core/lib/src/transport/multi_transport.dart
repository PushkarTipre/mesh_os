import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

class _PeerLink {
  _PeerLink(this.syntheticId);

  final String syntheticId;

  /// Every transport this peer has been discovered/connected on, mapped
  /// to that transport's own local remoteId for it.
  final Map<Transport, String> candidates = {};

  /// Which transport the live connection (if any) actually runs over.
  /// Set tentatively the moment we attempt an outbound [Transport.connect]
  /// or see an inbound [ConnectionEventType.incomingRequest], confirmed
  /// once [ConnectionEventType.connected] actually arrives.
  Transport? activeTransport;

  bool connected = false;
}

/// Runs several [Transport]s side by side behind a single [Transport]
/// interface (Checkpoint 8, ARCHITECTURE.md §7) -- `MeshLink`/`MeshOS`
/// never need to know more than one radio exists. Advertising/discovery
/// fan out to every underlying transport; a peer found on more than one
/// is presented upward as a single logical device, correlated by its
/// advertised name (MeshOS's rotating `TemporaryId` -- the same string
/// every transport was told to advertise via `localId`, so it's a
/// reliable, already-available correlation key with no extra protocol
/// needed). [connect] picks the *first* transport (by constructor order)
/// that has a discovered path to the peer, so callers pass transports
/// most-preferred first (e.g. Nearby before BLE, for bandwidth).
///
/// **What this class deliberately does not attempt:** dynamically
/// switching a peer's active transport mid-session (e.g. upgrading from
/// BLE to Nearby if Nearby becomes available later), or resolving a race
/// where two transports both reach "connected" for the same peer at
/// nearly the same time (the second one to confirm silently loses --
/// [connect] having already committed to the first available candidate
/// makes this rare in practice, but not impossible). Both are reasonable
/// v2 refinements once real hardware testing shows they matter -- see
/// ROADMAP.md Checkpoint 8's staged-routing precedent in §7.
///
/// A peer we learn about only via an inbound connection (never our own
/// `deviceEvents.found` on that transport -- e.g. they connected to us
/// before we finished scanning) has no advertised name to correlate by;
/// it's surfaced with a transport-namespaced fallback id
/// (`"<transport.name>:<remoteId>"`) instead. This means it *won't* be
/// merged with a separate sighting of the same physical node on another
/// transport -- an accepted imperfection, since true peer identity is
/// established one layer up by `MeshLink`'s discovery handshake
/// (`PeerSession.nodeId`), not by transport-level remoteId matching.
///
/// Fully unit-testable against any [Transport] implementation, including
/// two or more `FakeTransport`s standing in for "Nearby" and "BLE" --
/// unlike [BleTransport]/`NearbyTransport` themselves, none of this
/// selection/merging logic touches real hardware.
class MultiTransport implements Transport {
  MultiTransport(this.transports) {
    assert(transports.isNotEmpty, 'MultiTransport needs at least one underlying transport');
    for (final transport in transports) {
      _subscriptions.addAll([
        transport.deviceEvents.listen((event) => _onDeviceEvent(transport, event)),
        transport.connectionEvents.listen((event) => _onConnectionEvent(transport, event)),
        transport.dataEvents.listen((event) => _onDataEvent(transport, event)),
      ]);
    }
  }

  /// Ordered by preference -- [connect] tries each transport in this
  /// order and uses the first one with a discovered path to the peer.
  final List<Transport> transports;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Map<String, _PeerLink> _peers = {};

  /// transport -> (that transport's local remoteId -> our synthetic remoteId)
  final Map<Transport, Map<String, String>> _reverseLookup = {};

  final StreamController<DeviceEvent> _deviceEvents = StreamController.broadcast();
  final StreamController<ConnectionEvent> _connectionEvents = StreamController.broadcast();
  final StreamController<DataEvent> _dataEvents = StreamController.broadcast();

  @override
  String get name => transports.map((t) => t.name).join('+');

  /// The most conservative (smallest) ceiling across every underlying
  /// transport -- correct for any of them, at the cost of not letting a
  /// higher-bandwidth transport (e.g. Nearby) use its full capacity per
  /// send. [Transport.maxPayloadSize] is a single connection-agnostic
  /// property, so there's no per-peer alternative without a broader
  /// interface change; existing fragmentation (`Fragmenter`, Checkpoint 2)
  /// already handles chunking down to this size correctly, just not
  /// maximally efficiently. Known, documented v1 trade-off.
  @override
  int get maxPayloadSize => transports.map((t) => t.maxPayloadSize).reduce((a, b) => a < b ? a : b);

  @override
  Stream<DeviceEvent> get deviceEvents => _deviceEvents.stream;
  @override
  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override
  Stream<DataEvent> get dataEvents => _dataEvents.stream;

  @override
  Future<void> startAdvertising({required String localId}) =>
      _forEachTransport((t) => t.startAdvertising(localId: localId));

  @override
  Future<void> stopAdvertising() => _forEachTransport((t) => t.stopAdvertising());

  @override
  Future<void> startDiscovery({required String localId}) =>
      _forEachTransport((t) => t.startDiscovery(localId: localId));

  @override
  Future<void> stopDiscovery() => _forEachTransport((t) => t.stopDiscovery());

  /// Runs [action] on every underlying transport, tolerating any one of
  /// them failing (e.g. BLE unsupported on this device, Nearby disabled)
  /// -- the whole point of running them side by side is that the others
  /// keep working regardless.
  Future<void> _forEachTransport(Future<void> Function(Transport) action) async {
    await Future.wait(transports.map((t) async {
      try {
        await action(t);
      } catch (_) {
        // Intentionally swallowed -- see doc comment above.
      }
    }));
  }

  void _onDeviceEvent(Transport transport, DeviceEvent event) {
    switch (event.type) {
      case DeviceEventType.found:
        _onFound(transport, event);
      case DeviceEventType.lost:
        _onLost(transport, event);
    }
  }

  void _onFound(Transport transport, DeviceEvent event) {
    final advertisedName = event.advertisedName;
    final syntheticId = advertisedName ?? '${transport.name}:${event.remoteId}';

    final isBrandNewPeer = !_peers.containsKey(syntheticId);
    final link = _peers.putIfAbsent(syntheticId, () => _PeerLink(syntheticId));
    link.candidates[transport] = event.remoteId;
    (_reverseLookup[transport] ??= {})[event.remoteId] = syntheticId;

    if (isBrandNewPeer) {
      _deviceEvents.add(DeviceEvent(
        remoteId: syntheticId,
        type: DeviceEventType.found,
        advertisedName: advertisedName,
      ));
    }
  }

  void _onLost(Transport transport, DeviceEvent event) {
    final syntheticId = _reverseLookup[transport]?.remove(event.remoteId);
    if (syntheticId == null) return; // never tracked via a `found` on this transport

    final link = _peers[syntheticId];
    if (link == null) return;
    link.candidates.remove(transport);

    // Still reachable via another transport, or actively connected right
    // now (a connected peer can drop out of scan results without
    // actually disconnecting) -- don't surface `lost` in either case.
    if (link.candidates.isNotEmpty || link.connected) return;

    _peers.remove(syntheticId);
    _deviceEvents.add(DeviceEvent(remoteId: syntheticId, type: DeviceEventType.lost));
  }

  @override
  Future<void> connect(String remoteId) async {
    final link = _peers[remoteId];
    if (link == null) {
      _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.failed));
      return;
    }
    for (final transport in transports) {
      final localRemoteId = link.candidates[transport];
      if (localRemoteId == null) continue;
      link.activeTransport = transport;
      await transport.connect(localRemoteId);
      return;
    }
    _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.failed));
  }

  void _onConnectionEvent(Transport transport, ConnectionEvent event) {
    switch (event.type) {
      case ConnectionEventType.incomingRequest:
        _onIncomingRequest(transport, event);
      case ConnectionEventType.connected:
        _onConnected(transport, event);
      case ConnectionEventType.disconnected:
      case ConnectionEventType.failed:
        _onDisconnectedOrFailed(transport, event);
    }
  }

  /// Resolves [localRemoteId] on [transport] to our synthetic remoteId,
  /// reusing one already assigned via a prior `found` if there is one,
  /// otherwise minting the transport-namespaced fallback (see class doc).
  String _resolveSynthetic(Transport transport, String localRemoteId) {
    final existing = _reverseLookup[transport]?[localRemoteId];
    if (existing != null) return existing;

    final syntheticId = '${transport.name}:$localRemoteId';
    final link = _peers.putIfAbsent(syntheticId, () => _PeerLink(syntheticId));
    link.candidates[transport] = localRemoteId;
    (_reverseLookup[transport] ??= {})[localRemoteId] = syntheticId;
    return syntheticId;
  }

  void _onIncomingRequest(Transport transport, ConnectionEvent event) {
    final syntheticId = _resolveSynthetic(transport, event.remoteId);
    _peers[syntheticId]!.activeTransport = transport;
    _connectionEvents.add(
      ConnectionEvent(remoteId: syntheticId, type: ConnectionEventType.incomingRequest),
    );
  }

  void _onConnected(Transport transport, ConnectionEvent event) {
    final syntheticId = _resolveSynthetic(transport, event.remoteId);
    final link = _peers[syntheticId]!;
    link.activeTransport = transport;
    link.connected = true;
    _connectionEvents.add(ConnectionEvent(remoteId: syntheticId, type: ConnectionEventType.connected));
  }

  void _onDisconnectedOrFailed(Transport transport, ConnectionEvent event) {
    final syntheticId = _reverseLookup[transport]?[event.remoteId];
    if (syntheticId == null) return;
    final link = _peers[syntheticId];
    // A stale event for a transport that isn't (or is no longer) this
    // peer's active link -- e.g. an outbound attempt on transport A that
    // resolves after an inbound request on transport B already took
    // over (see class doc's noted race).
    if (link == null || link.activeTransport != transport) return;

    link.connected = false;
    link.activeTransport = null;
    _connectionEvents.add(ConnectionEvent(remoteId: syntheticId, type: event.type));

    if (link.candidates.isEmpty) {
      _peers.remove(syntheticId);
    }
  }

  @override
  Future<void> respondToConnectionRequest(String remoteId, {required bool accept}) async {
    final link = _peers[remoteId];
    final transport = link?.activeTransport;
    final localRemoteId = transport == null ? null : link?.candidates[transport];
    if (transport == null || localRemoteId == null) return;
    await transport.respondToConnectionRequest(localRemoteId, accept: accept);
  }

  @override
  Future<void> disconnect(String remoteId) async {
    final link = _peers[remoteId];
    final transport = link?.activeTransport;
    final localRemoteId = transport == null ? null : link?.candidates[transport];
    if (transport == null || localRemoteId == null) return;
    await transport.disconnect(localRemoteId);
  }

  void _onDataEvent(Transport transport, DataEvent event) {
    final syntheticId = _reverseLookup[transport]?[event.remoteId];
    if (syntheticId == null) return; // a connection always assigns one first
    _dataEvents.add(DataEvent(remoteId: syntheticId, data: event.data));
  }

  @override
  Future<void> send(String remoteId, Uint8List data) async {
    final link = _peers[remoteId];
    final transport = link?.activeTransport;
    if (link == null || transport == null || !link.connected) {
      throw StateError('MultiTransport: not connected to $remoteId');
    }
    final localRemoteId = link.candidates[transport];
    if (localRemoteId == null) {
      throw StateError('MultiTransport: no active path to $remoteId');
    }
    await transport.send(localRemoteId, data);
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    // Best-effort per transport, same as _forEachTransport -- one
    // transport failing to tear down cleanly shouldn't leave the others
    // (or this composite's own streams) leaked.
    for (final transport in transports) {
      try {
        await transport.dispose();
      } catch (_) {
        // Intentionally swallowed.
      }
    }
    await _deviceEvents.close();
    await _connectionEvents.close();
    await _dataEvents.close();
  }
}
