import 'dart:math';
import 'dart:typed_data';

import 'fragment.dart';

/// Splits an opaque byte buffer into [Fragment]s no larger than a
/// transport's usable MTU. Written and tested here against synthetic MTU
/// sizes; wired into a real transport's negotiated MTU in a later
/// checkpoint (ARCHITECTURE.md §11).
class Fragmenter {
  const Fragmenter._();

  /// Splits [data] into fragments carrying at most [maxChunkSize] bytes of
  /// data each (not counting the 8-byte fragment header). An empty [data]
  /// still produces exactly one (empty) fragment, so reassembly always has
  /// something to key off of.
  static List<Fragment> split(List<int> data, {required int maxChunkSize}) {
    if (maxChunkSize <= 0) {
      throw ArgumentError.value(maxChunkSize, 'maxChunkSize', 'must be positive');
    }
    final messageId = _generateMessageId();
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final chunkCount = bytes.isEmpty ? 1 : (bytes.length / maxChunkSize).ceil();

    return List<Fragment>.generate(chunkCount, (i) {
      final start = i * maxChunkSize;
      final end = min(start + maxChunkSize, bytes.length);
      return Fragment(
        messageId: messageId,
        index: i,
        count: chunkCount,
        data: Uint8List.sublistView(bytes, start, end),
      );
    });
  }

  static int _generateMessageId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(4, (_) => random.nextInt(256)),
    );
    return ByteData.sublistView(bytes).getUint32(0, Endian.big);
  }
}
