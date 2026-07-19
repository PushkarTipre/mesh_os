import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mesh_os/mesh_os.dart';

import 'broadcast_screen.dart';
import 'chat_history.dart';
import 'identity_card_screens.dart';
import 'mesh_debug_screen.dart';

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
  List<Contact> _contacts = const [];

  StreamSubscription<List<MeshDevice>>? _deviceSub;
  StreamSubscription<List<Contact>>? _contactSub;

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
      _contactSub = _mesh.contactUpdates.listen((contacts) {
        if (!mounted) return;
        setState(() => _contacts = contacts);
      });
      await _mesh.start();
      final contacts = await _mesh.contacts;
      if (!mounted) return;
      setState(() {
        _ready = true;
        _contacts = contacts;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _contactSub?.cancel();
    _mesh.dispose();
    super.dispose();
  }

  Future<void> _showMyCode() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MyIdentityCardScreen(mesh: _mesh)),
    );
  }

  Future<void> _scanCode() async {
    final contact = await Navigator.of(context).push(
      MaterialPageRoute<Contact?>(builder: (_) => ScanIdentityCardScreen(mesh: _mesh)),
    );
    if (contact == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Trusted ${contact.displayName ?? contact.nodeId}')),
    );
  }

  Future<void> _showBroadcast() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BroadcastScreen(mesh: _mesh)),
    );
  }

  Future<void> _showDebug() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MeshDebugScreen(mesh: _mesh)),
    );
  }

  Future<void> _setTrustLevel(String nodeId, TrustLevel level) async {
    switch (level) {
      case TrustLevel.trusted:
        await _mesh.trust(nodeId);
      case TrustLevel.blocked:
        await _mesh.block(nodeId);
      case TrustLevel.known:
        await _mesh.unblock(nodeId);
      case TrustLevel.unknown:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshOS Console'),
        actions: [
          IconButton(icon: const Icon(Icons.hub), onPressed: _showDebug),
          IconButton(icon: const Icon(Icons.campaign), onPressed: _showBroadcast),
          IconButton(icon: const Icon(Icons.qr_code), onPressed: _showMyCode),
          IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: _scanCode),
        ],
      ),
      body: !_ready && _error == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Failed to start: $_error'))
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    // Contacts already reachable directly (shown under "Nearby devices")
    // are hidden here -- this section is specifically for known contacts
    // who aren't currently in range, reachable only by routing through
    // relays (MeshOS.send() picks that automatically -- ChatScreen works
    // identically either way, see ROADMAP.md Checkpoint 6).
    final nearbyNodeIds = _devices.map((d) => d.nodeId).whereType<String>().toSet();
    final farContacts = _contacts.where((c) => !nearbyNodeIds.contains(c.nodeId)).toList();

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
          child: ListView(
            children: [
              _sectionHeader('Nearby devices (${_devices.length})'),
              if (_devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Searching for nearby MeshOS devices...'),
                )
              else
                ..._devices.map(_buildDeviceTile),
              if (farContacts.isNotEmpty) ...[
                _sectionHeader('Other known contacts (${farContacts.length})'),
                ...farContacts.map(_buildContactTile),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceTile(MeshDevice device) {
    // A display name only ever shows up for a trusted contact -- see
    // ARCHITECTURE.md §5's privacy boundary.
    final label = device.displayName ?? device.nodeId ?? device.remoteId;
    final status = !device.connected
        ? 'Connecting...'
        : !device.sessionReady
            ? 'Handshaking...'
            : 'Ready to chat';
    final subtitle = '$status · ${device.trustLevel.name}';
    final canOpenChat = device.sessionReady && device.nodeId != null;

    return ListTile(
      title: Text(label, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device.nodeId != null) _buildTrustMenu(device.nodeId!, device.trustLevel),
          if (canOpenChat) const Icon(Icons.chevron_right),
        ],
      ),
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

  /// A known contact who isn't currently a direct neighbor -- tapping
  /// still opens the same [ChatScreen]; [MeshOS.send] routes through
  /// relays automatically (Checkpoint 6), so this is exactly how CP6's
  /// "message someone out of range" demo works through the UI.
  Widget _buildContactTile(Contact contact) {
    final label = contact.displayName ?? contact.nodeId;
    return ListTile(
      title: Text(label, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text('Not nearby · ${contact.trustLevel.name}'),
      trailing: _buildTrustMenu(contact.nodeId, contact.trustLevel),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
            mesh: _mesh,
            historyStore: _historyStore,
            peerNodeId: contact.nodeId,
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _buildTrustMenu(String nodeId, TrustLevel trustLevel) {
    return PopupMenuButton<TrustLevel>(
      onSelected: (level) => _setTrustLevel(nodeId, level),
      itemBuilder: (context) => [
        if (trustLevel != TrustLevel.trusted)
          const PopupMenuItem(value: TrustLevel.trusted, child: Text('Trust')),
        if (trustLevel != TrustLevel.blocked)
          const PopupMenuItem(value: TrustLevel.blocked, child: Text('Block')),
        if (trustLevel == TrustLevel.blocked)
          const PopupMenuItem(value: TrustLevel.known, child: Text('Unblock')),
      ],
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

  // File transfers are session-only (not persisted to ChatHistoryStore,
  // unlike text messages) -- a dev-harness scope decision, not a platform
  // limitation; see ROADMAP.md Checkpoint 7's notes.
  final List<_FileEvent> _fileEvents = [];
  final Map<String, _FileEvent> _outgoingTransfers = {};

  Map<String, List<ChatMessageRecord>> _allHistory = {};
  StreamSubscription<InboundMessage>? _messageSub;
  StreamSubscription<IncomingFile>? _fileSub;
  StreamSubscription<FileTransferProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _messageSub = widget.mesh.messages.listen(_onIncoming);
    _fileSub = widget.mesh.incomingFiles.listen(_onIncomingFile);
    _progressSub = widget.mesh.outgoingFileProgress.listen(_onOutgoingProgress);
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _fileSub?.cancel();
    _progressSub?.cancel();
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
    // senderNodeId is always populated, whether the message arrived
    // directly or was routed through relays (Checkpoint 6) -- unlike
    // remoteId, which is null for a routed message. A non-null topic
    // means this is broadcast/publish traffic (Checkpoint 7), which
    // belongs in BroadcastScreen's feed, not a private chat thread, even
    // if it happens to come from this peer.
    if (message.senderNodeId != widget.peerNodeId || message.topic != null) return;
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

  void _onIncomingFile(IncomingFile file) {
    if (file.senderNodeId != widget.peerNodeId) return;
    setState(() {
      _fileEvents.add(_FileEvent(
        outgoing: false,
        filename: file.filename,
        timestamp: DateTime.now(),
        localBytes: file.bytes,
      ));
    });
    _scrollToBottom();
  }

  void _onOutgoingProgress(FileTransferProgress progress) {
    final event = _outgoingTransfers[progress.transferId];
    if (event == null) return; // not a transfer this screen started
    setState(() => event.progress = progress);
  }

  Future<void> _pickAndSendFile() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();

    final transferId = widget.mesh.sendFile(
      destination: widget.peerNodeId,
      filename: picked.name,
      bytes: bytes,
    );

    final event = _FileEvent(
      outgoing: true,
      filename: picked.name,
      timestamp: DateTime.now(),
      localBytes: bytes,
    );
    _outgoingTransfers[transferId] = event;
    setState(() => _fileEvents.add(event));
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
            child: Builder(builder: (context) {
              final items = <_ChatItem>[
                ..._messages.map(_TextChatItem.new),
                ..._fileEvents.map(_FileChatItem.new),
              ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return switch (item) {
                    _TextChatItem() => _buildBubble(item.record),
                    _FileChatItem() => _buildFileBubble(item.event),
                  };
                },
              );
            }),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.attach_file), onPressed: _pickAndSendFile),
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

  Widget _buildFileBubble(_FileEvent event) {
    final progress = event.progress;
    final statusText = !event.outgoing
        ? 'received'
        : switch (progress?.status) {
            null => 'sending',
            FileTransferStatus.inProgress => 'sending ${(progress!.fraction * 100).round()}%',
            FileTransferStatus.paused => 'paused ${(progress!.fraction * 100).round()}%',
            FileTransferStatus.completed => 'delivered',
          };

    return Align(
      alignment: event.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: event.outgoing ? Colors.blue.shade100 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (event.looksLikeImage && event.localBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(event.localBytes!, fit: BoxFit.cover),
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.insert_drive_file, size: 20),
                  const SizedBox(width: 6),
                  Flexible(child: Text(event.filename, overflow: TextOverflow.ellipsis)),
                ],
              ),
            const SizedBox(height: 4),
            Text(statusText, style: const TextStyle(fontSize: 10, color: Colors.black54)),
            if (event.outgoing &&
                progress != null &&
                progress.status != FileTransferStatus.completed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(value: progress.fraction),
              ),
          ],
        ),
      ),
    );
  }
}

/// A file sent or received in this chat -- kept separate from
/// [ChatMessageRecord] since file bytes aren't persisted (session-only,
/// see [_ChatScreenState]'s field doc).
class _FileEvent {
  _FileEvent({
    required this.outgoing,
    required this.filename,
    required this.timestamp,
    this.localBytes,
  });

  final bool outgoing;
  final String filename;
  final DateTime timestamp;
  final Uint8List? localBytes;

  /// Only ever set for an outgoing transfer -- see
  /// [_ChatScreenState._onOutgoingProgress].
  FileTransferProgress? progress;

  bool get looksLikeImage {
    final lower = filename.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
  }
}

/// Text messages ([ChatMessageRecord]) and file transfers ([_FileEvent])
/// are tracked in separate lists (different persistence lifetimes) but
/// rendered as one chronological feed -- this is the shared view over
/// both, sorted by [timestamp] just before building the list.
sealed class _ChatItem {
  DateTime get timestamp;
}

class _TextChatItem extends _ChatItem {
  _TextChatItem(this.record);
  final ChatMessageRecord record;
  @override
  DateTime get timestamp => record.timestamp;
}

class _FileChatItem extends _ChatItem {
  _FileChatItem(this.event);
  final _FileEvent event;
  @override
  DateTime get timestamp => event.timestamp;
}
