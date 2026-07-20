import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_core/testing.dart';

/// Runs a real 3-node mesh (Alice -- Bob -- Charlie, a line topology with
/// no direct Alice<->Charlie link) entirely in-process on this one device,
/// using the exact same `MeshLink`/`MeshOS`-layer code a real deployment
/// uses -- just over `FakeTransport` instead of `NearbyTransport`/
/// `BleTransport`.
///
/// **What running this proves:** the entire protocol stack -- identity,
/// crypto, handshake, multi-hop routing, relay, store-and-forward,
/// broadcast, and file transfer -- works correctly compiled into a real
/// Flutter app running on a real device (not just in `dart test` on a
/// laptop).
///
/// **What it can't prove:** that `NearbyTransport`/`BleTransport`
/// themselves work. That specifically requires two distinct physical
/// radios talking to each other over the air -- there is no single-device
/// substitute for it, no matter how good this screen is. See
/// NEXT_STEPS.md for the actual on-device (multi-phone) checklist.
class MeshSimulatorScreen extends StatefulWidget {
  const MeshSimulatorScreen({super.key});

  @override
  State<MeshSimulatorScreen> createState() => _MeshSimulatorScreenState();
}

class _SimNode {
  _SimNode({required this.label, required this.identity, required this.transport, required this.link});

  final String label;
  final NodeIdentity identity;
  final FakeTransport transport;
  final MeshLink link;
  final List<String> log = [];
  MeshLinkStats stats = const MeshLinkStats(
    packetsSent: 0,
    packetsReceived: 0,
    packetsRelayed: 0,
    bytesSent: 0,
    bytesReceived: 0,
    activeSessions: 0,
    storedRelayPackets: 0,
  );
}

class _MeshSimulatorScreenState extends State<MeshSimulatorScreen> {
  bool _ready = false;
  bool _bobOnline = true;
  bool _busy = false;
  // Deliberately separate from _busy -- taking Bob offline/online must
  // stay available even while a send is stuck waiting for him (that's
  // the whole point of the demo), so it can't share _busy with the
  // send/broadcast/file actions without deadlocking.
  bool _togglingBob = false;
  bool _linksCreated = false;

  late final _SimNode _alice;
  late final _SimNode _bob;
  late final _SimNode _charlie;
  late final FileTransferManager _aliceFiles;
  late final FileTransferManager _charlieFiles;

  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    unawaited(_setup());
  }

  Future<void> _setup() async {
    final network = FakeTransportNetwork();

    final aliceIdentity = await NodeIdentity.generate();
    final bobIdentity = await NodeIdentity.generate();
    final charlieIdentity = await NodeIdentity.generate();

    final aliceTransport = FakeTransport(network, name: 'sim');
    final bobTransport = FakeTransport(network, name: 'sim');
    final charlieTransport = FakeTransport(network, name: 'sim');

    _alice = _SimNode(
      label: 'Alice',
      identity: aliceIdentity,
      transport: aliceTransport,
      link: MeshLink(transport: aliceTransport, identity: aliceIdentity)..start(),
    );
    _bob = _SimNode(
      label: 'Bob',
      identity: bobIdentity,
      transport: bobTransport,
      link: MeshLink(transport: bobTransport, identity: bobIdentity)..start(),
    );
    _charlie = _SimNode(
      label: 'Charlie',
      identity: charlieIdentity,
      transport: charlieTransport,
      link: MeshLink(transport: charlieTransport, identity: charlieIdentity)..start(),
    );

    for (final node in [_alice, _bob, _charlie]) {
      _wireLogging(node);
    }

    _aliceFiles = FileTransferManager(link: _alice.link);
    _charlieFiles = FileTransferManager(link: _charlie.link);
    _subs.add(_charlieFiles.incomingFiles.listen((file) {
      _appendLog(_charlie, 'received file "${file.filename}" (${file.bytes.length} bytes) from ${_short(file.senderNodeId)}');
    }));
    _subs.add(_aliceFiles.outgoingProgress.listen((progress) {
      _appendLog(_alice, 'file "${progress.filename}": ${progress.status.name} ${(progress.fraction * 100).round()}%');
    }));

    // Everything that needs disposing now exists -- from this point on,
    // dispose() must clean it up even if the widget goes away before the
    // handshake dance below finishes (otherwise MeshLink's internal
    // periodic sweep timers leak).
    _linksCreated = true;

    // Alice and Charlie must meet directly once, so they're contacts --
    // multi-hop sendToNode needs the destination's public key on file,
    // same requirement as a real deployment (ARCHITECTURE.md §7).
    await _connectDirect(aliceTransport, charlieTransport, aId: 'alice', bId: 'charlie');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await aliceTransport.disconnect('charlie');
    await Future<void>.delayed(Duration.zero);

    // The real topology: Alice--Bob and Bob--Charlie, no direct link.
    await _connectDirect(aliceTransport, bobTransport, aId: 'alice', bId: 'bob');
    await _connectDirect(bobTransport, charlieTransport, aId: 'bob', bId: 'charlie');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    if (!mounted) return;
    setState(() => _ready = true);
  }

  Future<void> _connectDirect(FakeTransport a, FakeTransport b, {
    required String aId,
    required String bId,
  }) async {
    await a.startAdvertising(localId: aId);
    await b.startDiscovery(localId: bId);
    await Future<void>.delayed(Duration.zero);

    final aConnected = a.connectionEvents.firstWhere((e) => e.type == ConnectionEventType.connected);
    final bConnected = b.connectionEvents.firstWhere((e) => e.type == ConnectionEventType.connected);

    a.connectionEvents
        .firstWhere((e) => e.type == ConnectionEventType.incomingRequest)
        .then((e) => a.respondToConnectionRequest(e.remoteId, accept: true));

    await b.connect(aId);
    await aConnected;
    await bConnected;
  }

  void _wireLogging(_SimNode node) {
    _subs.add(node.link.messages.listen((msg) {
      if (msg.isFileChunk) return; // FileTransferManager already handles these
      final kind = msg.topic != null
          ? (msg.topic!.isEmpty ? 'broadcast' : 'publish[${msg.topic}]')
          : 'message';
      _appendLog(node, '$kind from ${_short(msg.senderNodeId)}: ${utf8.decode(msg.plaintext)}');
    }));
    _subs.add(node.link.sessionEstablished.listen((remoteId) {
      _appendLog(node, 'session established ($remoteId)');
    }));
    _subs.add(node.link.statsUpdates.listen((stats) {
      if (!mounted) return;
      setState(() => node.stats = stats);
    }));
  }

  void _appendLog(_SimNode node, String line) {
    if (!mounted) return;
    setState(() {
      node.log.insert(0, line);
      if (node.log.length > 20) node.log.removeLast();
    });
  }

  String _short(String nodeId) => nodeId.substring(0, 8);

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runToggle(Future<void> Function() action) async {
    if (_togglingBob) return;
    setState(() => _togglingBob = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _togglingBob = false);
    }
  }

  Future<void> _sendMessage() => _runAction(() async {
        final status = await _alice.link
            .sendToNode(_charlie.identity.nodeId, utf8.encode('Hello from Alice!'))
            .timeout(const Duration(seconds: 5), onTimeout: () => DeliveryStatus.failed);
        _appendLog(_alice, 'sendToNode(Charlie) -> ${status.name}');
      });

  Future<void> _broadcast() => _runAction(() async {
        await _alice.link.broadcast(utf8.encode('Broadcast from Alice'));
        _appendLog(_alice, 'broadcast sent');
      });

  Future<void> _sendFile() => _runAction(() async {
        final bytes = Uint8List.fromList(List<int>.generate(64 * 1024, (i) => i % 256));
        _aliceFiles.sendFile(nodeId: _charlie.identity.nodeId, filename: 'demo.bin', bytes: bytes);
        _appendLog(_alice, 'sendFile(Charlie) started (${bytes.length} bytes)');
      });

  Future<void> _toggleBob() => _runToggle(() async {
        if (_bobOnline) {
          await _bob.transport.disconnect('alice');
          await _bob.transport.disconnect('charlie');
          _appendLog(_bob, 'taken offline (simulating out of range)');
        } else {
          final aliceConnected =
              _alice.link.hasSession('bob') ? Future.value() : _reconnect(_alice.transport, _bob.transport, 'alice', 'bob');
          final charlieConnected = _charlie.link.hasSession('bob')
              ? Future.value()
              : _reconnect(_bob.transport, _charlie.transport, 'bob', 'charlie');
          await aliceConnected;
          await charlieConnected;
          _appendLog(_bob, 'back online');
        }
        setState(() => _bobOnline = !_bobOnline);
      });

  Future<void> _reconnect(FakeTransport a, FakeTransport b, String aId, String bId) async {
    final aConnected = a.connectionEvents.firstWhere((e) => e.type == ConnectionEventType.connected);
    final bConnected = b.connectionEvents.firstWhere((e) => e.type == ConnectionEventType.connected);
    a.connectionEvents
        .firstWhere((e) => e.type == ConnectionEventType.incomingRequest)
        .then((e) => a.respondToConnectionRequest(e.remoteId, accept: true));
    await b.connect(aId);
    await aConnected;
    await bConnected;
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    // Guard on _linksCreated, not _ready -- the links (and their internal
    // periodic sweep timers) exist and need disposing well before setup
    // fully completes and _ready flips true.
    if (_linksCreated) {
      _aliceFiles.dispose();
      _charlieFiles.dispose();
      _alice.link.dispose();
      _bob.link.dispose();
      _charlie.link.dispose();
      _alice.transport.dispose();
      _bob.transport.dispose();
      _charlie.transport.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mesh Simulator')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'This runs 3 simulated nodes in-process on this one device -- proves '
                    'the protocol (crypto, routing, relay, broadcast, file transfer) works '
                    'compiled into a real app. It does NOT prove NearbyTransport/BleTransport '
                    'work -- that needs two real phones with real radios. See NEXT_STEPS.md.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _busy ? null : _sendMessage,
                      child: const Text('Send: Alice → Charlie (via Bob)'),
                    ),
                    ElevatedButton(
                      onPressed: _busy ? null : _broadcast,
                      child: const Text('Broadcast from Alice'),
                    ),
                    ElevatedButton(
                      onPressed: _busy ? null : _sendFile,
                      child: const Text('Send file: Alice → Charlie'),
                    ),
                    ElevatedButton(
                      onPressed: _togglingBob ? null : _toggleBob,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _bobOnline ? null : Colors.red.shade100,
                      ),
                      child: Text(_bobOnline ? 'Take Bob offline' : 'Bring Bob back'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildNodeCard(_alice),
                _buildNodeCard(_bob, offline: !_bobOnline),
                _buildNodeCard(_charlie),
              ],
            ),
    );
  }

  Widget _buildNodeCard(_SimNode node, {bool offline = false}) {
    final stats = node.stats;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  node.label,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(width: 8),
                Text('(${_short(node.identity.nodeId)})',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                if (offline) ...[
                  const SizedBox(width: 8),
                  const Chip(label: Text('offline'), visualDensity: VisualDensity.compact),
                ],
              ],
            ),
            Text(
              'sent=${stats.packetsSent} received=${stats.packetsReceived} '
              'relayed=${stats.packetsRelayed} sessions=${stats.activeSessions} '
              'stored=${stats.storedRelayPackets}',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const Divider(),
            ...node.log.take(6).map(
                  (line) => Text(line, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                ),
            if (node.log.isEmpty)
              const Text('(no activity yet)', style: TextStyle(fontSize: 12, color: Colors.black38)),
          ],
        ),
      ),
    );
  }
}
