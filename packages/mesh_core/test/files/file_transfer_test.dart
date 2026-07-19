import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import '../transport/fake_transport.dart';

/// Connects [a] to [b] directly (advertise/discover/connect/accept) and
/// returns once both sides report a live connection.
Future<void> _connect(FakeTransport a, FakeTransport b, {
  required String aId,
  required String bId,
}) async {
  await a.startAdvertising(localId: aId);
  await b.startDiscovery(localId: bId);
  await Future<void>.delayed(Duration.zero);

  final aConnected = a.connectionEvents.firstWhere(
    (e) => e.type == ConnectionEventType.connected,
  );
  final bConnected = b.connectionEvents.firstWhere(
    (e) => e.type == ConnectionEventType.connected,
  );

  a.connectionEvents
      .firstWhere((e) => e.type == ConnectionEventType.incomingRequest)
      .then((e) => a.respondToConnectionRequest(e.remoteId, accept: true));

  await b.connect(aId);
  await aConnected;
  await bConnected;
}

void main() {
  group('FileTransferManager: basic transfer', () {
    test('a small file arrives byte-for-byte with the right filename and sender', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final managerA = FileTransferManager(link: linkA);
      final managerB = FileTransferManager(link: linkB);

      final fileBytes = Uint8List.fromList('hello from a file'.codeUnits);
      final incomingFuture = managerB.incomingFiles.first;
      final outgoingDone = managerA.outgoingProgress.firstWhere(
        (p) => p.status == FileTransferStatus.completed,
      );

      managerA.sendFile(nodeId: identityB.nodeId, filename: 'note.txt', bytes: fileBytes);

      final incoming = await incomingFuture.timeout(const Duration(seconds: 2));
      expect(incoming.filename, equals('note.txt'));
      expect(incoming.senderNodeId, equals(identityA.nodeId));
      expect(incoming.bytes, equals(fileBytes));

      // A's own side isn't "done" until its final ack round-trips back --
      // wait for that before tearing down, or the in-flight completion
      // would try to emit progress on an already-closed controller.
      await outgoingDone.timeout(const Duration(seconds: 2));

      await managerA.dispose();
      await managerB.dispose();
      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('a file larger than the chunk size is split, reassembled in order, and reports '
        'completed progress', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final managerA = FileTransferManager(link: linkA);
      final managerB = FileTransferManager(link: linkB);

      // 5 chunks' worth at chunkSize: 1000 -- forces genuine multi-chunk
      // splitting and reassembly, not just a single round trip.
      final fileBytes = Uint8List.fromList(List<int>.generate(4500, (i) => i % 256));

      final progressEvents = <FileTransferProgress>[];
      managerA.outgoingProgress.listen(progressEvents.add);

      final incomingFuture = managerB.incomingFiles.first;
      managerA.sendFile(
        nodeId: identityB.nodeId,
        filename: 'photo.bin',
        bytes: fileBytes,
        chunkSize: 1000,
      );

      final incoming = await incomingFuture.timeout(const Duration(seconds: 2));
      expect(incoming.bytes, equals(fileBytes));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(progressEvents.last.status, equals(FileTransferStatus.completed));
      expect(progressEvents.last.bytesTransferred, equals(fileBytes.length));
      expect(progressEvents.last.fraction, equals(1.0));

      await managerA.dispose();
      await managerB.dispose();
      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });

    test('a zero-byte file still transfers and reassembles to empty bytes', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final managerA = FileTransferManager(link: linkA);
      final managerB = FileTransferManager(link: linkB);

      final incomingFuture = managerB.incomingFiles.first;
      final outgoingDone = managerA.outgoingProgress.firstWhere(
        (p) => p.status == FileTransferStatus.completed,
      );
      managerA.sendFile(nodeId: identityB.nodeId, filename: 'empty.txt', bytes: Uint8List(0));

      final incoming = await incomingFuture.timeout(const Duration(seconds: 2));
      expect(incoming.bytes, isEmpty);
      expect(incoming.filename, equals('empty.txt'));

      await outgoingDone.timeout(const Duration(seconds: 2));

      await managerA.dispose();
      await managerB.dispose();
      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });
  });

  group('FileTransferManager: interruption and resume', () {
    test('a transfer interrupted mid-flight (ack lost, then connection dropped) pauses, '
        'then resumes and completes once reconnected -- with no corruption or loss',
        () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final managerA = FileTransferManager(link: linkA);
      final managerB = FileTransferManager(link: linkB);

      // A single data chunk (+1 metadata chunk) -- keeps the scenario
      // deterministic: sabotage B's very first ack (the metadata chunk's)
      // *before* the transfer even starts, then sever the connection
      // before A's retry timer would otherwise fire. This models "the
      // ack never made it back before the phones walked out of range."
      final fileBytes = Uint8List.fromList(List<int>.generate(500, (i) => i % 256));
      transportB.dropNextSends(1);

      final progressEvents = <FileTransferProgress>[];
      managerA.outgoingProgress.listen(progressEvents.add);

      managerA.sendFile(
        nodeId: identityB.nodeId,
        filename: 'interrupted.bin',
        bytes: fileBytes,
        chunkSize: fileBytes.length,
      );

      // Give the data + swallowed-ack round trip a moment, then cut the
      // connection well before the (2s default) retry timer would fire.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await transportA.disconnect('B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(progressEvents.last.status, equals(FileTransferStatus.paused));

      final incomingFuture = managerB.incomingFiles.first;

      // Phones come back into range -- MeshLink.sessionEstablished fires
      // once the fresh handshake completes, which is what triggers resume.
      await _connect(transportA, transportB, aId: 'A', bId: 'B');

      final incoming = await incomingFuture.timeout(const Duration(seconds: 5));
      expect(incoming.bytes, equals(fileBytes));
      expect(incoming.filename, equals('interrupted.bin'));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(progressEvents.last.status, equals(FileTransferStatus.completed));
      expect(progressEvents.last.bytesTransferred, equals(fileBytes.length));

      await managerA.dispose();
      await managerB.dispose();
      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });
  });

  group('FileTransferManager: non-chunk messages are left alone', () {
    test('an ordinary sendData message never reaches incomingFiles', () async {
      final network = FakeTransportNetwork();
      final transportA = FakeTransport(network);
      final transportB = FakeTransport(network);
      final identityA = await NodeIdentity.generate();
      final identityB = await NodeIdentity.generate();

      final linkA = MeshLink(transport: transportA, identity: identityA)..start();
      final linkB = MeshLink(transport: transportB, identity: identityB)..start();

      await _connect(transportA, transportB, aId: 'A', bId: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final managerB = FileTransferManager(link: linkB);
      final incomingSeen = <IncomingFile>[];
      managerB.incomingFiles.listen(incomingSeen.add);

      final received = linkB.messages.first;
      await linkA.sendData('B', 'just a chat message'.codeUnits);
      await received.timeout(const Duration(seconds: 2));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(incomingSeen, isEmpty);

      await managerB.dispose();
      await linkA.dispose();
      await linkB.dispose();
      await transportA.dispose();
      await transportB.dispose();
    });
  });
}
