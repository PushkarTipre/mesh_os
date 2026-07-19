import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/node_identity.dart';
import '../identity/temporary_id.dart';
import 'crc32.dart';
import 'packet_decode_exception.dart';
import 'packet_priority.dart';
import 'packet_type.dart';

/// A MeshOS wire packet (ARCHITECTURE.md §6, §12).
///
/// Field mutability matters here more than anything else about the format.
/// A packet is signed once by its origin node, then relayed hop by hop by
/// devices that don't hold that node's private key -- so each relay MUST
/// be able to decrement [ttl] and increment [hopCount] in place without
/// invalidating the signature. That means the signature can only cover
/// fields the origin sender set and nothing else touches: [version],
/// [type], [packetId], [timestamp], [tempSourceId], [tempDestId],
/// [priority], and [payload]. [ttl] and [hopCount] are deliberately
/// excluded from the signed data (see [_signableBytes]); the checksum is a
/// separate, unsigned, per-hop transmission-integrity check that every
/// relay recomputes fresh in [toBytes] after mutating ttl/hopCount via
/// [forwarded].
class MeshPacket {
  const MeshPacket._({
    required this.version,
    required this.type,
    required this.packetId,
    required this.timestamp,
    required this.tempSourceId,
    required this.tempDestId,
    required this.priority,
    required this.ttl,
    required this.hopCount,
    required this.signature,
    required this.payload,
  });

  static const int currentVersion = 1;

  static const int packetIdLength = 8;
  static const int _tempIdLength = TemporaryId.lengthBytes;
  static const int _signatureLength = 64; // Ed25519
  static const int _checksumLength = 4; // CRC-32

  static const int _offVersion = 0;
  static const int _offType = _offVersion + 1;
  static const int _offPacketId = _offType + 1;
  static const int _offTimestamp = _offPacketId + packetIdLength;
  static const int _offTempSourceId = _offTimestamp + 8;
  static const int _offTempDestId = _offTempSourceId + _tempIdLength;
  static const int _offPriority = _offTempDestId + _tempIdLength;
  static const int _offTtl = _offPriority + 1;
  static const int _offHopCount = _offTtl + 1;
  static const int _offChecksum = _offHopCount + 1;
  static const int _offSignature = _offChecksum + _checksumLength;

  /// Size of every field before the payload. Decoding requires at least
  /// this many bytes; everything past it is the (unpadded) payload.
  static const int fixedHeaderLength = _offSignature + _signatureLength;

  /// Sentinel [tempDestId] meaning "no specific destination" -- used for
  /// [PacketType.broadcast] and [PacketType.discovery] packets.
  static final Uint8List broadcastDestination = Uint8List(_tempIdLength);

  final int version;
  final PacketType type;

  /// 8 random bytes assigned once by the origin sender. Stays unchanged
  /// across every hop -- this is what a [PacketDedupCache] keys on to
  /// detect "have I already relayed this" and avoid flooding loops.
  final Uint8List packetId;

  final DateTime timestamp;
  final Uint8List tempSourceId;
  final Uint8List tempDestId;
  final PacketPriority priority;

  /// Decremented by each relay. A relay drops the packet instead of
  /// forwarding once this reaches 0 (see [forwarded]).
  final int ttl;

  /// Incremented by each relay.
  final int hopCount;

  /// Ed25519 signature over the sender-immutable fields + payload (see
  /// class doc). Unchanged across hops.
  final Uint8List signature;

  final Uint8List payload;

  String get packetIdHex => _bytesToHex(packetId);

  /// Builds and signs a new packet originated by [signer]. [ttl] bounds
  /// how many hops it can travel before relays must drop it.
  static Future<MeshPacket> create({
    required NodeIdentity signer,
    required PacketType type,
    required List<int> tempSourceId,
    required List<int> tempDestId,
    required List<int> payload,
    int ttl = 8,
    PacketPriority priority = PacketPriority.normal,
    DateTime? timestamp,
  }) async {
    final resolvedPacketId = _generatePacketId();
    final resolvedTimestamp = (timestamp ?? DateTime.now()).toUtc();
    final tempSourceIdBytes = _fixedLengthCopy(
      tempSourceId,
      _tempIdLength,
      'tempSourceId',
    );
    final tempDestIdBytes = _fixedLengthCopy(
      tempDestId,
      _tempIdLength,
      'tempDestId',
    );
    final payloadBytes = Uint8List.fromList(payload);

    final signable = _signableBytes(
      version: currentVersion,
      type: type,
      packetId: resolvedPacketId,
      timestamp: resolvedTimestamp,
      tempSourceId: tempSourceIdBytes,
      tempDestId: tempDestIdBytes,
      priority: priority,
      payload: payloadBytes,
    );
    final signature = await signer.sign(signable);

    return MeshPacket._(
      version: currentVersion,
      type: type,
      packetId: resolvedPacketId,
      timestamp: resolvedTimestamp,
      tempSourceId: tempSourceIdBytes,
      tempDestId: tempDestIdBytes,
      priority: priority,
      ttl: ttl,
      hopCount: 0,
      signature: Uint8List.fromList(signature),
      payload: payloadBytes,
    );
  }

  /// This packet as it should look after being relayed one hop: TTL
  /// decremented, hop count incremented, signature untouched (it never
  /// covered TTL/hopCount, so it stays valid). Returns null if TTL is
  /// already exhausted -- the caller should drop the packet, not forward
  /// it.
  MeshPacket? forwarded() {
    if (ttl <= 0) return null;
    return MeshPacket._(
      version: version,
      type: type,
      packetId: packetId,
      timestamp: timestamp,
      tempSourceId: tempSourceId,
      tempDestId: tempDestId,
      priority: priority,
      ttl: ttl - 1,
      hopCount: hopCount + 1,
      signature: signature,
      payload: payload,
    );
  }

  /// Verifies this packet was really signed by the holder of
  /// [signerPublicKey]. The caller supplies the public key (from a trust
  /// store or a session handshake) -- packets don't carry the sender's
  /// permanent public key themselves, only [tempSourceId] (see
  /// [TemporaryId]'s privacy rationale).
  Future<bool> verifySignature(SimplePublicKey signerPublicKey) {
    final signable = _signableBytes(
      version: version,
      type: type,
      packetId: packetId,
      timestamp: timestamp,
      tempSourceId: tempSourceId,
      tempDestId: tempDestId,
      priority: priority,
      payload: payload,
    );
    return NodeIdentity.verify(
      message: signable,
      signatureBytes: signature,
      signerPublicKey: signerPublicKey,
    );
  }

  Uint8List toBytes() {
    final buffer = Uint8List(fixedHeaderLength + payload.length);
    final view = ByteData.sublistView(buffer);

    buffer[_offVersion] = version;
    buffer[_offType] = type.byteValue;
    buffer.setRange(_offPacketId, _offPacketId + packetIdLength, packetId);
    view.setInt64(_offTimestamp, timestamp.millisecondsSinceEpoch, Endian.big);
    buffer.setRange(
      _offTempSourceId,
      _offTempSourceId + _tempIdLength,
      tempSourceId,
    );
    buffer.setRange(
      _offTempDestId,
      _offTempDestId + _tempIdLength,
      tempDestId,
    );
    buffer[_offPriority] = priority.byteValue;
    buffer[_offTtl] = ttl;
    buffer[_offHopCount] = hopCount;
    // checksum bytes (_offChecksum.._offSignature) stay zero until computed below
    buffer.setRange(_offSignature, fixedHeaderLength, signature);
    buffer.setRange(fixedHeaderLength, buffer.length, payload);

    final checksum = Crc32.compute(buffer);
    view.setUint32(_offChecksum, checksum, Endian.big);

    return buffer;
  }

  static MeshPacket decode(List<int> rawBytes) {
    try {
      final bytes = rawBytes is Uint8List ? rawBytes : Uint8List.fromList(rawBytes);
      if (bytes.length < fixedHeaderLength) {
        throw PacketDecodeException(
          'buffer too short: ${bytes.length} bytes, need at least $fixedHeaderLength',
        );
      }

      final version = bytes[_offVersion];
      if (version != currentVersion) {
        throw PacketDecodeException('unsupported packet version: $version');
      }

      final type = PacketType.fromByte(bytes[_offType]);
      final packetId = Uint8List.fromList(
        bytes.sublist(_offPacketId, _offPacketId + packetIdLength),
      );

      final view = ByteData.sublistView(bytes);
      final timestampMs = view.getInt64(_offTimestamp, Endian.big);
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
        isUtc: true,
      );

      final tempSourceId = Uint8List.fromList(
        bytes.sublist(_offTempSourceId, _offTempSourceId + _tempIdLength),
      );
      final tempDestId = Uint8List.fromList(
        bytes.sublist(_offTempDestId, _offTempDestId + _tempIdLength),
      );
      final priority = PacketPriority.fromByte(bytes[_offPriority]);
      final ttl = bytes[_offTtl];
      final hopCount = bytes[_offHopCount];
      final storedChecksum = view.getUint32(_offChecksum, Endian.big);
      final signature = Uint8List.fromList(
        bytes.sublist(_offSignature, fixedHeaderLength),
      );
      final payload = Uint8List.fromList(bytes.sublist(fixedHeaderLength));

      final forChecksum = Uint8List.fromList(bytes);
      forChecksum.setRange(_offChecksum, _offSignature, const [0, 0, 0, 0]);
      final computedChecksum = Crc32.compute(forChecksum);
      if (computedChecksum != storedChecksum) {
        throw const PacketDecodeException('checksum mismatch: corrupt packet');
      }

      return MeshPacket._(
        version: version,
        type: type,
        packetId: packetId,
        timestamp: timestamp,
        tempSourceId: tempSourceId,
        tempDestId: tempDestId,
        priority: priority,
        ttl: ttl,
        hopCount: hopCount,
        signature: signature,
        payload: payload,
      );
    } on PacketDecodeException {
      rethrow;
    } catch (e) {
      // Guarantees decode() never lets a raw RangeError/FormatException/etc
      // escape -- any unexpected failure becomes a typed decode error.
      throw PacketDecodeException('malformed packet: $e');
    }
  }

  static Uint8List _signableBytes({
    required int version,
    required PacketType type,
    required Uint8List packetId,
    required DateTime timestamp,
    required Uint8List tempSourceId,
    required Uint8List tempDestId,
    required PacketPriority priority,
    required Uint8List payload,
  }) {
    final builder = BytesBuilder();
    builder.addByte(version);
    builder.addByte(type.byteValue);
    builder.add(packetId);
    final timestampBytes = ByteData(8)
      ..setInt64(0, timestamp.millisecondsSinceEpoch, Endian.big);
    builder.add(timestampBytes.buffer.asUint8List());
    builder.add(tempSourceId);
    builder.add(tempDestId);
    builder.addByte(priority.byteValue);
    builder.add(payload);
    return builder.toBytes();
  }

  static Uint8List _generatePacketId() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(packetIdLength, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _fixedLengthCopy(List<int> bytes, int length, String name) {
    if (bytes.length != length) {
      throw ArgumentError.value(
        bytes.length,
        name,
        'must be exactly $length bytes',
      );
    }
    return Uint8List.fromList(bytes);
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
