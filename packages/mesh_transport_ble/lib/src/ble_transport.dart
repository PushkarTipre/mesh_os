import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:mesh_core/mesh_core.dart';

/// [Transport] backed by Bluetooth Low Energy (ARCHITECTURE.md §11, §7).
/// A thin platform-adapter -- it carries bytes and reports
/// connection-lifecycle events, nothing more; the handshake/crypto logic
/// lives in `mesh_core`'s `MeshLink`, transport-agnostic. Covers devices
/// without Google Play services (where `mesh_transport_nearby` doesn't
/// work at all) and pre-builds the interop path for when iOS support
/// returns.
///
/// Every MeshOS node runs both BLE roles at once -- a peripheral (GATT
/// server) advertising and accepting incoming connections, and a central
/// (GATT client) scanning for and connecting to others -- since every
/// node is an equal peer, same design principle as `NearbyTransport`.
/// One GATT service, two characteristics: centrals *write* to
/// [_dataInUuid] to send us data, and we *notify* [_dataOutUuid] to send
/// data to a central that's subscribed to it. A node talking to a peer
/// uses whichever role applies -- write+notify-subscribe if it connected
/// out as a central, notify if the peer connected in to it as a
/// peripheral.
///
/// **Known limitation:** [maxPayloadSize] is a fixed, conservative floor
/// (the un-negotiated default ATT MTU), not the actual negotiated value
/// per connection -- [Transport.maxPayloadSize] is a single
/// connection-agnostic property, so this transport can't plumb a
/// per-peer negotiated MTU back into `MeshLink`'s fragmentation sizing
/// without a broader interface change. `requestMTU` is still attempted
/// opportunistically after connecting (better real throughput when it
/// succeeds), but correctness never depends on it succeeding -- every
/// send still fragments down to the safe floor. See ARCHITECTURE.md §7.
///
/// Untestable without real Android hardware, same caveat as
/// `NearbyTransport` -- BLE peripheral-mode GATT servers have no
/// emulator support, and the `CentralManager`/`PeripheralManager`
/// factories throw outside a real platform-channel-registered app.
/// Everything it delegates to (`MeshLink`, `MeshPacket`, `NodeIdentity`,
/// `MultiTransport`) is already covered by `mesh_core`'s test suite
/// against fake transports.
class BleTransport implements Transport {
  BleTransport() {
    _subscriptions.addAll([
      _central.discovered.listen(_onDiscovered),
      _central.connectionStateChanged.listen(_onCentralConnectionStateChanged),
      _central.characteristicNotified.listen(_onCharacteristicNotified),
      _peripheral.connectionStateChanged.listen(_onPeripheralConnectionStateChanged),
      _peripheral.characteristicWriteRequested.listen(_onCharacteristicWriteRequested),
      _peripheral.characteristicReadRequested.listen(_onCharacteristicReadRequested),
    ]);
  }

  // "mesh" / "os" spelled out in the first two hex groups purely as a
  // memorable, low-collision-risk namespace -- not registered with the
  // Bluetooth SIG (we're not a member), so this must be a full 128-bit
  // UUID rather than a short one.
  static final UUID _serviceUuid = UUID.fromString('6d657368-6f73-0001-0000-000000000000');
  static final UUID _dataInUuid = UUID.fromString('6d657368-6f73-0001-0000-000000000001');
  static final UUID _dataOutUuid = UUID.fromString('6d657368-6f73-0001-0000-000000000002');

  /// BLE's default (un-negotiated) ATT MTU is 23 bytes, leaving 20 usable
  /// after the 3-byte ATT header -- see this class's "Known limitation".
  static const int _defaultMaxPayloadSize = 20;

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  final GATTCharacteristic _localDataIn = GATTCharacteristic.mutable(
    uuid: _dataInUuid,
    properties: const [
      GATTCharacteristicProperty.write,
      GATTCharacteristicProperty.writeWithoutResponse,
    ],
    permissions: const [GATTCharacteristicPermission.write],
    descriptors: const [],
  );
  final GATTCharacteristic _localDataOut = GATTCharacteristic.mutable(
    uuid: _dataOutUuid,
    properties: const [GATTCharacteristicProperty.notify],
    permissions: const [GATTCharacteristicPermission.read],
    descriptors: const [],
  );

  @override
  String get name => 'ble';

  @override
  int get maxPayloadSize => _defaultMaxPayloadSize;

  final StreamController<DeviceEvent> _deviceEvents = StreamController.broadcast();
  final StreamController<ConnectionEvent> _connectionEvents = StreamController.broadcast();
  final StreamController<DataEvent> _dataEvents = StreamController.broadcast();

  @override
  Stream<DeviceEvent> get deviceEvents => _deviceEvents.stream;
  @override
  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override
  Stream<DataEvent> get dataEvents => _dataEvents.stream;

  // --- Central role: peers we discover by scanning and connect out to ---

  final Map<String, Peripheral> _discoveredPeripherals = {};
  final Map<String, ({Peripheral peripheral, GATTCharacteristic dataIn, GATTCharacteristic dataOut})>
      _centralLinks = {};

  // --- Peripheral role: centrals that connect in to us ---

  final Map<String, Central> _pendingCentrals = {}; // connected at the radio level, awaiting respondToConnectionRequest
  final Map<String, Central> _connectedCentrals = {}; // accepted

  @override
  Future<void> startAdvertising({required String localId}) async {
    final service = GATTService(
      uuid: _serviceUuid,
      isPrimary: true,
      includedServices: const [],
      characteristics: [_localDataIn, _localDataOut],
    );
    await _peripheral.removeAllServices();
    await _peripheral.addService(service);
    await _peripheral.startAdvertising(
      Advertisement(name: localId, serviceUUIDs: [_serviceUuid]),
    );
  }

  @override
  Future<void> stopAdvertising() => _peripheral.stopAdvertising();

  @override
  Future<void> startDiscovery({required String localId}) =>
      _central.startDiscovery(serviceUUIDs: [_serviceUuid]);

  @override
  Future<void> stopDiscovery() => _central.stopDiscovery();

  void _onDiscovered(DiscoveredEventArgs event) {
    final remoteId = event.peripheral.uuid.toString();
    _discoveredPeripherals[remoteId] = event.peripheral;
    _deviceEvents.add(DeviceEvent(
      remoteId: remoteId,
      type: DeviceEventType.found,
      advertisedName: event.advertisement.name,
    ));
    // BLE scanning has no distinct "lost" signal comparable to Nearby's --
    // a peripheral simply stops showing up in scan results. Surfacing
    // that reliably (vs. just going quiet while still connected) isn't
    // attempted here; MeshOS's own reconnect-on-next-discovery logic
    // tolerates a stale "found" entry that never reconnects.
  }

  @override
  Future<void> connect(String remoteId) async {
    final peripheral = _discoveredPeripherals[remoteId];
    if (peripheral == null) {
      _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.failed));
      return;
    }
    await _central.connect(peripheral);
  }

  Future<void> _onCentralConnectionStateChanged(
    PeripheralConnectionStateChangedEventArgs event,
  ) async {
    final remoteId = event.peripheral.uuid.toString();
    if (event.state != ConnectionState.connected) {
      final wasLinked = _centralLinks.remove(remoteId) != null;
      _connectionEvents.add(ConnectionEvent(
        remoteId: remoteId,
        // A disconnect for a peer we never finished linking (GATT
        // discovery still in flight, or never got there) reads as a
        // failed connection attempt rather than a mid-session drop.
        type: wasLinked ? ConnectionEventType.disconnected : ConnectionEventType.failed,
      ));
      return;
    }

    try {
      final services = await _central.discoverGATT(event.peripheral);
      final service = services.firstWhere((s) => s.uuid == _serviceUuid);
      final dataIn = service.characteristics.firstWhere((c) => c.uuid == _dataInUuid);
      final dataOut = service.characteristics.firstWhere((c) => c.uuid == _dataOutUuid);
      await _central.setCharacteristicNotifyState(event.peripheral, dataOut, state: true);
      try {
        // Best-effort -- see this class's "Known limitation" doc.
        await _central.requestMTU(event.peripheral, mtu: 517);
      } catch (_) {
        // Not fatal: sends still work at the conservative default size.
      }
      _centralLinks[remoteId] = (peripheral: event.peripheral, dataIn: dataIn, dataOut: dataOut);
      _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.connected));
    } catch (_) {
      // Not a real MeshOS GATT service, or discovery/setup failed --
      // don't leave a half-open link around. Best-effort: the peripheral
      // may already be gone/disconnected at the radio level by now (e.g.
      // status-22-style native errors from the underlying stack), which
      // isn't a condition this transport needs to surface -- we already
      // report the connection attempt itself as failed below.
      unawaited(_central.disconnect(event.peripheral).catchError((_) {}));
      _connectionEvents.add(ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.failed));
    }
  }

  void _onCharacteristicNotified(GATTCharacteristicNotifiedEventArgs event) {
    if (event.characteristic.uuid != _dataOutUuid) return;
    _dataEvents.add(DataEvent(remoteId: event.peripheral.uuid.toString(), data: event.value));
  }

  void _onPeripheralConnectionStateChanged(CentralConnectionStateChangedEventArgs event) {
    final remoteId = event.central.uuid.toString();
    if (event.state == ConnectionState.connected) {
      _pendingCentrals[remoteId] = event.central;
      _connectionEvents.add(
        ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.incomingRequest),
      );
      return;
    }

    _pendingCentrals.remove(remoteId);
    final wasConnected = _connectedCentrals.remove(remoteId) != null;
    // A central that drops before we ever accepted it (still pending)
    // doesn't need an event -- we never told the app about it as
    // anything but a request in progress.
    if (wasConnected) {
      _connectionEvents.add(
        ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.disconnected),
      );
    }
  }

  @override
  Future<void> respondToConnectionRequest(String remoteId, {required bool accept}) async {
    final central = _pendingCentrals.remove(remoteId);
    if (central == null) return;
    if (accept) {
      _connectedCentrals[remoteId] = central;
      _connectionEvents.add(
        ConnectionEvent(remoteId: remoteId, type: ConnectionEventType.connected),
      );
    } else {
      // BLE's peripheral role has no application-level "reject before
      // the radio link forms" the way Nearby does -- the connection
      // already physically exists by the time we're asked. The closest
      // equivalent is disconnecting it immediately.
      await _peripheral.disconnect(central);
    }
  }

  void _onCharacteristicWriteRequested(GATTCharacteristicWriteRequestedEventArgs event) {
    if (event.characteristic.uuid == _dataInUuid) {
      _dataEvents.add(
        DataEvent(remoteId: event.central.uuid.toString(), data: event.request.value),
      );
    }
    unawaited(_peripheral.respondWriteRequest(event.request).catchError((_) {}));
  }

  void _onCharacteristicReadRequested(GATTCharacteristicReadRequestedEventArgs event) {
    // We don't serve real readable data -- _dataOut's `read` permission
    // exists only for GATT stacks that expect it on a notify
    // characteristic. Answer defensively so a stray read request never
    // leaves a central's GATT operation queue hanging.
    unawaited(
      _peripheral.respondReadRequestWithValue(event.request, value: Uint8List(0)).catchError((_) {}),
    );
  }

  @override
  Future<void> send(String remoteId, Uint8List data) async {
    final centralLink = _centralLinks[remoteId];
    if (centralLink != null) {
      await _central.writeCharacteristic(
        centralLink.peripheral,
        centralLink.dataIn,
        value: data,
        type: GATTCharacteristicWriteType.withResponse,
      );
      return;
    }
    final central = _connectedCentrals[remoteId];
    if (central != null) {
      await _peripheral.notifyCharacteristic(central, _localDataOut, value: data);
      return;
    }
    throw StateError('BleTransport: not connected to $remoteId');
  }

  @override
  Future<void> disconnect(String remoteId) async {
    final centralLink = _centralLinks[remoteId];
    if (centralLink != null) {
      await _central.disconnect(centralLink.peripheral);
      return;
    }
    final central = _connectedCentrals[remoteId] ?? _pendingCentrals[remoteId];
    if (central != null) {
      await _peripheral.disconnect(central);
    }
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await stopAdvertising();
    await stopDiscovery();
    for (final link in _centralLinks.values.toList()) {
      await _central.disconnect(link.peripheral);
    }
    for (final central in _connectedCentrals.values.toList()) {
      await _peripheral.disconnect(central);
    }
    await _deviceEvents.close();
    await _connectionEvents.close();
    await _dataEvents.close();
  }
}
