import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/node_identity.dart';

/// What a QR code (or NFC tap, or share-code) carries for the "Becoming
/// Contacts" flow (ARCHITECTURE.md §9): a self-certifying bundle of a
/// node's public keys and the display name it's choosing to reveal.
/// Self-certifying in the same sense as `MeshLink`'s discovery handshake --
/// [decode] verifies the signature against the very key embedded in the
/// payload, so a valid card is proof the encoder holds the matching
/// private key, without any prior key exchange.
///
/// Unlike the ordinary discovery handshake, this is an intentional,
/// consensual exchange between two people physically present (scanning
/// each other's codes) -- that consent is exactly why it's safe for the
/// payload to carry a display name here, when the passive discovery
/// beacon deliberately never does (ARCHITECTURE.md §5).
class IdentityCard {
  const IdentityCard({
    required this.signingPublicKey,
    required this.agreementPublicKey,
    required this.displayName,
  });

  static const int currentVersion = 1;
  static const int maxDisplayNameBytes = 64;

  final SimplePublicKey signingPublicKey;
  final SimplePublicKey agreementPublicKey;
  final String displayName;

  Future<String> resolveNodeId() =>
      NodeIdentity.nodeIdForSigningPublicKey(signingPublicKey);

  /// Builds and signs a shareable card for [identity], choosing to reveal
  /// [displayName]. Throws [ArgumentError] if the name is unreasonably
  /// long (QR codes have a practical data ceiling).
  static Future<String> encode({
    required NodeIdentity identity,
    required String displayName,
  }) async {
    if (utf8.encode(displayName).length > maxDisplayNameBytes) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must be at most $maxDisplayNameBytes UTF-8 bytes',
      );
    }

    final signable = _signableBytes(
      signingPublicKeyBytes: identity.signingPublicKey.bytes,
      agreementPublicKeyBytes: identity.agreementPublicKey.bytes,
      displayName: displayName,
    );
    final signature = await identity.sign(signable);

    return jsonEncode({
      'v': currentVersion,
      'signingPublicKey': base64Encode(identity.signingPublicKey.bytes),
      'agreementPublicKey': base64Encode(identity.agreementPublicKey.bytes),
      'displayName': displayName,
      'signature': base64Encode(signature),
    });
  }

  /// Parses and verifies [encoded]. Returns null for anything malformed,
  /// unsupported-version, or with a signature that doesn't check out --
  /// never throws, so a garbled QR scan is just "not a valid card," not a
  /// crash.
  static Future<IdentityCard?> decode(String encoded) async {
    try {
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic>) return null;
      if (json['v'] != currentVersion) return null;

      final signingPublicKeyBytes = base64Decode(json['signingPublicKey'] as String);
      final agreementPublicKeyBytes = base64Decode(json['agreementPublicKey'] as String);
      final displayName = json['displayName'] as String;
      final signatureBytes = base64Decode(json['signature'] as String);

      final signingPublicKey = SimplePublicKey(
        signingPublicKeyBytes,
        type: KeyPairType.ed25519,
      );
      final agreementPublicKey = SimplePublicKey(
        agreementPublicKeyBytes,
        type: KeyPairType.x25519,
      );

      final signable = _signableBytes(
        signingPublicKeyBytes: signingPublicKeyBytes,
        agreementPublicKeyBytes: agreementPublicKeyBytes,
        displayName: displayName,
      );
      final valid = await NodeIdentity.verify(
        message: signable,
        signatureBytes: signatureBytes,
        signerPublicKey: signingPublicKey,
      );
      if (!valid) return null;

      return IdentityCard(
        signingPublicKey: signingPublicKey,
        agreementPublicKey: agreementPublicKey,
        displayName: displayName,
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _signableBytes({
    required List<int> signingPublicKeyBytes,
    required List<int> agreementPublicKeyBytes,
    required String displayName,
  }) {
    final builder = BytesBuilder();
    builder.addByte(currentVersion);
    builder.add(signingPublicKeyBytes);
    builder.add(agreementPublicKeyBytes);
    builder.add(utf8.encode(displayName));
    return builder.toBytes();
  }
}
