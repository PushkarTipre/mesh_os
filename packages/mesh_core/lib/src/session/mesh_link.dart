import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/encrypted_envelope.dart';
import '../identity/node_identity.dart';
import '../packet/fragment.dart';
import '../packet/fragmenter.dart';
import '../packet/mesh_packet.dart';
import '../packet/packet_decode_exception.dart';
import '../packet/packet_dedup_cache.dart';
import '../packet/packet_type.dart';
import '../packet/reassembler.dart';
import '../routing/relay_policy.dart';
import '../transport/transport.dart';
import '../trust/contact.dart';
import '../trust/trust_level.dart';
import '../trust/trust_store.dart';
import 'peer_session.dart';

const int _publicKeyLength = 32; // Ed25519 and X25519 keys are both 32 bytes

// Every byte blob handed to the transport is prefixed with one of these,
// so the receiving side knows whether to decode it directly as a
// MeshPacket or feed it through the Reassembler first.
const int _wholePacketMarker = 0x00;
const int _fragmentMarker = 0x01;

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A message received from a peer, already signature-verified and
/// decrypted -- whether it arrived directly or through one or more
/// relays.
class InboundMessage {
  const InboundMessage({required this.senderNodeId, required this.plaintext, this.remoteId});

  /// The sender's permanent, stable Node ID. Always populated, regardless
  /// of hop count -- use this, not [remoteId], to identify who sent it.
  final String senderNodeId;

  final Uint8List plaintext;

  /// The transport-level connection this arrived on: the sender
  /// themselves for a direct message, or null for a routed one (there's
  /// no live connection to the original sender in that case).
  final String? remoteId;
}

/// Outcome of a [MeshLink.sendData]/[MeshLink.sendToNode] call.
enum DeliveryStatus {
  /// The peer's [PacketType.ack] for this message was received --
  /// end-to-end for a routed send, hop-by-hop for a direct one.
  delivered,

  /// Every retry was exhausted (direct send), the peer disconnected, or
  /// the packet expired from the local store-and-forward cache without
  /// an ack ever arriving (routed send).
  failed,
}

class _PendingSend {
  _PendingSend({
    required this.remoteId,
    required this.packetBytes,
    required this.maxRetries,
  });

  final String remoteId;
  final Uint8List packetBytes;
  final int maxRetries;
  final Completer<DeliveryStatus> completer = Completer<DeliveryStatus>();
  int attempts = 0;
  Timer? timer;
}

class _StoredRelayPacket {
  _StoredRelayPacket({required this.packet, required this.storedAt});

  final MeshPacket packet;
  final DateTime storedAt;
}

/// Sits on top of any [Transport] and turns raw connected-peer bytes into
/// verified, decrypted messages -- and the reverse for sending, with
/// ACK-based delivery confirmation and retry, and multi-hop routing for
/// destinations that aren't directly connected. This is deliberately
/// transport-agnostic (it only touches the [Transport] interface), which
/// is what makes it unit-testable against `FakeTransport` with no real
/// radio.
///
/// The handshake: when a connection comes up, both sides immediately send
/// a signed [PacketType.discovery] packet whose payload *is* their two
/// public keys. This is self-certifying -- a signature only verifies
/// against the public key it claims, so once a discovery packet's
/// signature checks out against its own embedded key, that's proof the
/// sender holds the matching private key, with no prior key exchange
/// needed. See ARCHITECTURE.md §7-9 for the resulting privacy boundary
/// (temporary IDs are what passive scanning reveals; permanent public
/// keys are only revealed to peers you actually connect to).
///
/// Direct reliability: a [sendData] to a directly-connected peer is
/// tracked until their [PacketType.ack] arrives, retrying on a timer up
/// to `maxRetries` times before resolving [DeliveryStatus.failed].
/// Because a retry can cause the *same* data packet to arrive twice (e.g.
/// the ack, not the data, was what got lost), incoming data packets are
/// deduplicated by packet ID before being surfaced on [messages] -- the
/// receiver still re-sends the ack either way, since that's what the
/// sender is actually waiting on.
///
/// Multi-hop routing (Checkpoint 6): a packet not authored by the direct
/// peer that handed us its bytes is a routing candidate, distinguished
/// from a direct message purely by whether it verifies against that
/// peer's own session key -- if it doesn't, it's either addressed to us
/// via a relay, or passing through us toward someone else. Routing uses
/// [NodeIdentity.routingAddress] rather than the rotating temporary ID
/// for addressing: see that field's doc comment for why -- in short,
/// temp-ID rotation is incompatible with store-and-forward across
/// meaningful time gaps. [sendToNode] is the routing-aware counterpart
/// to [sendData]: it sends directly if a live session exists, and falls
/// back to flooding + store-and-forward + an end-to-end ack otherwise.
class MeshLink {
  MeshLink({
    required this.transport,
    required this.identity,
    TrustStore? trustStore,
    this.relayPolicy = RelayPolicy.everything,
    this.storeAndForwardExpiry = const Duration(hours: 24),
  }) : trustStore = trustStore ?? InMemoryTrustStore();

  final Transport transport;
  final NodeIdentity identity;

  /// Contact records (trust level, display name) survive across
  /// reconnects and app restarts -- unlike [PeerSession], which is
  /// ephemeral. Defaults to an in-memory store if the caller doesn't
  /// supply a persistent one (mesh_os's `DriftTrustStore`).
  final TrustStore trustStore;

  final RelayPolicy relayPolicy;

  /// How long a packet stays in the local store-and-forward cache,
  /// waiting for a path to its destination, before [sendToNode] (for a
  /// packet we originated) or ongoing relaying (for one we're carrying
  /// for someone else) gives up on it.
  final Duration storeAndForwardExpiry;

  static const int _maxRelaysPerSourcePerWindow = 20;
  static const Duration _relayRateWindow = Duration(minutes: 1);

  final Map<String, PeerSession> _sessions = {};
  final Map<String, Reassembler> _reassemblers = {};
  final Map<String, _PendingSend> _pendingSends = {};
  final Map<String, _StoredRelayPacket> _relayStore = {};
  final Map<String, Completer<DeliveryStatus>> _routedSendCompleters = {};
  final Map<String, List<DateTime>> _relayRateLimitLog = {};
  final PacketDedupCache _dedupCache = PacketDedupCache();
  final StreamController<InboundMessage> _messages = StreamController.broadcast();
  final StreamController<String> _sessionEstablished = StreamController.broadcast();

  StreamSubscription<ConnectionEvent>? _connectionSub;
  StreamSubscription<DataEvent>? _dataSub;
  Timer? _relayCleanupTimer;

  Stream<InboundMessage> get messages => _messages.stream;

  /// Emits a peer's remoteId the moment its discovery handshake completes
  /// -- i.e. the point at which [hasSession] first becomes true for it and
  /// [sendData] becomes usable.
  Stream<String> get sessionEstablished => _sessionEstablished.stream;

  Iterable<String> get sessionIds => _sessions.keys;

  Iterable<PeerSession> get sessions => _sessions.values;

  bool hasSession(String remoteId) => _sessions.containsKey(remoteId);

  void start() {
    _connectionSub = transport.connectionEvents.listen(_onConnectionEvent);
    _dataSub = transport.dataEvents.listen(_onDataEvent);

    // Store-and-forward entries are otherwise only swept lazily, on the
    // next relay/flood/reconnect activity -- a node with no further
    // connectivity at all would never re-check, leaving a sendToNode()
    // caller waiting forever instead of eventually seeing `failed`. Sweep
    // periodically too, at a cadence scaled to the expiry window.
    final sweepInterval = Duration(
      milliseconds: (storeAndForwardExpiry.inMilliseconds / 4)
          .clamp(1000, const Duration(hours: 6).inMilliseconds)
          .toInt(),
    );
    _relayCleanupTimer = Timer.periodic(sweepInterval, (_) => _evictExpiredRelayPackets());
  }

  Future<void> _onConnectionEvent(ConnectionEvent event) async {
    switch (event.type) {
      case ConnectionEventType.connected:
        await _sendDiscovery(event.remoteId);
      case ConnectionEventType.disconnected:
      case ConnectionEventType.failed:
        _sessions.remove(event.remoteId);
        _reassemblers.remove(event.remoteId);
        _relayRateLimitLog.remove(event.remoteId);
        _failPendingSendsFor(event.remoteId);
      case ConnectionEventType.incomingRequest:
        break;
    }
  }

  Future<void> _sendDiscovery(String remoteId) async {
    final tempSourceId = await identity.temporaryIdBytes();
    final payload = BytesBuilder()
      ..add(identity.signingPublicKey.bytes)
      ..add(identity.agreementPublicKey.bytes);
    final packet = await MeshPacket.create(
      signer: identity,
      type: PacketType.discovery,
      tempSourceId: tempSourceId,
      tempDestId: MeshPacket.broadcastDestination,
      payload: payload.toBytes(),
    );
    await _sendBytes(remoteId, packet.toBytes());
  }

  /// Sends [packetBytes] to [remoteId], transparently fragmenting it first
  /// if it's too large for the transport's [Transport.maxPayloadSize]. A
  /// 1-byte envelope marker precedes every send so the receiving side
  /// knows whether to decode directly or feed it through a [Reassembler].
  Future<void> _sendBytes(String remoteId, Uint8List packetBytes) async {
    if (packetBytes.length + 1 <= transport.maxPayloadSize) {
      final envelope = BytesBuilder()
        ..addByte(_wholePacketMarker)
        ..add(packetBytes);
      await transport.send(remoteId, envelope.toBytes());
      return;
    }

    final maxChunkSize = transport.maxPayloadSize - 1 - Fragment.headerLength;
    for (final fragment in Fragmenter.split(packetBytes, maxChunkSize: maxChunkSize)) {
      final envelope = BytesBuilder()
        ..addByte(_fragmentMarker)
        ..add(fragment.toBytes());
      await transport.send(remoteId, envelope.toBytes());
    }
  }

  Future<void> _onDataEvent(DataEvent event) async {
    if (event.data.isEmpty) return;
    final marker = event.data[0];
    final body = Uint8List.sublistView(event.data, 1);

    final Uint8List packetBytes;
    switch (marker) {
      case _wholePacketMarker:
        packetBytes = body;
      case _fragmentMarker:
        final Fragment fragment;
        try {
          fragment = Fragment.fromBytes(body);
        } on PacketDecodeException {
          return;
        }
        final reassembler = _reassemblers.putIfAbsent(event.remoteId, Reassembler.new);
        final reassembled = reassembler.add(fragment);
        if (reassembled == null) return; // still waiting on the rest
        packetBytes = reassembled;
      default:
        return; // unknown envelope marker -- drop
    }

    final MeshPacket packet;
    try {
      packet = MeshPacket.decode(packetBytes);
    } on PacketDecodeException {
      return; // malformed input -- drop, don't crash the link
    }

    if (packet.type == PacketType.discovery) {
      await _handleDiscovery(event.remoteId, packet);
      return;
    }

    final session = _sessions[event.remoteId];
    if (session == null) return; // no key material for this peer yet

    if (packet.type != PacketType.data && packet.type != PacketType.ack) return;

    // A direct send/ack (sendData/_sendAck) always addresses tempDestId
    // as broadcastDestination -- there's no routing address to check,
    // the live transport connection *is* the addressing. Anything else
    // in tempDestId means this packet is routed (Checkpoint 6): it might
    // be signed by the very peer we're connected to (their own outbound
    // packet, addressed past us to someone else -- the common first-hop
    // case) or by someone further away entirely. Either way it can't be
    // handled via this direct session's key, since the payload wasn't
    // necessarily encrypted for *us* using *their* key.
    if (!_bytesEqual(packet.tempDestId, MeshPacket.broadcastDestination)) {
      await _handleRoutedPacket(event.remoteId, packet);
      return;
    }

    if (!await packet.verifySignature(session.signingPublicKey)) {
      return; // doesn't match this session's peer -- drop
    }

    // Defense in depth: a contact can be blocked *while* a session is
    // already live (the handshake-time check in _handleDiscovery only
    // covers new/reconnecting sessions).
    if (await trustStore.trustLevelFor(session.nodeId) == TrustLevel.blocked) {
      _sessions.remove(event.remoteId);
      await transport.disconnect(event.remoteId);
      return;
    }

    switch (packet.type) {
      case PacketType.data:
        await _handleData(event.remoteId, packet, session);
      case PacketType.ack:
        _handleAck(packet);
      default:
        break; // unreachable -- narrowed to data/ack above
    }
  }

  Future<void> _handleDiscovery(String remoteId, MeshPacket packet) async {
    if (packet.payload.length != _publicKeyLength * 2) return;
    final signingPublicKey = SimplePublicKey(
      packet.payload.sublist(0, _publicKeyLength),
      type: KeyPairType.ed25519,
    );
    final agreementPublicKey = SimplePublicKey(
      packet.payload.sublist(_publicKeyLength, _publicKeyLength * 2),
      type: KeyPairType.x25519,
    );

    // Self-certifying: the signature must verify against the very key it
    // claims to belong to.
    if (!await packet.verifySignature(signingPublicKey)) return;

    final nodeId = await NodeIdentity.nodeIdForSigningPublicKey(signingPublicKey);
    final existingContact = await trustStore.getContact(nodeId);

    // "Blocked = dropped at ingress" (ARCHITECTURE.md SS4): never
    // establish a session with a blocked node, and hang up the transport
    // connection outright.
    if (existingContact?.trustLevel == TrustLevel.blocked) {
      await transport.disconnect(remoteId);
      return;
    }

    if (existingContact == null) {
      // First-ever contact -- "interacted before" makes it at least
      // known. Trusted only ever comes from an explicit IdentityCard
      // exchange (mesh_os's MeshOS.trust*), never automatically.
      await trustStore.upsertContact(Contact(
        nodeId: nodeId,
        signingPublicKeyBytes: Uint8List.fromList(signingPublicKey.bytes),
        agreementPublicKeyBytes: Uint8List.fromList(agreementPublicKey.bytes),
        trustLevel: TrustLevel.known,
        firstSeenAt: DateTime.now().toUtc(),
      ));
    }

    _sessions[remoteId] = PeerSession(
      remoteId: remoteId,
      nodeId: nodeId,
      signingPublicKey: signingPublicKey,
      agreementPublicKey: agreementPublicKey,
    );
    _sessionEstablished.add(remoteId);

    // A fresh connection is a fresh opportunity to get stuck packets
    // moving again (ARCHITECTURE.md §7's "Charlie appears -> forward").
    await _reattemptStoredRelays(remoteId);
  }

  Future<void> _handleData(String remoteId, MeshPacket packet, PeerSession session) async {
    // A duplicate is expected whenever our previous ack for this same
    // packet got lost -- the sender will retry the identical packet.
    // Still decrypt (harmless, no side effects) so we can still ack it,
    // but don't surface it to the app twice.
    final isNew = _dedupCache.checkAndRecord(packet.packetIdHex);

    final EncryptedEnvelope envelope;
    try {
      envelope = EncryptedEnvelope.fromBytes(packet.payload);
    } on FormatException {
      return;
    }

    final Uint8List plaintext;
    try {
      plaintext = await identity.decryptFrom(envelope, session.agreementPublicKey);
    } catch (_) {
      return; // MAC failure / tampered payload -- drop
    }

    if (isNew) {
      _messages.add(InboundMessage(
        senderNodeId: session.nodeId,
        plaintext: plaintext,
        remoteId: remoteId,
      ));
    }

    await _sendAck(remoteId, packet.packetId);
  }

  Future<void> _sendAck(String remoteId, Uint8List ackedPacketId) async {
    final tempSourceId = await identity.temporaryIdBytes();
    final ackPacket = await MeshPacket.create(
      signer: identity,
      type: PacketType.ack,
      tempSourceId: tempSourceId,
      tempDestId: MeshPacket.broadcastDestination,
      payload: ackedPacketId,
    );
    await _sendBytes(remoteId, ackPacket.toBytes());
  }

  void _handleAck(MeshPacket ackPacket) {
    if (ackPacket.payload.length != MeshPacket.packetIdLength) return;
    final pending = _pendingSends.remove(_bytesToHex(ackPacket.payload));
    if (pending == null) return; // unknown, or already resolved -- duplicate ack
    pending.timer?.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.complete(DeliveryStatus.delivered);
    }
  }

  // ---------------------------------------------------------------------
  // Multi-hop routing (Checkpoint 6)
  // ---------------------------------------------------------------------

  Future<void> _handleRoutedPacket(String fromRemoteId, MeshPacket packet) async {
    final isNew = _dedupCache.checkAndRecord(packet.packetIdHex);
    if (!isNew) return; // already relayed or processed this one

    if (_bytesEqual(packet.tempDestId, identity.routingAddress)) {
      final delivered = await _tryDeliverRouted(packet);
      if (delivered) return;
      // Routing-address collision is astronomically unlikely, but if we
      // couldn't confidently claim it, fall through and treat it as a
      // relay candidate rather than silently dropping a real message.
    }

    await _relayPacket(fromRemoteId, packet);
  }

  Future<bool> _tryDeliverRouted(MeshPacket packet) async {
    final senderContact = await _resolveContactByRoutingAddress(packet.tempSourceId);
    if (senderContact == null) return false;

    // Consumed either way -- we recognize the sender, so this genuinely
    // was addressed to us; a blocked sender's traffic is dropped, not
    // relayed further.
    if (senderContact.trustLevel == TrustLevel.blocked) return true;

    if (!await packet.verifySignature(senderContact.signingPublicKey)) return false;

    switch (packet.type) {
      case PacketType.data:
        await _handleRoutedData(packet, senderContact);
        return true;
      case PacketType.ack:
        _handleRoutedAck(packet);
        return true;
      default:
        return false;
    }
  }

  Future<Contact?> _resolveContactByRoutingAddress(Uint8List routingAddress) async {
    for (final contact in await trustStore.listContacts()) {
      final candidate = await NodeIdentity.routingAddressForSigningPublicKey(
        contact.signingPublicKey,
      );
      if (_bytesEqual(candidate, routingAddress)) return contact;
    }
    return null;
  }

  Future<void> _handleRoutedData(MeshPacket packet, Contact senderContact) async {
    final EncryptedEnvelope envelope;
    try {
      envelope = EncryptedEnvelope.fromBytes(packet.payload);
    } on FormatException {
      return;
    }

    final Uint8List plaintext;
    try {
      plaintext = await identity.decryptFrom(envelope, senderContact.agreementPublicKey);
    } catch (_) {
      return; // MAC failure / tampered payload -- drop
    }

    _messages.add(InboundMessage(senderNodeId: senderContact.nodeId, plaintext: plaintext));
    await _sendRoutedAck(senderContact, packet.packetId);
  }

  Future<void> _sendRoutedAck(Contact recipient, Uint8List ackedPacketId) async {
    final destRoutingAddress = await NodeIdentity.routingAddressForSigningPublicKey(
      recipient.signingPublicKey,
    );
    final ackPacket = await MeshPacket.create(
      signer: identity,
      type: PacketType.ack,
      tempSourceId: identity.routingAddress,
      tempDestId: destRoutingAddress,
      payload: ackedPacketId,
    );
    await _floodOrStore(ackPacket);
  }

  void _handleRoutedAck(MeshPacket ackPacket) {
    if (ackPacket.payload.length != MeshPacket.packetIdLength) return;
    final ackedPacketIdHex = _bytesToHex(ackPacket.payload);
    final completer = _routedSendCompleters.remove(ackedPacketIdHex);
    if (completer == null) return; // not ours, or already resolved
    _relayStore.remove(ackedPacketIdHex);
    if (!completer.isCompleted) {
      completer.complete(DeliveryStatus.delivered);
    }
  }

  Future<void> _relayPacket(String fromRemoteId, MeshPacket packet) async {
    final forwarded = packet.forwarded();
    if (forwarded == null) return; // ttl exhausted

    if (!await _relayAllowed(fromRemoteId)) return;
    if (!_recordRelayForRateLimit(fromRemoteId)) return;

    await _floodOrStore(forwarded, excludeRemoteId: fromRemoteId);
  }

  Future<bool> _relayAllowed(String fromRemoteId) async {
    switch (relayPolicy) {
      case RelayPolicy.disabled:
        return false;
      case RelayPolicy.everything:
        return true;
      case RelayPolicy.trustedContactsOnly:
        final session = _sessions[fromRemoteId];
        if (session == null) return false;
        return await trustStore.trustLevelFor(session.nodeId) == TrustLevel.trusted;
    }
  }

  /// Basic DoS hygiene: caps how many packets we'll relay *on behalf of*
  /// a single source peer within [_relayRateWindow] -- a hostile or
  /// malfunctioning neighbor can't turn us into an unbounded flood
  /// amplifier for their traffic.
  bool _recordRelayForRateLimit(String fromRemoteId) {
    final now = DateTime.now();
    final log = _relayRateLimitLog.putIfAbsent(fromRemoteId, () => []);
    log.removeWhere((t) => now.difference(t) > _relayRateWindow);
    if (log.length >= _maxRelaysPerSourcePerWindow) return false;
    log.add(now);
    return true;
  }

  /// Stores [packet] for later opportunistic delivery (ARCHITECTURE.md
  /// §7) and immediately floods it to every currently connected peer
  /// except [excludeRemoteId] (typically whoever we just received it
  /// from, if any).
  Future<void> _floodOrStore(MeshPacket packet, {String? excludeRemoteId}) async {
    _evictExpiredRelayPackets();
    _relayStore[packet.packetIdHex] = _StoredRelayPacket(
      packet: packet,
      storedAt: DateTime.now().toUtc(),
    );
    final bytes = packet.toBytes();
    for (final remoteId in _sessions.keys.toList()) {
      if (remoteId == excludeRemoteId) continue;
      await _sendBytes(remoteId, bytes);
    }
  }

  Future<void> _reattemptStoredRelays(String remoteId) async {
    _evictExpiredRelayPackets();
    for (final stored in _relayStore.values.toList()) {
      await _sendBytes(remoteId, stored.packet.toBytes());
    }
  }

  void _evictExpiredRelayPackets() {
    final now = DateTime.now().toUtc();
    final expiredKeys = _relayStore.entries
        .where((entry) => now.difference(entry.value.storedAt) > storeAndForwardExpiry)
        .map((entry) => entry.key)
        .toList();
    for (final key in expiredKeys) {
      _relayStore.remove(key);
      final completer = _routedSendCompleters.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(DeliveryStatus.failed);
      }
    }
  }

  /// Sends [plaintext] to [nodeId], using a direct session if one exists,
  /// or routing through relays (flooding + store-and-forward) otherwise.
  /// Requires [nodeId] to already be a known contact -- encrypting for
  /// them needs their public key, which this device only has on file if
  /// they've met before, directly or via a relay. Throws [StateError]
  /// otherwise, or if they're blocked.
  ///
  /// Unlike [sendData]'s bounded retry, a routed send has no fixed
  /// timeout in the usual sense: it resolves [DeliveryStatus.delivered]
  /// whenever the end-to-end ack eventually arrives (which could be much
  /// later, if the destination isn't reachable yet), or
  /// [DeliveryStatus.failed] once the packet expires from the local
  /// store-and-forward cache ([storeAndForwardExpiry]) without one.
  Future<DeliveryStatus> sendToNode(String nodeId, List<int> plaintext) async {
    for (final session in _sessions.values) {
      if (session.nodeId == nodeId) {
        return sendData(session.remoteId, plaintext);
      }
    }

    final contact = await trustStore.getContact(nodeId);
    if (contact == null) {
      throw StateError('MeshLink: no known contact with node $nodeId yet');
    }
    if (contact.trustLevel == TrustLevel.blocked) {
      throw StateError('MeshLink: $nodeId is blocked');
    }

    final envelope = await identity.encryptFor(plaintext, contact.agreementPublicKey);
    final destRoutingAddress = await NodeIdentity.routingAddressForSigningPublicKey(
      contact.signingPublicKey,
    );
    final packet = await MeshPacket.create(
      signer: identity,
      type: PacketType.data,
      tempSourceId: identity.routingAddress,
      tempDestId: destRoutingAddress,
      payload: envelope.toBytes(),
    );

    final completer = Completer<DeliveryStatus>();
    _routedSendCompleters[packet.packetIdHex] = completer;
    await _floodOrStore(packet);

    return completer.future;
  }

  // ---------------------------------------------------------------------
  // Direct (single-hop) reliable send -- Checkpoint 4
  // ---------------------------------------------------------------------

  /// Encrypts and sends [plaintext] to [remoteId], retrying up to
  /// [maxRetries] times (every [retryInterval]) until the peer's ack
  /// arrives. Requires a session to already be established (i.e. the
  /// discovery handshake has completed) -- throws [StateError] otherwise,
  /// including if the peer has since been blocked.
  Future<DeliveryStatus> sendData(
    String remoteId,
    List<int> plaintext, {
    int maxRetries = 3,
    Duration retryInterval = const Duration(seconds: 2),
  }) async {
    final session = _sessions[remoteId];
    if (session == null) {
      throw StateError('MeshLink: no established session with $remoteId yet');
    }
    if (await trustStore.trustLevelFor(session.nodeId) == TrustLevel.blocked) {
      _sessions.remove(remoteId);
      throw StateError('MeshLink: $remoteId (${session.nodeId}) is blocked');
    }
    final envelope = await identity.encryptFor(plaintext, session.agreementPublicKey);
    final tempSourceId = await identity.temporaryIdBytes();
    final packet = await MeshPacket.create(
      signer: identity,
      type: PacketType.data,
      tempSourceId: tempSourceId,
      tempDestId: MeshPacket.broadcastDestination,
      payload: envelope.toBytes(),
    );

    final pending = _PendingSend(
      remoteId: remoteId,
      packetBytes: packet.toBytes(),
      maxRetries: maxRetries,
    );
    _pendingSends[packet.packetIdHex] = pending;

    unawaited(_attemptSend(packet.packetIdHex, pending, retryInterval));

    return pending.completer.future;
  }

  Future<void> _attemptSend(
    String packetIdHex,
    _PendingSend pending,
    Duration retryInterval,
  ) async {
    // Already resolved (acked, failed, or the peer disconnected) --
    // nothing left to do.
    if (!_pendingSends.containsKey(packetIdHex)) return;

    await _sendBytes(pending.remoteId, pending.packetBytes);
    pending.attempts += 1;

    if (pending.attempts > pending.maxRetries) {
      _pendingSends.remove(packetIdHex);
      if (!pending.completer.isCompleted) {
        pending.completer.complete(DeliveryStatus.failed);
      }
      return;
    }

    pending.timer = Timer(
      retryInterval,
      () => _attemptSend(packetIdHex, pending, retryInterval),
    );
  }

  void _failPendingSendsFor(String remoteId) {
    final keys = _pendingSends.entries
        .where((entry) => entry.value.remoteId == remoteId)
        .map((entry) => entry.key)
        .toList();
    for (final key in keys) {
      final pending = _pendingSends.remove(key)!;
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(DeliveryStatus.failed);
      }
    }
  }

  Future<void> dispose() async {
    await _connectionSub?.cancel();
    await _dataSub?.cancel();
    _relayCleanupTimer?.cancel();
    for (final pending in _pendingSends.values) {
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(DeliveryStatus.failed);
      }
    }
    _pendingSends.clear();
    for (final completer in _routedSendCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete(DeliveryStatus.failed);
      }
    }
    _routedSendCompleters.clear();
    _relayStore.clear();
    await _messages.close();
    await _sessionEstablished.close();
  }
}
