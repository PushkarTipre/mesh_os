import 'packet_decode_exception.dart';

/// Routing priority (ARCHITECTURE.md §6, §18). Not yet acted on by any
/// scheduling/relay logic -- that lands with routing in a later
/// checkpoint -- but the wire format carries it from the start so packets
/// don't need a breaking format change when relay policies (e.g. "relay
/// emergency packets only") are implemented.
enum PacketPriority {
  low,
  normal,
  high,
  emergency;

  int get byteValue => index;

  static PacketPriority fromByte(int byte) {
    if (byte < 0 || byte >= PacketPriority.values.length) {
      throw PacketDecodeException('unknown packet priority byte: $byte');
    }
    return PacketPriority.values[byte];
  }
}
