import 'dart:typed_data';

import 'packet_decode_exception.dart';

/// One chunk of a [MeshPacket] that was too large for a transport's MTU
/// (ARCHITECTURE.md §6, §11). Transport-agnostic -- it just carries
/// opaque bytes; what those bytes decode to (a `MeshPacket`, typically) is
/// not this layer's concern.
class Fragment {
  const Fragment({
    required this.messageId,
    required this.index,
    required this.count,
    required this.data,
  });

  static const int headerLength = 8;

  /// Groups fragments belonging to the same original message.
  final int messageId;

  /// 0-based position of this fragment among [count] total.
  final int index;

  final int count;

  final Uint8List data;

  Uint8List toBytes() {
    final buffer = Uint8List(headerLength + data.length);
    final view = ByteData.sublistView(buffer);
    view.setUint32(0, messageId, Endian.big);
    view.setUint16(4, index, Endian.big);
    view.setUint16(6, count, Endian.big);
    buffer.setRange(headerLength, buffer.length, data);
    return buffer;
  }

  factory Fragment.fromBytes(List<int> rawBytes) {
    final bytes = rawBytes is Uint8List ? rawBytes : Uint8List.fromList(rawBytes);
    if (bytes.length < headerLength) {
      throw PacketDecodeException(
        'fragment buffer too short: ${bytes.length} bytes, need at least $headerLength',
      );
    }
    final view = ByteData.sublistView(bytes);
    return Fragment(
      messageId: view.getUint32(0, Endian.big),
      index: view.getUint16(4, Endian.big),
      count: view.getUint16(6, Endian.big),
      data: Uint8List.fromList(bytes.sublist(headerLength)),
    );
  }
}
