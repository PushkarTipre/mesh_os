import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'trust_level.dart';

/// A persisted record of a node MeshOS has interacted with (ARCHITECTURE.md
/// §4, §7, §9). Distinct from `PeerSession`, which is ephemeral (scoped to
/// one live transport connection) -- a [Contact] survives disconnects and
/// app restarts.
class Contact {
  const Contact({
    required this.nodeId,
    required this.signingPublicKeyBytes,
    required this.agreementPublicKeyBytes,
    required this.trustLevel,
    required this.firstSeenAt,
    this.displayName,
  });

  final String nodeId;
  final Uint8List signingPublicKeyBytes;
  final Uint8List agreementPublicKeyBytes;
  final TrustLevel trustLevel;
  final DateTime firstSeenAt;

  /// Only ever set for [TrustLevel.trusted] contacts -- learned via an
  /// explicit `IdentityCard` exchange (QR/NFC/share-code), never from the
  /// ordinary discovery handshake (ARCHITECTURE.md §5's privacy boundary).
  final String? displayName;

  SimplePublicKey get signingPublicKey =>
      SimplePublicKey(signingPublicKeyBytes, type: KeyPairType.ed25519);

  SimplePublicKey get agreementPublicKey =>
      SimplePublicKey(agreementPublicKeyBytes, type: KeyPairType.x25519);

  Contact copyWith({TrustLevel? trustLevel, String? displayName}) => Contact(
        nodeId: nodeId,
        signingPublicKeyBytes: signingPublicKeyBytes,
        agreementPublicKeyBytes: agreementPublicKeyBytes,
        trustLevel: trustLevel ?? this.trustLevel,
        firstSeenAt: firstSeenAt,
        displayName: displayName ?? this.displayName,
      );
}
