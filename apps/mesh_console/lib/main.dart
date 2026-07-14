import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';

import 'chat_history.dart';

void main() {
  runApp(const MeshConsoleApp());
}

class MeshConsoleApp extends StatelessWidget {
  const MeshConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshOS Console',
      home: const HomeScreen(),
    );
  }
}

/// CP4 exit-criterion demo: two Android phones, airplane mode, chatting
/// both directions; kill and reopen the app -- identity and message
/// history survive. See ROADMAP.md Checkpoint 4.
///
/// Deliberately thin: all discovery/connection/handshake logic now lives
/// behind the [MeshOS] facade (compare to CP3's hand-wired
/// NearbyTransport + MeshLink) -- this screen just reacts to
/// [MeshOS.deviceUpdates] and taps into [MeshOS.messages]/[MeshOS.send].
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MeshOS _mesh = MeshOS();
  final ChatHistoryStore _historyStore = ChatHistoryStore();

  bool _ready = false;
  String? _error;
  List<MeshDevice> _devices = const [];

  StreamSubscription<List<MeshDevice>>? _deviceSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _mesh.initialize();
      _deviceSub = _mesh.deviceUpdates.listen((devices) {
        if (!mounted) return;
        setState(() => _devices = devices);
      });
      await _mesh.start();
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _mesh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MeshOS Console')),
      body: !_ready && _error == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Failed to start: $_error'))
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Node ID: ${_mesh.identity.nodeId}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _devices.isEmpty
              ? const Center(child: Text('Searching for nearby MeshOS devices...'))
              : ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (context, index) => _buildDeviceTile(_devices[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildDeviceTile(MeshDevice device) {
    final label = device.nodeId ?? device.remoteId;
    final subtitle = !device.connected
        ? 'Connecting...'
        : !device.sessionReady
            ? 'Handshaking...'
            : 'Ready to chat';
    final canOpenChat = device.sessionReady && device.nodeId != null;

    return ListTile(
      title: Text(label, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(subtitle),
      trailing: canOpenChat ? const Icon(Icons.chevron_right) : null,
      onTap: canOpenChat
          ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatScreen(
                    mesh: _mesh,
                    historyStore: _historyStore,
                    peerNodeId: device.nodeId!,
                  ),
                ),
              )
          : null,
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.mesh,
    required this.historyStore,
    required this.peerNodeId,
  });

  final MeshOS mesh;
  final ChatHistoryStore historyStore;
  final String peerNodeId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessageRecord> _messages = [];

  Map<String, List<ChatMessageRecord>> _allHistory = {};
  StreamSubscription<InboundMessage>? _messageSub;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _messageSub = widget.mesh.messages.listen(_onIncoming);
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await widget.historyStore.loadAll();
    if (!mounted) return;
    setState(() {
      _allHistory = history;
      _messages
        ..clear()
        ..addAll(history[widget.peerNodeId] ?? const []);
    });
    _scrollToBottom();
  }

  void _onIncoming(InboundMessage message) {
    if (widget.mesh.nodeIdForRemoteId(message.remoteId) != widget.peerNodeId) return;
    setState(() {
      _messages.add(
        ChatMessageRecord(
          outgoing: false,
          text: utf8.decode(message.plaintext),
          timestamp: DateTime.now(),
          status: 'received',
        ),
      );
    });
    unawaited(_persist());
    _scrollToBottom();
  }

  Future<void> _persist() async {
    _allHistory[widget.peerNodeId] = List.of(_messages);
    await widget.historyStore.saveAll(_allHistory);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    final record = ChatMessageRecord(
      outgoing: true,
      text: text,
      timestamp: DateTime.now(),
      status: 'sending',
    );
    final index = _messages.length;
    setState(() => _messages.add(record));
    unawaited(_persist());
    _scrollToBottom();

    try {
      final status = await widget.mesh.send(
        destination: widget.peerNodeId,
        payload: utf8.encode(text),
      );
      if (!mounted) return;
      setState(() {
        _messages[index] = record.copyWith(
          status: status == DeliveryStatus.delivered ? 'delivered' : 'failed',
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages[index] = record.copyWith(status: 'failed'));
    }
    unawaited(_persist());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.peerNodeId,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) => _buildBubble(_messages[index]),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(hintText: 'Message'),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(ChatMessageRecord message) {
    return Align(
      alignment: message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: message.outgoing ? Colors.blue.shade100 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message.text),
            if (message.outgoing)
              Text(
                message.status,
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
          ],
        ),
      ),
    );
  }
}
