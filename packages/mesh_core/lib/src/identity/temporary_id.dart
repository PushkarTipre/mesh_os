import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Rotating, unlinkable identifier a node broadcasts instead of its
/// permanent Node ID, to reduce passive tracking (see ARCHITECTURE.md §3,
/// §6).
///
/// The identifier is a deterministic function of the node's permanent
/// signing public key and the current time slot. A node recomputes its own
/// current temporary ID trivially, and any peer that already possesses the
/// node's permanent public key (i.e. an established trusted contact) can
/// recognize it nearby without a fresh handshake. A stranger who has never
/// obtained the permanent public key cannot invert the identifier or link
/// successive rotations to the same node.
///
/// This guarantee depends on the permanent public key never being
/// broadcast in the open discovery beacon -- that is enforced by the
/// discovery/transport layer (later checkpoints), not by this class.
class TemporaryId {
  const TemporaryId._();

  static const Duration rotationInterval = Duration(minutes: 10);
  static const int lengthBytes = 8;

  static final Sha256 _hashAlgorithm = Sha256();

  /// The rotation "slot" (a coarse time bucket) that [time] falls into.
  /// Two calls within the same [rotationInterval] window return the same
  /// slot, and therefore the same temporary ID for a given identity.
  static int slotFor(DateTime time) {
    final epochSeconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
    return epochSeconds ~/ rotationInterval.inSeconds;
  }

  /// Derives the temporary ID for the signing public key bytes at [at]
  /// (defaults to now), as a lowercase hex string.
  static Future<String> derive({
    required List<int> signingPublicKeyBytes,
    DateTime? at,
  }) async {
    final slot = slotFor(at ?? DateTime.now());
    final slotBytes = ByteData(8)..setInt64(0, slot, Endian.big);
    final digest = await _hashAlgorithm.hash([
      ...signingPublicKeyBytes,
      ...slotBytes.buffer.asUint8List(),
    ]);
    final truncated = digest.bytes.sublist(0, lengthBytes);
    return truncated.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
