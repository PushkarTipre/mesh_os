import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';

/// CP9's "network topology debug view + mesh analytics" -- a live look at
/// what this node's [MeshOS] instance is actually doing, for development
/// and demoing. Deliberately plain (lists and numbers, not a graph
/// renderer): per ROADMAP.md's own guidance, `mesh_console` is an
/// instrument panel, not a product, and a real topology graph is more
/// than a dev harness needs.
class MeshDebugScreen extends StatefulWidget {
  const MeshDebugScreen({super.key, required this.mesh});

  final MeshOS mesh;

  @override
  State<MeshDebugScreen> createState() => _MeshDebugScreenState();
}

class _MeshDebugScreenState extends State<MeshDebugScreen> {
  MeshLinkStats? _stats;
  List<MeshDevice> _devices = const [];
  List<Contact> _contacts = const [];

  StreamSubscription<MeshLinkStats>? _statsSub;
  StreamSubscription<List<MeshDevice>>? _deviceSub;
  StreamSubscription<List<Contact>>? _contactSub;

  @override
  void initState() {
    super.initState();
    _stats = widget.mesh.stats;
    _devices = widget.mesh.devices;
    _statsSub = widget.mesh.statsUpdates.listen((stats) {
      if (!mounted) return;
      setState(() => _stats = stats);
    });
    _deviceSub = widget.mesh.deviceUpdates.listen((devices) {
      if (!mounted) return;
      setState(() => _devices = devices);
    });
    _contactSub = widget.mesh.contactUpdates.listen((contacts) {
      if (!mounted) return;
      setState(() => _contacts = contacts);
    });
    widget.mesh.contacts.then((contacts) {
      if (!mounted) return;
      setState(() => _contacts = contacts);
    });
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    _deviceSub?.cancel();
    _contactSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final directlyConnected = _devices.where((d) => d.sessionReady).toList();
    final nearbyNodeIds = _devices.map((d) => d.nodeId).whereType<String>().toSet();
    final reachableViaRelay = _contacts.where((c) => !nearbyNodeIds.contains(c.nodeId)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Mesh debug')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _sectionHeader('This node'),
          _kv('Node ID', widget.mesh.identity.nodeId),
          const SizedBox(height: 12),
          _sectionHeader('Activity'),
          if (stats == null)
            const Text('No activity yet')
          else ...[
            _kv('Packets sent', '${stats.packetsSent}'),
            _kv('Packets received', '${stats.packetsReceived}'),
            _kv('Packets relayed for others', '${stats.packetsRelayed}'),
            _kv('Bytes sent', _formatBytes(stats.bytesSent)),
            _kv('Bytes received', _formatBytes(stats.bytesReceived)),
            _kv('Active sessions', '${stats.activeSessions}'),
            _kv('Packets held for store-and-forward', '${stats.storedRelayPackets}'),
          ],
          const SizedBox(height: 12),
          _sectionHeader('Directly connected (${directlyConnected.length})'),
          if (directlyConnected.isEmpty)
            const Text('None')
          else
            ...directlyConnected.map(_buildDeviceRow),
          const SizedBox(height: 12),
          _sectionHeader('Reachable via relay (${reachableViaRelay.length})'),
          if (reachableViaRelay.isEmpty)
            const Text('None')
          else
            ...reachableViaRelay.map(_buildContactRow),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 220, child: Text(key)),
            Expanded(
              child: Text(value, style: const TextStyle(fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  Widget _buildDeviceRow(MeshDevice device) {
    final label = device.displayName ?? device.nodeId ?? device.remoteId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '$label · ${device.trustLevel.name} · remoteId=${device.remoteId}',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  Widget _buildContactRow(Contact contact) {
    final label = contact.displayName ?? contact.nodeId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '$label · ${contact.trustLevel.name} · via relay',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
