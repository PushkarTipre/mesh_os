/// Thrown when bytes cannot be decoded into a valid packet or fragment --
/// truncated buffers, unsupported versions, unknown type bytes, or a
/// checksum mismatch. Decoders guarantee they throw this (never a raw
/// [RangeError] or other low-level error) for any malformed input.
class PacketDecodeException implements Exception {
  const PacketDecodeException(this.message);

  final String message;

  @override
  String toString() => 'PacketDecodeException: $message';
}
