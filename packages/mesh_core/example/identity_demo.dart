// Run with: dart run example/identity_demo.dart
// Demonstrates what a NodeIdentity actually produces: two devices ("Alice"
// and "Bob") generate identities, Alice signs and encrypts a message for
// Bob, and Bob verifies and decrypts it.
import 'dart:convert';

import 'package:mesh_core/mesh_core.dart';

Future<void> main() async {
  final alice = await NodeIdentity.generate();
  final bob = await NodeIdentity.generate();

  print('Alice node ID: ${alice.nodeId}');
  print('Bob   node ID: ${bob.nodeId}');
  print('');
  print('Alice signing public key: ${base64Encode(alice.signingPublicKey.bytes)}');
  print('Alice agreement public key: ${base64Encode(alice.agreementPublicKey.bytes)}');
  print('');

  print('Alice temporary ID (this slot): ${await alice.temporaryId()}');
  print('Bob   temporary ID (this slot): ${await bob.temporaryId()}');
  print('');

  final message = utf8.encode('Meet at the water tower at 6pm.');
  final signature = await alice.sign(message);
  print('Message: "Meet at the water tower at 6pm."');
  print('Signature (base64): ${base64Encode(signature)}');

  final signatureValid = await NodeIdentity.verify(
    message: message,
    signatureBytes: signature,
    signerPublicKey: alice.signingPublicKey,
  );
  print('Bob verifies signature is really Alice\'s: $signatureValid');
  print('');

  final envelope = await alice.encryptFor(message, bob.agreementPublicKey);
  print('Encrypted envelope (what a relay actually sees on the wire):');
  print('  nonce:      ${base64Encode(envelope.nonce)}');
  print('  ciphertext: ${base64Encode(envelope.cipherText)}');
  print('  mac:        ${base64Encode(envelope.mac)}');
  print('');

  final decrypted = await bob.decryptFrom(envelope, alice.agreementPublicKey);
  print('Bob decrypts it back to: "${utf8.decode(decrypted)}"');
  print('');

  print('--- What a relay node with no keys sees ---');
  final relay = await NodeIdentity.generate();
  try {
    await relay.decryptFrom(envelope, alice.agreementPublicKey);
    print('ERROR: relay should not have been able to decrypt this!');
  } catch (e) {
    print('Relay tried to decrypt and failed, as expected: $e');
  }
  print('');

  print('--- Identity survives a restart ---');
  final store = InMemoryIdentityStore();
  final aliceRun1 = await NodeIdentity.loadOrCreate(store);
  final aliceRun2 = await NodeIdentity.loadOrCreate(store); // "app restarted"
  print('First launch node ID:  ${aliceRun1.nodeId}');
  print('Second launch node ID: ${aliceRun2.nodeId}');
  print('Same identity: ${aliceRun1.nodeId == aliceRun2.nodeId}');
}
