import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_transport_ble/mesh_transport_ble.dart';
import 'package:mesh_transport_nearby/mesh_transport_nearby.dart';

import 'mesh_device.dart';
import 'secure_storage_identity_store.dart';
import 'storage/drift_trust_store.dart';

/// The MeshOS public API (ARCHITECTURE.md §19): the facade a host app
/// builds on, so it never has to touch Bluetooth/Nearby, packet framing,
/// or crypto directly.
///
/// ```dart
/// final mesh = MeshOS();
/// await mesh.initialize();
/// await mesh.start();
///
/// await mesh.send(destination: nodeId, payload: bytes);
/// mesh.messages.listen((msg) => ...);
///
/// await mesh.trust(nodeId);
/// await mesh.block(nodeId);
/// ```
///
/// Wraps `mesh_core`'s [MeshLink] (handshake, crypto, reliability, trust
/// enforcement, multi-hop routing) rather than reimplementing anything --
/// this class is glue, not logic. As of Checkpoint 8, [start] runs two
/// transports side by side behind `mesh_core`'s [MultiTransport]:
/// `mesh_transport_nearby`'s [NearbyTransport] (preferred, for bandwidth)
/// and `mesh_transport_ble`'s [BleTransport] (fallback -- reaches devices
/// without Google Play services, and pre-builds the Android<->iOS interop
/// path for when iOS support returns). Every discovered MeshOS peer is
/// connected to automatically, and every incoming connection request is
/// auto-accepted; gating *whether to connect at all* behind trust/relay
/// policy is a later checkpoint (ARCHITECTURE.md §5, §18), not yet
/// implemented. What's gated today: once connected, a [TrustLevel.blocked]
/// peer is refused a session (or dropped from one); only
/// [TrustLevel.trusted] peers ever have a [MeshDevice.displayName]; and
/// [send] transparently routes through relays (flooding + store-and-forward,
/// Checkpoint 6) when the destination isn't a direct neighbor, so callers
/// never need to know how many hops a message takes.
class MeshOS {
  MeshOS({IdentityStore? identityStore, TrustStore? trustStore})
      : _identityStore = identityStore ?? SecureStorageIdentityStore(),
        _trustStore = trustStore ?? DriftTrustStore();

  final IdentityStore _identityStore;
  final TrustStore _trustStore;

  NodeIdentity? _identity;
  Transport? _transport;
  MeshLink? _link;
  FileTransferManager? _fileTransfers;
  bool _started = false;

  final Map<String, MeshDevice> _devices = {};
  final Set<String> _connectAttempted = {};

  final StreamController<List<MeshDevice>> _devicesController =
      StreamController<List<MeshDevice>>.broadcast();
  final StreamController<InboundMessage> _messagesController =
      StreamController<InboundMessage>.broadcast();

  StreamSubscription<DeviceEvent>? _deviceSub;
  StreamSubscription<ConnectionEvent>? _connectionSub;
  StreamSubscription<String>? _sessionSub;
  StreamSubscription<InboundMessage>? _messageSub;
  StreamSubscription<List<Contact>>? _contactSub;

  final StreamController<String> _diagnostics = StreamController<String>.broadcast();

  void _diag(String message) => _diagnostics.add(message);

  /// This node's permanent, stable identity. Only valid after [initialize].
  NodeIdentity get identity {
    final id = _identity;
    if (id == null) {
      throw StateError('MeshOS: call initialize() before using this getter');
    }
    return id;
  }

  /// Currently known nearby/connected devices.
  List<MeshDevice> get devices => List.unmodifiable(_devices.values);

  /// Emits the full device list every time it changes.
  Stream<List<MeshDevice>> get deviceUpdates => _devicesController.stream;

  /// Verified, decrypted incoming messages from any peer -- direct,
  /// routed through relays, or broadcast/published ([InboundMessage.topic]
  /// is non-null for the latter). [InboundMessage.senderNodeId] is always
  /// populated (use it, not [InboundMessage.remoteId], for things like
  /// persisted chat history -- `remoteId` is null for a routed or
  /// broadcast/publish message, since there's no single live connection
  /// to attribute it to). File transfer chunks ([PacketType.file]) never
  /// appear here -- see [incomingFiles] instead.
  Stream<InboundMessage> get messages => _messagesController.stream;

  /// Progress updates for files this device is sending -- see [sendFile].
  Stream<FileTransferProgress> get outgoingFileProgress {
    final transfers = _fileTransfers;
    if (transfers == null) {
      throw StateError('MeshOS: call start() first');
    }
    return transfers.outgoingProgress;
  }

  /// Fully reassembled files received from peers.
  Stream<IncomingFile> get incomingFiles {
    final transfers = _fileTransfers;
    if (transfers == null) {
      throw StateError('MeshOS: call start() first');
    }
    return transfers.incomingFiles;
  }

  /// A snapshot of this node's mesh activity as of right now (packets
  /// sent/received/relayed, bytes moved, active sessions, and packets
  /// currently held in the local store-and-forward cache) -- powers
  /// `mesh_console`'s debug/analytics view (Checkpoint 9). See
  /// [statsUpdates] to be notified as it changes rather than polling.
  MeshLinkStats get stats {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    return link.stats;
  }

  Stream<MeshLinkStats> get statsUpdates {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    return link.statsUpdates;
  }

  /// Coarse, human-readable step-by-step progress messages for [start] --
  /// "requesting Nearby permissions", "BLE permissions granted", "starting
  /// discovery", and so on. Not meant for protocol-level debugging (see
  /// `MeshLink.statsUpdates`/[stats] for that) -- this exists specifically
  /// so a host app can show *where* startup is stuck if it never
  /// completes, since permission dialogs and radio initialization are
  /// exactly the kind of platform-specific step that can hang or fail
  /// silently on some devices without ever throwing a catchable
  /// exception. `mesh_console`'s error-log screen is built entirely on
  /// this stream.
  Stream<String> get diagnostics => _diagnostics.stream;

  /// Every contact this device has ever interacted with, regardless of
  /// whether they're currently nearby (ARCHITECTURE.md §4, §9).
  Future<List<Contact>> get contacts => _trustStore.listContacts();

  /// Emits the full contact list every time trust/profile data changes.
  Stream<List<Contact>> get contactUpdates => _trustStore.watchContacts();

  /// Loads (or generates, on first launch) this device's identity. Call
  /// once before [start].
  Future<void> initialize() async {
    _identity = await NodeIdentity.loadOrCreate(_identityStore);
  }

  /// Starts advertising and discovering over the available transports,
  /// and begins auto-connecting to every MeshOS peer found. Emits
  /// progress on [diagnostics] as it goes; if it throws, the last
  /// diagnostic emitted (with no matching "...done" message after it)
  /// tells you which step failed.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    try {
      // Run both permission requests concurrently rather than one after
      // the other -- Android queues/serializes the actual dialogs at the
      // OS level regardless, so this is safe, and it roughly halves
      // worst-case wall time. Matters in practice: on at least one real
      // device (a OnePlus Nord), BLE's authorize() calls alone take up
      // to 20s to time out (see BlePermissions), and stacking that after
      // Nearby's own multi-permission dialog was enough to make a
      // perfectly-successful startup look, from the host app's
      // perspective, like it was taking unreasonably long.
      _diag('Requesting Nearby + BLE permissions...');
      final granted = await Future.wait([
        NearbyPermissions.requestAll(),
        BlePermissions.requestAll(),
      ]);
      final nearbyGranted = granted[0];
      final bleGranted = granted[1];
      _diag('Nearby permissions: granted=$nearbyGranted');
      _diag('BLE permissions: granted=$bleGranted');

      // Nearby listed first: MultiTransport.connect prefers earlier
      // entries, and Nearby has the higher bandwidth ceiling of the two
      // (ARCHITECTURE.md §11). BLE is what still works on devices without
      // Google Play services, or if Nearby is unavailable for any reason.
      //
      // BleTransport is only included if BLE permissions actually came
      // back granted. Without that, its central-manager scan runs without
      // the OS having authorized it -- observed on at least one real
      // device (a OnePlus Nord) to silently drop its service-UUID filter,
      // surfacing every BLE peripheral in range (headphones, laptops, ...)
      // as if it were a MeshOS peer. `_onDeviceEvent` below auto-connects
      // to everything it sees, so each of those becomes a real GATT
      // connection attempt to a device that was never going to have our
      // service, which fails and disconnects -- churn that can leave the
      // phone's Bluetooth stack unstable for Nearby too, since Nearby's
      // discovery also rides on BLE under the hood. Simplest correct fix:
      // don't drive the radio at all without authorization for it.
      _diag('Constructing transports...');
      final transports = <Transport>[NearbyTransport()];
      if (bleGranted) {
        transports.add(BleTransport());
      } else {
        _diag('BLE not authorized -- running Nearby-only this session');
      }
      final transport = MultiTransport(transports);
      final link = MeshLink(transport: transport, identity: identity, trustStore: _trustStore)
        ..start();
      _transport = transport;
      _link = link;
      _fileTransfers = FileTransferManager(link: link);
      _diag('MeshLink constructed and started');

      _deviceSub = transport.deviceEvents.listen(_onDeviceEvent);
      _connectionSub = transport.connectionEvents.listen(_onConnectionEvent);
      _sessionSub = link.sessionEstablished.listen(_onSessionEstablished);
      // File-transfer chunks are internal plumbing (FileTransferManager
      // already consumed them above) -- an app listening on [messages]
      // wants chat/broadcast traffic, not raw chunk bytes. See
      // [incomingFiles] for reassembled files instead.
      _messageSub = link.messages.listen((message) {
        if (message.isFileChunk) return;
        _messagesController.add(message);
      });
      _contactSub = _trustStore.watchContacts().listen(_onContactsChanged);

      final tempId = await identity.temporaryId();
      _diag('Starting advertising...');
      await transport.startAdvertising(localId: tempId);
      _diag('Advertising started; starting discovery...');
      await transport.startDiscovery(localId: tempId);
      _diag('start() complete');
    } catch (e, stack) {
      _diag('start() failed: $e\n$stack');
      rethrow;
    }
  }

  /// Restarts advertising and discovery on the current transport(s).
  /// A no-op if [start] hasn't completed yet.
  ///
  /// Exists specifically for a host app to call when it returns to the
  /// foreground after being backgrounded. Neither Nearby Connections nor
  /// BLE scanning/advertising reliably keeps running while an app is
  /// backgrounded (most aggressively once the screen is off -- Android
  /// throttles or fully suspends both for apps that aren't foregrounded),
  /// and nothing automatically resumes them just because the app becomes
  /// visible again -- observed on real devices as two phones sitting next
  /// to each other, both freshly resumed from background, showing each
  /// other as "not nearby" indefinitely. `mesh_console`'s `HomeScreen`
  /// calls this from a `WidgetsBindingObserver` on
  /// `AppLifecycleState.resumed`. See NEXT_STEPS.md.
  ///
  /// Also clears the internal "already attempted a connection to this
  /// peer" tracking, so a peer re-found by the fresh discovery below gets
  /// a genuine reconnect attempt even if it was marked as already
  /// attempted before backgrounding suspended everything (and therefore
  /// never got a chance to fire a `disconnected` event to clear that
  /// marker the normal way).
  Future<void> refreshDiscovery() async {
    final transport = _transport;
    if (transport == null) return;
    _diag('Refreshing discovery (app resumed)...');
    try {
      final tempId = await identity.temporaryId();
      await transport.stopDiscovery();
      await transport.stopAdvertising();
      _connectAttempted.clear();
      await transport.startAdvertising(localId: tempId);
      await transport.startDiscovery(localId: tempId);
      _diag('Discovery refreshed');
    } catch (e, stack) {
      _diag('Discovery refresh failed: $e\n$stack');
    }
  }

  void _onDeviceEvent(DeviceEvent event) {
    if (event.type == DeviceEventType.lost) {
      // A connected peer can also drop out of *discovery* results
      // (Nearby stops reporting endpoints it's already connected to)
      // without actually disconnecting -- only forget it here if it was
      // never connected in the first place.
      final existing = _devices[event.remoteId];
      if (existing == null || !existing.connected) {
        _devices.remove(event.remoteId);
        _connectAttempted.remove(event.remoteId);
        _publishDevices();
      }
      return;
    }

    if (!_devices.containsKey(event.remoteId)) {
      _devices[event.remoteId] = MeshDevice(
        remoteId: event.remoteId,
        connected: false,
        sessionReady: false,
      );
      _publishDevices();
    }

    // Attempt a connection exactly once per "not yet connected" streak --
    // Nearby can re-announce an already-attempted endpoint while
    // discovery keeps running.
    if (_connectAttempted.add(event.remoteId)) {
      unawaited(_transport?.connect(event.remoteId));
    }
  }

  Future<void> _onConnectionEvent(ConnectionEvent event) async {
    switch (event.type) {
      case ConnectionEventType.incomingRequest:
        await _transport?.respondToConnectionRequest(event.remoteId, accept: true);
      case ConnectionEventType.connected:
        final existing = _devices[event.remoteId] ??
            MeshDevice(remoteId: event.remoteId, connected: false, sessionReady: false);
        _devices[event.remoteId] = existing.copyWith(connected: true);
        _publishDevices();
      case ConnectionEventType.disconnected:
      case ConnectionEventType.failed:
        _connectAttempted.remove(event.remoteId);
        final existing = _devices[event.remoteId];
        if (existing != null) {
          _devices[event.remoteId] = existing.copyWith(connected: false, sessionReady: false);
          _publishDevices();
        }
    }
  }

  Future<void> _onSessionEstablished(String remoteId) async {
    final link = _link;
    if (link == null) return;
    PeerSession? session;
    for (final candidate in link.sessions) {
      if (candidate.remoteId == remoteId) {
        session = candidate;
        break;
      }
    }
    if (session == null) return;

    final contact = await _trustStore.getContact(session.nodeId);
    final existing = _devices[remoteId] ??
        MeshDevice(remoteId: remoteId, connected: true, sessionReady: false);
    _devices[remoteId] = existing.copyWith(
      nodeId: session.nodeId,
      sessionReady: true,
      trustLevel: contact?.trustLevel ?? TrustLevel.known,
      displayName: contact?.displayName,
    );
    _publishDevices();
  }

  /// Keeps nearby devices' [MeshDevice.trustLevel]/[MeshDevice.displayName]
  /// in sync with trust changes (e.g. a QR exchange or a block) that
  /// happen while they're already connected, without needing a reconnect.
  void _onContactsChanged(List<Contact> contacts) {
    var changed = false;
    for (final contact in contacts) {
      for (final device in _devices.values.toList()) {
        if (device.nodeId != contact.nodeId) continue;
        if (device.trustLevel == contact.trustLevel && device.displayName == contact.displayName) {
          continue;
        }
        _devices[device.remoteId] = device.copyWith(
          trustLevel: contact.trustLevel,
          displayName: contact.displayName,
        );
        changed = true;
      }
    }
    if (changed) _publishDevices();
  }

  void _publishDevices() {
    _devicesController.add(devices);
  }

  /// Sends [payload] to the node with permanent id [destination],
  /// encrypted and signed. Uses a direct session if [destination] is a
  /// currently-connected peer (fast, bounded retry); otherwise routes
  /// through relays -- flooding plus store-and-forward -- as long as
  /// [destination] is a known contact (met before, directly or via a
  /// relay), resolving once the destination's end-to-end ack eventually
  /// arrives. Throws [StateError] if [destination] isn't a known contact
  /// at all, or if they're blocked.
  Future<DeliveryStatus> send({
    required String destination,
    required List<int> payload,
  }) async {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    return link.sendToNode(destination, payload);
  }

  /// Sends [payload] to every reachable node, self-certifying and
  /// unencrypted -- there's no destination to be a known contact of, and
  /// no encryption key to have on file for them. See [MeshLink.broadcast].
  Future<void> broadcast(List<int> payload, {int ttl = 8}) {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    return link.broadcast(payload, ttl: ttl);
  }

  /// Like [broadcast], but tagged with [topic] so only [subscribe]d
  /// listeners surface it on [messages]. See [MeshLink.publish].
  Future<void> publish(String topic, List<int> payload, {int ttl = 8}) {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    return link.publish(topic, payload, ttl: ttl);
  }

  /// Starts surfacing [publish]ed traffic for [topic] on [messages], in
  /// addition to plain broadcasts (always surfaced).
  void subscribe(String topic) {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    link.subscribe(topic);
  }

  void unsubscribe(String topic) {
    final link = _link;
    if (link == null) {
      throw StateError('MeshOS: call start() first');
    }
    link.unsubscribe(topic);
  }

  /// Starts sending [bytes] to [destination] as [filename], chunked and
  /// sent via the same reliable delivery [send] uses. Returns immediately
  /// with a transfer id; track progress via [outgoingFileProgress].
  /// Requires [destination] to already be a known contact, same as
  /// [send].
  String sendFile({
    required String destination,
    required String filename,
    required Uint8List bytes,
    int chunkSize = 16 * 1024,
  }) {
    final transfers = _fileTransfers;
    if (transfers == null) {
      throw StateError('MeshOS: call start() first');
    }
    return transfers.sendFile(
      nodeId: destination,
      filename: filename,
      bytes: bytes,
      chunkSize: chunkSize,
    );
  }

  /// Resolves a live [InboundMessage.remoteId] (or [MeshDevice.remoteId])
  /// to the peer's stable, permanent Node ID -- use this, not remoteId,
  /// as a persistence key (e.g. chat history), since remoteId changes
  /// across reconnects.
  String? nodeIdForRemoteId(String remoteId) => _devices[remoteId]?.nodeId;

  /// Promotes an already-known node to [TrustLevel.trusted], without
  /// setting a display name. Most apps will use [trustFromIdentityCard]
  /// instead, which also exchanges a name; this is the bare API from
  /// ARCHITECTURE.md §19. Throws [StateError] if this device has never
  /// connected to [nodeId] before (so there's no public key on file).
  Future<void> trust(String nodeId) async {
    final existing = await _trustStore.getContact(nodeId);
    if (existing == null) {
      throw StateError('MeshOS: no known contact with node $nodeId yet');
    }
    await _trustStore.upsertContact(existing.copyWith(trustLevel: TrustLevel.trusted));
  }

  /// Blocks [nodeId]: refuses any future session with them and, if
  /// they're currently connected, disconnects immediately. Throws
  /// [StateError] if this device has never connected to [nodeId] before.
  Future<void> block(String nodeId) async {
    final existing = await _trustStore.getContact(nodeId);
    if (existing == null) {
      throw StateError('MeshOS: no known contact with node $nodeId yet');
    }
    await _trustStore.upsertContact(existing.copyWith(trustLevel: TrustLevel.blocked));

    for (final device in _devices.values) {
      if (device.nodeId == nodeId) {
        await _transport?.disconnect(device.remoteId);
      }
    }
  }

  /// Reverts a blocked contact back to [TrustLevel.known]. No-op if
  /// [nodeId] isn't a known contact at all.
  Future<void> unblock(String nodeId) async {
    final existing = await _trustStore.getContact(nodeId);
    if (existing == null) return;
    await _trustStore.upsertContact(existing.copyWith(trustLevel: TrustLevel.known));
  }

  /// Builds this device's shareable identity card for the "Becoming
  /// Contacts" flow (ARCHITECTURE.md §9) -- encode it into a QR code, an
  /// NFC payload, or a share code. [displayName] is what the other person
  /// will see; it's never revealed anywhere else.
  Future<String> createIdentityCard({required String displayName}) =>
      IdentityCard.encode(identity: identity, displayName: displayName);

  /// Processes a scanned/received identity card: verifies it, then
  /// upgrades that peer to [TrustLevel.trusted] with the exchanged
  /// display name. Returns the resulting [Contact], or null if the card
  /// was invalid or tampered with.
  Future<Contact?> trustFromIdentityCard(String encoded) async {
    final card = await IdentityCard.decode(encoded);
    if (card == null) return null;

    final nodeId = await card.resolveNodeId();
    final existing = await _trustStore.getContact(nodeId);
    final contact = Contact(
      nodeId: nodeId,
      signingPublicKeyBytes: Uint8List.fromList(card.signingPublicKey.bytes),
      agreementPublicKeyBytes: Uint8List.fromList(card.agreementPublicKey.bytes),
      trustLevel: TrustLevel.trusted,
      displayName: card.displayName,
      firstSeenAt: existing?.firstSeenAt ?? DateTime.now().toUtc(),
    );
    await _trustStore.upsertContact(contact);
    return contact;
  }

  Future<void> dispose() async {
    await _deviceSub?.cancel();
    await _connectionSub?.cancel();
    await _sessionSub?.cancel();
    await _messageSub?.cancel();
    await _contactSub?.cancel();
    await _fileTransfers?.dispose();
    await _link?.dispose();
    await _transport?.dispose();
    await _devicesController.close();
    await _messagesController.close();
    await _diagnostics.close();
  }
}
