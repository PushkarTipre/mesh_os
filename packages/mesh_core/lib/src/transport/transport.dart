import 'dart:typed_data';

/// A discovered peer became visible or went out of range.
enum DeviceEventType { found, lost }

class DeviceEvent {
  const DeviceEvent({required this.remoteId, required this.type, this.advertisedName});

  /// The connection-addressable identifier -- pass this to [Transport.connect].
  /// Ephemeral and assigned by the transport (e.g. Nearby's `endpointId`),
  /// distinct from [advertisedName].
  final String remoteId;

  final DeviceEventType type;

  /// The peer's self-advertised name at discovery time -- MeshOS puts its
  /// rotating `TemporaryId` here, never a permanent identifier. Null for
  /// a [DeviceEventType.lost] event, where only [remoteId] is meaningful.
  final String? advertisedName;

  @override
  String toString() => 'DeviceEvent($type, $remoteId, $advertisedName)';
}

/// A connection to a peer (identified by `remoteId` on [ConnectionEvent])
/// changed state.
enum ConnectionEventType {
  /// A peer wants to connect and is waiting for us to accept/reject.
  incomingRequest,
  connected,
  disconnected,

  /// A connection attempt (ours or theirs) did not succeed.
  failed,
}

class ConnectionEvent {
  const ConnectionEvent({required this.remoteId, required this.type});

  final String remoteId;
  final ConnectionEventType type;

  @override
  String toString() => 'ConnectionEvent($type, $remoteId)';
}

class DataEvent {
  const DataEvent({required this.remoteId, required this.data});

  final String remoteId;
  final Uint8List data;
}

/// A radio transport MeshOS can carry packets over. Deliberately narrow --
/// advertise/discover/connect/send/receive -- so both Nearby Connections
/// (CP3) and BLE (CP8, for devices without Google Play services and for
/// eventual iOS interop) can implement it, and so higher layers (session
/// handshake, routing) never need to know which one they're talking to.
///
/// Implementations are dumb wrappers around a platform API: they carry
/// bytes and report connection-lifecycle events, nothing more. Anything
/// resembling protocol logic (key exchange, packet encoding, dedup,
/// routing) belongs one layer up, transport-agnostic, so it can be unit
/// tested against [Transport] without touching real hardware.
abstract class Transport {
  /// Short name for logs/debugging, e.g. "nearby", "ble".
  String get name;

  /// Largest single message this transport can carry before the caller
  /// must fragment it (see `Fragmenter`).
  int get maxPayloadSize;

  /// Makes this node discoverable as [localId] to nearby peers running
  /// [startDiscovery]. MeshOS advertises the rotating `TemporaryId`, never
  /// the permanent Node ID.
  Future<void> startAdvertising({required String localId});
  Future<void> stopAdvertising();

  /// Starts scanning for nearby advertising peers. Findings arrive on
  /// [deviceEvents].
  Future<void> startDiscovery({required String localId});
  Future<void> stopDiscovery();

  Stream<DeviceEvent> get deviceEvents;

  /// Requests a connection to a peer discovered via [deviceEvents].
  Future<void> connect(String remoteId);

  /// Accepts or rejects an incoming connection request reported via
  /// [connectionEvents] as [ConnectionEventType.incomingRequest].
  Future<void> respondToConnectionRequest(String remoteId, {required bool accept});

  Future<void> disconnect(String remoteId);

  Stream<ConnectionEvent> get connectionEvents;

  /// Sends raw bytes to a connected peer. Must be at most
  /// [maxPayloadSize] bytes -- fragment first if not.
  Future<void> send(String remoteId, Uint8List data);

  Stream<DataEvent> get dataEvents;

  /// Releases any underlying platform resources. A disposed transport
  /// must not be used again.
  Future<void> dispose();
}
