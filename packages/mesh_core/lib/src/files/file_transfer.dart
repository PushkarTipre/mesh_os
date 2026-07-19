import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../packet/packet_type.dart';
import '../session/mesh_link.dart';

const int _transferIdLength = 8;
const int _chunkHeaderLength = _transferIdLength + 4 + 4; // + chunkIndex + totalChunks

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _generateTransferId() {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(_transferIdLength, (_) => random.nextInt(256)));
}

Uint8List _encodeChunk({
  required Uint8List transferId,
  required int chunkIndex,
  required int totalChunks,
  required Uint8List payload,
}) {
  final buffer = Uint8List(_chunkHeaderLength + payload.length);
  buffer.setRange(0, _transferIdLength, transferId);
  final view = ByteData.sublistView(buffer);
  view.setUint32(_transferIdLength, chunkIndex, Endian.big);
  view.setUint32(_transferIdLength + 4, totalChunks, Endian.big);
  buffer.setRange(_chunkHeaderLength, buffer.length, payload);
  return buffer;
}

class _DecodedChunk {
  _DecodedChunk({
    required this.transferId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.payload,
  });

  final Uint8List transferId;
  final int chunkIndex;
  final int totalChunks;
  final Uint8List payload;
}

_DecodedChunk? _decodeChunk(Uint8List bytes) {
  if (bytes.length < _chunkHeaderLength) return null;
  final view = ByteData.sublistView(bytes);
  return _DecodedChunk(
    transferId: Uint8List.fromList(bytes.sublist(0, _transferIdLength)),
    chunkIndex: view.getUint32(_transferIdLength, Endian.big),
    totalChunks: view.getUint32(_transferIdLength + 4, Endian.big),
    payload: Uint8List.fromList(bytes.sublist(_chunkHeaderLength)),
  );
}

/// Outcome of one [FileTransferManager.sendFile] call, as reported on
/// [FileTransferManager.outgoingProgress].
enum FileTransferStatus {
  /// Actively sending chunks, or waiting to resume.
  inProgress,

  /// A chunk send failed or timed out -- stalled until a reconnect to the
  /// destination (see [FileTransferManager]'s class doc) resumes it from
  /// [FileTransferProgress.bytesTransferred], not from scratch.
  paused,

  /// Every chunk was acknowledged.
  completed,
}

class FileTransferProgress {
  const FileTransferProgress({
    required this.transferId,
    required this.filename,
    required this.totalBytes,
    required this.bytesTransferred,
    required this.status,
  });

  final String transferId;
  final String filename;
  final int totalBytes;
  final int bytesTransferred;
  final FileTransferStatus status;

  /// 1.0 for a zero-byte file regardless of [status] -- there's no
  /// meaningful partial progress to report for it.
  double get fraction => totalBytes == 0 ? 1.0 : bytesTransferred / totalBytes;
}

/// A fully reassembled file received from a peer, surfaced once every
/// chunk has arrived.
class IncomingFile {
  const IncomingFile({
    required this.transferId,
    required this.senderNodeId,
    required this.filename,
    required this.bytes,
  });

  final String transferId;
  final String senderNodeId;
  final String filename;
  final Uint8List bytes;
}

class _OutgoingTransfer {
  _OutgoingTransfer({
    required this.transferIdHex,
    required this.transferId,
    required this.nodeId,
    required this.filename,
    required this.totalBytes,
    required this.chunks,
  });

  final String transferIdHex;
  final Uint8List transferId;
  final String nodeId;
  final String filename;
  final int totalBytes;

  /// Index 0 is JSON metadata (filename/totalBytes); 1..N are file data
  /// slices. Chunking the metadata the same way as the data means the
  /// receiver doesn't need a separate message type to learn the filename.
  final List<Uint8List> chunks;

  int nextChunkIndex = 0;
  int bytesTransferred = 0;
  FileTransferStatus status = FileTransferStatus.inProgress;
}

class _IncomingMeta {
  _IncomingMeta({required this.filename, required this.senderNodeId});

  final String filename;
  final String senderNodeId;
}

/// Chunked file transfer built entirely on top of [MeshLink.sendToNode] --
/// it reuses that method's existing encryption, direct/routed addressing,
/// and hop-by-hop or end-to-end acking rather than inventing a parallel
/// reliability mechanism. Each chunk is just an ordinary [MeshLink]
/// message tagged [PacketType.file] instead of [PacketType.data], purely
/// so the receiving side's [MeshLink.messages] can flag it via
/// [InboundMessage.isFileChunk] and this class can intercept it before it
/// reaches application listeners (raw chunk bytes aren't meaningful on
/// their own).
///
/// Chunks for one transfer are sent strictly in order, awaiting each
/// chunk's [DeliveryStatus] before sending the next -- simpler than a
/// sliding window, and file transfer isn't latency-sensitive the way
/// interactive chat is. Each `sendToNode` call is bounded to 15 seconds
/// (rather than inheriting its up-to-24-hour store-and-forward default)
/// so a transfer stalls into [FileTransferStatus.paused] promptly instead
/// of hanging; because every attempt uses a fresh packet ID, a
/// late-arriving ack for a timed-out attempt is simply ignored by
/// [MeshLink], never double-counted. A paused transfer resumes
/// automatically from its last acked chunk the next time [MeshLink]
/// reports a completed handshake ([MeshLink.sessionEstablished]) with the
/// same destination node.
class FileTransferManager {
  FileTransferManager({required this.link}) {
    _messagesSub = link.messages.listen(_onMessage);
    _sessionSub = link.sessionEstablished.listen(_onSessionEstablished);
  }

  final MeshLink link;

  final Map<String, _OutgoingTransfer> _outgoing = {};
  final Map<String, Map<int, Uint8List>> _incomingChunks = {};
  final Map<String, _IncomingMeta> _incomingMeta = {};

  final StreamController<FileTransferProgress> _outgoingProgress =
      StreamController.broadcast();
  final StreamController<IncomingFile> _incomingFiles = StreamController.broadcast();

  StreamSubscription<InboundMessage>? _messagesSub;
  StreamSubscription<String>? _sessionSub;

  Stream<FileTransferProgress> get outgoingProgress => _outgoingProgress.stream;

  Stream<IncomingFile> get incomingFiles => _incomingFiles.stream;

  /// Starts sending [bytes] to [nodeId] as [filename], chunked at
  /// [chunkSize] bytes. Returns immediately with a transfer id; track
  /// progress via [outgoingProgress]. Requires [nodeId] to already be a
  /// known contact, same as [MeshLink.sendToNode].
  String sendFile({
    required String nodeId,
    required String filename,
    required Uint8List bytes,
    int chunkSize = 16 * 1024,
  }) {
    final transferId = _generateTransferId();
    final transferIdHex = _bytesToHex(transferId);

    final dataChunks = <Uint8List>[];
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = min(offset + chunkSize, bytes.length);
      dataChunks.add(Uint8List.sublistView(bytes, offset, end));
    }
    if (dataChunks.isEmpty) dataChunks.add(Uint8List(0)); // zero-byte file: one empty chunk

    final metaBytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'filename': filename, 'totalBytes': bytes.length})),
    );

    final transfer = _OutgoingTransfer(
      transferIdHex: transferIdHex,
      transferId: transferId,
      nodeId: nodeId,
      filename: filename,
      totalBytes: bytes.length,
      chunks: [metaBytes, ...dataChunks],
    );
    _outgoing[transferIdHex] = transfer;

    unawaited(_continueTransfer(transferIdHex));
    return transferIdHex;
  }

  Future<void> _continueTransfer(String transferIdHex) async {
    final transfer = _outgoing[transferIdHex];
    if (transfer == null || transfer.status == FileTransferStatus.completed) return;
    transfer.status = FileTransferStatus.inProgress;

    while (transfer.nextChunkIndex < transfer.chunks.length) {
      final index = transfer.nextChunkIndex;
      final chunkPayload = _encodeChunk(
        transferId: transfer.transferId,
        chunkIndex: index,
        totalChunks: transfer.chunks.length,
        payload: transfer.chunks[index],
      );

      DeliveryStatus status;
      try {
        status = await link
            .sendToNode(transfer.nodeId, chunkPayload, type: PacketType.file)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        status = DeliveryStatus.failed;
      }

      if (status != DeliveryStatus.delivered) {
        transfer.status = FileTransferStatus.paused;
        _emitOutgoingProgress(transfer);
        return;
      }

      if (index > 0) {
        // Index 0 is metadata, not user-visible file content.
        transfer.bytesTransferred += transfer.chunks[index].length;
      }
      transfer.nextChunkIndex += 1;
      _emitOutgoingProgress(transfer);
    }

    transfer.status = FileTransferStatus.completed;
    _emitOutgoingProgress(transfer);
  }

  void _emitOutgoingProgress(_OutgoingTransfer transfer) {
    _outgoingProgress.add(FileTransferProgress(
      transferId: transfer.transferIdHex,
      filename: transfer.filename,
      totalBytes: transfer.totalBytes,
      bytesTransferred: transfer.bytesTransferred,
      status: transfer.status,
    ));
  }

  void _onSessionEstablished(String remoteId) {
    String? nodeId;
    for (final session in link.sessions) {
      if (session.remoteId == remoteId) {
        nodeId = session.nodeId;
        break;
      }
    }
    if (nodeId == null) return;

    for (final transfer in _outgoing.values.toList()) {
      if (transfer.nodeId == nodeId && transfer.status == FileTransferStatus.paused) {
        unawaited(_continueTransfer(transfer.transferIdHex));
      }
    }
  }

  void _onMessage(InboundMessage message) {
    if (!message.isFileChunk) return;
    final decoded = _decodeChunk(message.plaintext);
    if (decoded == null) return; // malformed -- drop

    final transferIdHex = _bytesToHex(decoded.transferId);
    final chunksForTransfer = _incomingChunks.putIfAbsent(transferIdHex, () => {});
    chunksForTransfer[decoded.chunkIndex] = decoded.payload;

    if (decoded.chunkIndex == 0) {
      try {
        final meta = jsonDecode(utf8.decode(decoded.payload)) as Map<String, dynamic>;
        _incomingMeta[transferIdHex] = _IncomingMeta(
          filename: meta['filename'] as String,
          senderNodeId: message.senderNodeId,
        );
      } catch (_) {
        // Malformed metadata -- this transfer can never be reassembled
        // meaningfully; drop what we've buffered for it.
        _incomingChunks.remove(transferIdHex);
        return;
      }
    }

    if (chunksForTransfer.length != decoded.totalChunks) return; // still waiting on more
    for (var i = 0; i < decoded.totalChunks; i++) {
      if (!chunksForTransfer.containsKey(i)) return; // gap -- still waiting
    }
    final meta = _incomingMeta[transferIdHex];
    if (meta == null) return; // chunk 0 (metadata) hasn't arrived yet

    final builder = BytesBuilder();
    for (var i = 1; i < decoded.totalChunks; i++) {
      builder.add(chunksForTransfer[i]!);
    }

    _incomingFiles.add(IncomingFile(
      transferId: transferIdHex,
      senderNodeId: meta.senderNodeId,
      filename: meta.filename,
      bytes: builder.toBytes(),
    ));

    _incomingChunks.remove(transferIdHex);
    _incomingMeta.remove(transferIdHex);
  }

  Future<void> dispose() async {
    await _messagesSub?.cancel();
    await _sessionSub?.cancel();
    await _outgoingProgress.close();
    await _incomingFiles.close();
  }
}
