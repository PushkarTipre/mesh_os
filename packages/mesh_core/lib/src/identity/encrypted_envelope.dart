import 'dart:typed_data';

/// The output of [NodeIdentity.encryptFor]: a nonce, ciphertext, and AEAD
/// authentication tag, serializable to a flat byte buffer for transport.
class EncryptedEnvelope {
  const EncryptedEnvelope({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  static const int nonceLength = 12;
  static const int macLength = 16;

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  Uint8List toBytes() {
    final builder = BytesBuilder()
      ..add(nonce)
      ..add(mac)
      ..add(cipherText);
    return builder.toBytes();
  }

  factory EncryptedEnvelope.fromBytes(List<int> bytes) {
    if (bytes.length < nonceLength + macLength) {
      throw const FormatException('EncryptedEnvelope: buffer too short');
    }
    return EncryptedEnvelope(
      nonce: Uint8List.fromList(bytes.sublist(0, nonceLength)),
      cipherText: Uint8List.fromList(
        bytes.sublist(nonceLength + macLength),
      ),
      mac: Uint8List.fromList(
        bytes.sublist(nonceLength, nonceLength + macLength),
      ),
    );
  }
}
