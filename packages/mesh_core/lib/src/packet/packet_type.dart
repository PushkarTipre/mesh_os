import 'packet_decode_exception.dart';

/// The 7 packet types from ARCHITECTURE.md §6.
enum PacketType {
  discovery,
  data,
  broadcast,
  ack,
  sync,
  file,
  heartbeat;

  int get byteValue => index;

  static PacketType fromByte(int byte) {
    if (byte < 0 || byte >= PacketType.values.length) {
      throw PacketDecodeException('unknown packet type byte: $byte');
    }
    return PacketType.values[byte];
  }
}
