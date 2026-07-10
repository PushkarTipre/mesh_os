import 'dart:typed_data';

/// Standard IEEE 802.3 CRC-32, used as a cheap per-hop transmission
/// integrity check on packets -- catches radio bit-flips before spending
/// time on signature verification. Not a security mechanism; authenticity
/// comes from the Ed25519 signature, not this checksum.
class Crc32 {
  const Crc32._();

  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      table[i] = c;
    }
    return table;
  }

  static int compute(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }
}
