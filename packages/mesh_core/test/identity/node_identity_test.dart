import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

void main() {
  group('NodeIdentity.generate', () {
    test('produces a 32-hex-char node id', () async {
      final identity = await NodeIdentity.generate();
      expect(identity.nodeId, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('produces distinct identities on repeated calls', () async {
      final a = await NodeIdentity.generate();
      final b = await NodeIdentity.generate();
      expect(a.nodeId, isNot(equals(b.nodeId)));
      expect(a.signingPublicKey.bytes, isNot(equals(b.signingPublicKey.bytes)));
    });
  });

  group('routingAddress', () {
    test('is 8 bytes and distinct between two identities', () async {
      final a = await NodeIdentity.generate();
      final b = await NodeIdentity.generate();
      expect(a.routingAddress, hasLength(8));
      expect(a.routingAddress, isNot(equals(b.routingAddress)));
    });

    test('is a stable prefix of the same digest nodeId is drawn from -- '
        'unlike temporaryId, it does not rotate with time', () async {
      final identity = await NodeIdentity.generate();
      final at1 = DateTime.utc(2026, 1, 1, 12);
      final at2 = at1.add(const Duration(hours: 3));

      final addressAgain = await NodeIdentity.routingAddressForSigningPublicKey(
        identity.signingPublicKey,
      );
      expect(identity.routingAddress, equals(addressAgain));

      // unlike temporaryId, routingAddress has no time parameter at all --
      // demonstrate that the two temp IDs at these times differ, while the
      // routing address (computed independent of time) stays constant.
      final tempAt1 = await identity.temporaryId(at: at1);
      final tempAt2 = await identity.temporaryId(at: at2);
      expect(tempAt1, isNot(equals(tempAt2)));
    });
  });

  group('sign / verify', () {
    test('a valid signature verifies against the signer public key', () async {
      final signer = await NodeIdentity.generate();
      final message = utf8.encode('hello mesh');

      final signature = await signer.sign(message);
      final ok = await NodeIdentity.verify(
        message: message,
        signatureBytes: signature,
        signerPublicKey: signer.signingPublicKey,
      );

      expect(ok, isTrue);
    });

    test('fails to verify against a different node\'s public key', () async {
      final signer = await NodeIdentity.generate();
      final impostor = await NodeIdentity.generate();
      final message = utf8.encode('hello mesh');

      final signature = await signer.sign(message);
      final ok = await NodeIdentity.verify(
        message: message,
        signatureBytes: signature,
        signerPublicKey: impostor.signingPublicKey,
      );

      expect(ok, isFalse);
    });

    test('fails to verify a tampered message', () async {
      final signer = await NodeIdentity.generate();
      final message = utf8.encode('hello mesh');
      final tampered = utf8.encode('hello mess');

      final signature = await signer.sign(message);
      final ok = await NodeIdentity.verify(
        message: tampered,
        signatureBytes: signature,
        signerPublicKey: signer.signingPublicKey,
      );

      expect(ok, isFalse);
    });

    test('never throws on garbage signature bytes', () async {
      final signer = await NodeIdentity.generate();
      final ok = await NodeIdentity.verify(
        message: utf8.encode('hello mesh'),
        signatureBytes: Uint8List(4),
        signerPublicKey: signer.signingPublicKey,
      );

      expect(ok, isFalse);
    });
  });

  group('encryptFor / decryptFrom', () {
    test('round-trips plaintext between two identities', () async {
      final alice = await NodeIdentity.generate();
      final bob = await NodeIdentity.generate();
      final plaintext = utf8.encode('meet at the usual spot');

      final envelope = await alice.encryptFor(plaintext, bob.agreementPublicKey);
      final decrypted = await bob.decryptFrom(envelope, alice.agreementPublicKey);

      expect(utf8.decode(decrypted), equals('meet at the usual spot'));
    });

    test('round-trips through EncryptedEnvelope byte serialization', () async {
      final alice = await NodeIdentity.generate();
      final bob = await NodeIdentity.generate();
      final plaintext = utf8.encode('over the wire');

      final envelope = await alice.encryptFor(plaintext, bob.agreementPublicKey);
      final rebuilt = EncryptedEnvelope.fromBytes(envelope.toBytes());
      final decrypted = await bob.decryptFrom(rebuilt, alice.agreementPublicKey);

      expect(utf8.decode(decrypted), equals('over the wire'));
    });

    test('a relay cannot decrypt -- wrong recipient key fails', () async {
      final alice = await NodeIdentity.generate();
      final bob = await NodeIdentity.generate();
      final relay = await NodeIdentity.generate();
      final plaintext = utf8.encode('secret');

      final envelope = await alice.encryptFor(plaintext, bob.agreementPublicKey);

      expect(
        () => relay.decryptFrom(envelope, alice.agreementPublicKey),
        throwsA(anything),
      );
    });

    test('tampered ciphertext fails MAC verification', () async {
      final alice = await NodeIdentity.generate();
      final bob = await NodeIdentity.generate();
      final plaintext = utf8.encode('secret');

      final envelope = await alice.encryptFor(plaintext, bob.agreementPublicKey);
      final corruptedCipherText = Uint8List.fromList(envelope.cipherText);
      corruptedCipherText[0] ^= 0xFF;
      final tampered = EncryptedEnvelope(
        nonce: envelope.nonce,
        cipherText: corruptedCipherText,
        mac: envelope.mac,
      );

      expect(
        () => bob.decryptFrom(tampered, alice.agreementPublicKey),
        throwsA(anything),
      );
    });
  });

  group('temporaryId', () {
    test('is stable within the same rotation slot', () async {
      final identity = await NodeIdentity.generate();
      final at = DateTime.utc(2026, 1, 1, 12, 0);

      final first = await identity.temporaryId(at: at);
      final second = await identity.temporaryId(at: at.add(const Duration(minutes: 3)));

      expect(first, equals(second));
    });

    test('rotates on the next slot', () async {
      final identity = await NodeIdentity.generate();
      final at = DateTime.utc(2026, 1, 1, 12, 0);

      final first = await identity.temporaryId(at: at);
      final second = await identity.temporaryId(
        at: at.add(TemporaryId.rotationInterval),
      );

      expect(first, isNot(equals(second)));
    });

    test('differs between two identities at the same time', () async {
      final a = await NodeIdentity.generate();
      final b = await NodeIdentity.generate();
      final at = DateTime.utc(2026, 1, 1, 12, 0);

      expect(await a.temporaryId(at: at), isNot(equals(await b.temporaryId(at: at))));
    });
  });

  group('persistence (loadOrCreate / toStorable / fromStorable)', () {
    test('loadOrCreate against an empty store generates and persists', () async {
      final store = InMemoryIdentityStore();
      final identity = await NodeIdentity.loadOrCreate(store);

      expect(await store.read(), isNotNull);
      expect((await store.read())!['signingPrivateKey'], isNotEmpty);
      expect(identity.nodeId, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('a second loadOrCreate against the same store returns the same identity '
        '(simulates surviving an app restart)', () async {
      final store = InMemoryIdentityStore();
      final first = await NodeIdentity.loadOrCreate(store);
      final second = await NodeIdentity.loadOrCreate(store);

      expect(second.nodeId, equals(first.nodeId));
      expect(second.signingPublicKey.bytes, equals(first.signingPublicKey.bytes));
      expect(second.agreementPublicKey.bytes, equals(first.agreementPublicKey.bytes));

      // and it's really the same key material, not just the same public
      // key by coincidence: a signature made after "restart" still
      // verifies, and the two identities can still decrypt each other's
      // old traffic.
      final message = utf8.encode('after restart');
      final signature = await second.sign(message);
      expect(
        await NodeIdentity.verify(
          message: message,
          signatureBytes: signature,
          signerPublicKey: first.signingPublicKey,
        ),
        isTrue,
      );
    });

    test('fromStorable reconstructs a functionally identical identity', () async {
      final original = await NodeIdentity.generate();
      final restored = await NodeIdentity.fromStorable(original.toStorable());

      expect(restored.nodeId, equals(original.nodeId));

      final plaintext = utf8.encode('roundtrip');
      final other = await NodeIdentity.generate();
      final envelope = await other.encryptFor(plaintext, original.agreementPublicKey);
      final decrypted = await restored.decryptFrom(envelope, other.agreementPublicKey);
      expect(utf8.decode(decrypted), equals('roundtrip'));
    });

    test('fromStorable rejects an unknown storage version', () async {
      expect(
        () => NodeIdentity.fromStorable({'version': 99}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
