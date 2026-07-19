import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encrypted_envelope.dart';
import 'identity_store.dart';
import 'temporary_id.dart';

/// A MeshOS node's cryptographic identity: an Ed25519 signing key pair for
/// authenticity, and an X25519 key pair for end-to-end encryption key
/// agreement (see ARCHITECTURE.md §3). Private key material never leaves
/// the device that generated it -- callers are responsible for persisting
/// [toStorable] somewhere secure (e.g. platform keychain) via an
/// [IdentityStore].
class NodeIdentity {
  NodeIdentity._({
    required this.signingKeyPair,
    required this.agreementKeyPair,
    required this.signingPublicKey,
    required this.agreementPublicKey,
    required this.nodeId,
    required this.routingAddress,
  });

  static final Ed25519 _signingAlgorithm = Ed25519();
  static final X25519 _agreementAlgorithm = X25519();
  static final Sha256 _hashAlgorithm = Sha256();
  static final Chacha20 _cipherAlgorithm = Chacha20.poly1305Aead();

  final SimpleKeyPairData signingKeyPair;
  final SimpleKeyPairData agreementKeyPair;
  final SimplePublicKey signingPublicKey;
  final SimplePublicKey agreementPublicKey;

  /// Lowercase hex, derived as the first 16 bytes of
  /// SHA-256(signing public key bytes).
  final String nodeId;

  /// A *stable* (non-rotating) 8-byte address used only for multi-hop
  /// packet routing (Checkpoint 6) -- see [routingAddressForSigningPublicKey]
  /// for why this exists as a third identifier alongside [nodeId] and
  /// [temporaryId].
  final Uint8List routingAddress;

  static Future<NodeIdentity> generate() async {
    final signing = await _signingAlgorithm.newKeyPair();
    final agreement = await _agreementAlgorithm.newKeyPair();
    return _fromKeyPairs(signing: signing, agreement: agreement);
  }

  /// Loads the identity persisted in [store], or generates and persists a
  /// new one if none exists yet. Calling this twice against the same
  /// backing store returns the same identity both times -- this is what
  /// makes identity survive an app restart.
  static Future<NodeIdentity> loadOrCreate(IdentityStore store) async {
    final existing = await store.read();
    if (existing != null) {
      return fromStorable(existing);
    }
    final identity = await generate();
    await store.write(identity.toStorable());
    return identity;
  }

  static Future<NodeIdentity> _fromKeyPairs({
    required SimpleKeyPair signing,
    required SimpleKeyPair agreement,
  }) async {
    final signingData = await signing.extract();
    final agreementData = await agreement.extract();
    final signingPublicKey = await signing.extractPublicKey();
    final agreementPublicKey = await agreement.extractPublicKey();
    final nodeId = await nodeIdForSigningPublicKey(signingPublicKey);
    final routingAddress = await routingAddressForSigningPublicKey(signingPublicKey);
    return NodeIdentity._(
      signingKeyPair: signingData,
      agreementKeyPair: agreementData,
      signingPublicKey: signingPublicKey,
      agreementPublicKey: agreementPublicKey,
      nodeId: nodeId,
      routingAddress: routingAddress,
    );
  }

  /// Derives the Node ID for any signing public key, not just this
  /// identity's own -- lets a caller who has learned a peer's public key
  /// (e.g. via [MeshLink]'s discovery handshake) compute that peer's
  /// permanent Node ID without needing their private key.
  static Future<String> nodeIdForSigningPublicKey(SimplePublicKey signingPublicKey) async {
    final digest = await _hashAlgorithm.hash(signingPublicKey.bytes);
    return _bytesToHex(digest.bytes.sublist(0, 16));
  }

  /// Derives the routing address for any signing public key -- the first
  /// 8 bytes of the same SHA-256 digest [nodeId] is drawn from (just
  /// fewer of them; nodeId uses the first 16).
  ///
  /// Why this exists as a *third* identifier, alongside the permanent
  /// [nodeId] and the rotating [temporaryId]: temp-ID rotation (every 10
  /// minutes, ARCHITECTURE.md §3) is fine for direct, immediate delivery,
  /// but is fundamentally incompatible with store-and-forward -- if a
  /// packet sits with a relay for an hour, the destination's temp ID has
  /// already rotated six times, so an address computed at send time can
  /// never match by delivery time. Multi-hop packets (`MeshLink`'s
  /// routed-packet path) address `tempSourceId`/`tempDestId` with routing
  /// addresses instead, which trades away temp-ID's anti-tracking
  /// property for multi-hop traffic specifically: an observer who sees
  /// the same routing address recur across packets over time can infer
  /// "these all go to/from the same node," without learning who that is
  /// (a routing address, like a Node ID, doesn't reveal the public key
  /// itself). Direct, single-hop packets are unaffected -- they keep
  /// using the rotating temp ID exactly as before.
  static Future<Uint8List> routingAddressForSigningPublicKey(
    SimplePublicKey signingPublicKey,
  ) async {
    final digest = await _hashAlgorithm.hash(signingPublicKey.bytes);
    return Uint8List.fromList(digest.bytes.sublist(0, 8));
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Signs [message] with this identity's signing key.
  Future<Uint8List> sign(List<int> message) async {
    final signature = await _signingAlgorithm.sign(
      message,
      keyPair: signingKeyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies that [signatureBytes] over [message] was produced by the
  /// holder of [signerPublicKey]. Never throws -- tampered or malformed
  /// input simply fails to verify.
  static Future<bool> verify({
    required List<int> message,
    required List<int> signatureBytes,
    required SimplePublicKey signerPublicKey,
  }) async {
    try {
      final signature = Signature(signatureBytes, publicKey: signerPublicKey);
      return await _signingAlgorithm.verify(message, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Encrypts [plaintext] for [recipientAgreementPublicKey] using X25519
  /// ECDH key agreement and an HKDF-derived ChaCha20-Poly1305 AEAD key.
  Future<EncryptedEnvelope> encryptFor(
    List<int> plaintext,
    SimplePublicKey recipientAgreementPublicKey,
  ) async {
    final payloadKey = await _derivePayloadKey(recipientAgreementPublicKey);
    final secretBox = await _cipherAlgorithm.encrypt(
      plaintext,
      secretKey: payloadKey,
    );
    return EncryptedEnvelope(
      nonce: Uint8List.fromList(secretBox.nonce),
      cipherText: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  /// Decrypts an [EncryptedEnvelope] that [senderAgreementPublicKey]
  /// produced for this identity. Throws if the MAC fails to verify
  /// (tampered ciphertext or wrong sender key).
  Future<Uint8List> decryptFrom(
    EncryptedEnvelope envelope,
    SimplePublicKey senderAgreementPublicKey,
  ) async {
    final payloadKey = await _derivePayloadKey(senderAgreementPublicKey);
    final secretBox = SecretBox(
      envelope.cipherText,
      nonce: envelope.nonce,
      mac: Mac(envelope.mac),
    );
    final plaintext = await _cipherAlgorithm.decrypt(
      secretBox,
      secretKey: payloadKey,
    );
    return Uint8List.fromList(plaintext);
  }

  Future<SecretKey> _derivePayloadKey(SimplePublicKey otherAgreementPublicKey) async {
    final sharedSecret = await _agreementAlgorithm.sharedSecretKey(
      keyPair: agreementKeyPair,
      remotePublicKey: otherAgreementPublicKey,
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode('MeshOS-v1-payload-key'),
    );
  }

  /// Deterministic rotating identifier that only holders of
  /// [signingPublicKey] can recompute -- see [TemporaryId].
  Future<String> temporaryId({DateTime? at}) => TemporaryId.derive(
        signingPublicKeyBytes: signingPublicKey.bytes,
        at: at,
      );

  /// Raw-byte form of [temporaryId] -- the wire representation used in
  /// packet headers (see `MeshPacket`).
  Future<Uint8List> temporaryIdBytes({DateTime? at}) => TemporaryId.deriveBytes(
        signingPublicKeyBytes: signingPublicKey.bytes,
        at: at,
      );

  /// Serializes this identity, including private key material, for
  /// storage via an [IdentityStore]. The caller is responsible for storing
  /// the result somewhere secure.
  Map<String, dynamic> toStorable() => {
        'version': 1,
        'signingPrivateKey': base64Encode(signingKeyPair.bytes),
        'agreementPrivateKey': base64Encode(agreementKeyPair.bytes),
      };

  static Future<NodeIdentity> fromStorable(Map<String, dynamic> data) async {
    final version = data['version'];
    if (version != 1) {
      throw FormatException('Unsupported NodeIdentity storage version: $version');
    }
    final signingSeed = base64Decode(data['signingPrivateKey'] as String);
    final agreementSeed = base64Decode(data['agreementPrivateKey'] as String);
    final signing = await _signingAlgorithm.newKeyPairFromSeed(signingSeed);
    final agreement = await _agreementAlgorithm.newKeyPairFromSeed(agreementSeed);
    return _fromKeyPairs(signing: signing, agreement: agreement);
  }
}
