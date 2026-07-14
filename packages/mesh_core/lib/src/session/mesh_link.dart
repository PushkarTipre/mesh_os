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
import '../transport/transport.dart';
import 'peer_session.dart';

const int _publicKeyLength = 32; // Ed25519 and X25519 keys are both 32 bytes

// Every byte blob handed to the transport is prefixed with one of these,
// so the receiving side knows whether to decode it directly as a
// MeshPacket or feed it through the Reassembler first.
const int _wholePacketMarker = 0x00;
const int _fragmentMarker = 0x01;

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A message received from a peer, already signature-verified and
/// decrypted.
class InboundMessage {
  const InboundMessage({required this.remoteId, required this.plaintext});

  final String remoteId;
  final Uint8List plaintext;
}

/// Outcome of a [MeshLink.sendData] call.
enum DeliveryStatus {
  /// The peer's [PacketType.ack] for this message was received.
  delivered,

  /// Every retry was exhausted, or the peer disconnected, without an ack.
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

/// Sits on top of any [Transport] and turns raw connected-peer bytes into
/// verified, decrypted messages -- and the reverse for sending, with
/// ACK-based delivery confirmation and retry. This is deliberately
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
/// Reliability: a [PacketType.data] send is tracked until the receiver's
/// [PacketType.ack] arrives, retrying on a timer up to `maxRetries` times
/// before resolving [DeliveryStatus.failed]. Because a retry can cause the
/// *same* data packet to arrive twice (e.g. the ack, not the data, was
/// what got lost), incoming data packets are deduplicated by packet ID
/// before being surfaced on [messages] -- the receiver still re-sends the
/// ack either way, since that's what the sender is actually waiting on.
class MeshLink {
  MeshLink({required this.transport, required this.identity});

  final Transport transport;
  final NodeIdentity identity;

  final Map<String, PeerSession> _sessions = {};
  final Map<String, Reassembler> _reassemblers = {};
  final Map<String, _PendingSend> _pendingSends = {};
  final PacketDedupCache _dedupCache = PacketDedupCache();
  final StreamController<InboundMessage> _messages = StreamController.broadcast();
  final StreamController<String> _sessionEstablished = StreamController.broadcast();

  StreamSubscription<ConnectionEvent>? _connectionSub;
  StreamSubscription<DataEvent>? _dataSub;

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
  }

  Future<void> _onConnectionEvent(ConnectionEvent event) async {
    switch (event.type) {
      case ConnectionEventType.connected:
        await _sendDiscovery(event.remoteId);
      case ConnectionEventType.disconnected:
      case ConnectionEventType.failed:
        _sessions.remove(event.remoteId);
        _reassemblers.remove(event.remoteId);
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

    if (!await packet.verifySignature(session.signingPublicKey)) {
      return; // doesn't match this session's peer -- drop
    }

    switch (packet.type) {
      case PacketType.data:
        await _handleData(event.remoteId, packet, session);
      case PacketType.ack:
        _handleAck(packet);
      default:
        break;
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

    _sessions[remoteId] = PeerSession(
      remoteId: remoteId,
      nodeId: await NodeIdentity.nodeIdForSigningPublicKey(signingPublicKey),
      signingPublicKey: signingPublicKey,
      agreementPublicKey: agreementPublicKey,
    );
    _sessionEstablished.add(remoteId);
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
      _messages.add(InboundMessage(remoteId: remoteId, plaintext: plaintext));
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

  /// Encrypts and sends [plaintext] to [remoteId], retrying up to
  /// [maxRetries] times (every [retryInterval]) until the peer's ack
  /// arrives. Requires a session to already be established (i.e. the
  /// discovery handshake has completed) -- throws [StateError] otherwise.
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
    for (final pending in _pendingSends.values) {
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(DeliveryStatus.failed);
      }
    }
    _pendingSends.clear();
    await _messages.close();
    await _sessionEstablished.close();
  }
}
