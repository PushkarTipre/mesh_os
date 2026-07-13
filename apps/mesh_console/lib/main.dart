import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';
import 'package:mesh_transport_nearby/mesh_transport_nearby.dart';

void main() {
  runApp(const MeshConsoleApp());
}

class MeshConsoleApp extends StatelessWidget {
  const MeshConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshOS Console',
      home: const ConsoleScreen(),
    );
  }
}

/// CP3 exit-criterion demo: two Android phones running this screen should
/// discover each other over Nearby Connections, connect, complete the
/// MeshLink discovery handshake automatically, and exchange signed,
/// encrypted test packets -- with the log showing verify+decrypt success
/// on both sides. See ROADMAP.md Checkpoint 3.
///
/// This is a raw instrument panel, not a product screen: every nearby
/// MeshOS node is auto-accepted on connection request (trust/contacts is
/// a later checkpoint -- ARCHITECTURE.md §7, §9), and the temporary ID is
/// computed once at launch rather than rotated.
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key});

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  final _identityStore = SecureStorageIdentityStore();

  NodeIdentity? _identity;
  String? _temporaryId;
  NearbyTransport? _transport;
  MeshLink? _link;
  bool _permissionsGranted = false;
  String? _bootstrapError;

  final Map<String, DeviceEvent> _discovered = {};
  final Set<String> _connected = {};
  final Set<String> _sessioned = {};
  final List<String> _log = [];

  StreamSubscription<DeviceEvent>? _deviceSub;
  StreamSubscription<ConnectionEvent>? _connectionSub;
  StreamSubscription<InboundMessage>? _messageSub;
  StreamSubscription<String>? _sessionSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _connectionSub?.cancel();
    _messageSub?.cancel();
    _sessionSub?.cancel();
    _link?.dispose();
    _transport?.dispose();
    super.dispose();
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, '[${_timestamp()}] $line'));
  }

  Future<void> _bootstrap() async {
    try {
      final identity = await NodeIdentity.loadOrCreate(_identityStore);
      // Computed once per launch -- real temp-ID rotation handling is a
      // later checkpoint (ARCHITECTURE.md §6).
      final tempId = await identity.temporaryId();

      final granted = await NearbyPermissions.requestAll();

      final transport = NearbyTransport();
      final link = MeshLink(transport: transport, identity: identity)..start();

      _deviceSub = transport.deviceEvents.listen(_onDeviceEvent);
      _connectionSub = transport.connectionEvents.listen(_onConnectionEvent);
      _messageSub = link.messages.listen(_onMessage);
      _sessionSub = link.sessionEstablished.listen(_onSessionEstablished);

      setState(() {
        _identity = identity;
        _temporaryId = tempId;
        _permissionsGranted = granted;
        _transport = transport;
        _link = link;
      });

      _appendLog('Identity ready. Node ID: ${identity.nodeId}');
      _appendLog('Temporary ID: $tempId');

      if (!granted) {
        _appendLog(
          'WARNING: not all Nearby permissions were granted -- advertising/discovery will likely fail.',
        );
        return;
      }

      await transport.startAdvertising(localId: tempId);
      await transport.startDiscovery(localId: tempId);
      _appendLog('Advertising and discovering as $tempId');
    } catch (e) {
      setState(() => _bootstrapError = '$e');
      _appendLog('Bootstrap failed: $e');
    }
  }

  void _onDeviceEvent(DeviceEvent event) {
    setState(() {
      if (event.type == DeviceEventType.found) {
        _discovered[event.remoteId] = event;
      } else {
        _discovered.remove(event.remoteId);
      }
    });
    final action = event.type == DeviceEventType.found ? 'found' : 'lost';
    _appendLog('Device $action: ${event.remoteId} (${event.advertisedName ?? '?'})');
  }

  Future<void> _onConnectionEvent(ConnectionEvent event) async {
    _appendLog('Connection event: ${event.type} (${event.remoteId})');
    switch (event.type) {
      case ConnectionEventType.incomingRequest:
        await _transport?.respondToConnectionRequest(event.remoteId, accept: true);
        _appendLog('Auto-accepted connection request from ${event.remoteId}');
      case ConnectionEventType.connected:
        setState(() => _connected.add(event.remoteId));
      case ConnectionEventType.disconnected:
      case ConnectionEventType.failed:
        setState(() {
          _connected.remove(event.remoteId);
          _sessioned.remove(event.remoteId);
        });
    }
  }

  void _onSessionEstablished(String remoteId) {
    setState(() => _sessioned.add(remoteId));
    _appendLog(
      'Discovery handshake complete with $remoteId -- signature verified, session ready',
    );
  }

  void _onMessage(InboundMessage message) {
    _appendLog(
      'Received from ${message.remoteId}: "${utf8.decode(message.plaintext)}" '
      '(signature verified, decrypted OK)',
    );
  }

  Future<void> _connectTo(String remoteId) async {
    _appendLog('Connecting to $remoteId ...');
    await _transport?.connect(remoteId);
  }

  Future<void> _disconnectFrom(String remoteId) async {
    await _transport?.disconnect(remoteId);
  }

  Future<void> _sendTestPacket(String remoteId) async {
    final message = 'Hello from ${_temporaryId ?? '?'} at ${_timestamp()}';
    try {
      await _link?.sendData(remoteId, utf8.encode(message));
      _appendLog('Sent to $remoteId: "$message" (signed + encrypted)');
    } catch (e) {
      _appendLog('Send to $remoteId failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MeshOS Console')),
      body: _identity == null && _bootstrapError == null
          ? const Center(child: CircularProgressIndicator())
          : _bootstrapError != null
              ? Center(child: Text('Bootstrap failed: $_bootstrapError'))
              : _buildConsole(),
    );
  }

  Widget _buildConsole() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIdentityCard(),
        const Divider(height: 1),
        Expanded(
          flex: 2,
          child: ListView(
            children: [
              _sectionHeader('Nearby devices (${_discovered.length})'),
              ..._discovered.values.map(_buildDeviceTile),
              _sectionHeader('Connected peers (${_connected.length})'),
              ..._connected.map(_buildConnectedTile),
            ],
          ),
        ),
        const Divider(height: 1),
        _sectionHeader('Log'),
        Expanded(
          flex: 3,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _log.length,
            itemBuilder: (context, index) => Text(
              _log[index],
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildIdentityCard() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Node ID: ${_identity!.nodeId}', style: const TextStyle(fontFamily: 'monospace')),
          Text(
            'Temporary ID: ${_temporaryId ?? '...'}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 4),
          Text(
            _permissionsGranted ? 'Nearby permissions granted' : 'Nearby permissions NOT granted',
            style: TextStyle(color: _permissionsGranted ? Colors.green : Colors.red),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _buildDeviceTile(DeviceEvent event) {
    final alreadyConnected = _connected.contains(event.remoteId);
    return ListTile(
      dense: true,
      title: Text(event.advertisedName ?? event.remoteId),
      subtitle: Text(event.remoteId, style: const TextStyle(fontFamily: 'monospace')),
      trailing: ElevatedButton(
        onPressed: alreadyConnected ? null : () => _connectTo(event.remoteId),
        child: Text(alreadyConnected ? 'Connected' : 'Connect'),
      ),
    );
  }

  Widget _buildConnectedTile(String remoteId) {
    final ready = _sessioned.contains(remoteId);
    return ListTile(
      dense: true,
      title: Text(remoteId, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(ready ? 'Session ready' : 'Handshaking...'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton(
            onPressed: ready ? () => _sendTestPacket(remoteId) : null,
            child: const Text('Send test packet'),
          ),
          IconButton(
            icon: const Icon(Icons.link_off),
            onPressed: () => _disconnectFrom(remoteId),
          ),
        ],
      ),
    );
  }
}
