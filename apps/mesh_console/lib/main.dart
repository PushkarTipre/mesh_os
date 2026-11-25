import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mesh_os/mesh_os.dart';

import 'app_log.dart';
import 'broadcast_log.dart';
import 'broadcast_screen.dart';
import 'chat_history.dart';
import 'error_log_screen.dart';
import 'identity_card_screens.dart';
import 'mesh_debug_screen.dart';
import 'mesh_simulator_screen.dart';

/// Catches everything that could otherwise crash silently on a device
/// nobody's watching a debugger on -- see AppLog's own doc comment for
/// why this exists. `runZonedGuarded` is what makes even errors thrown
/// *outside* any widget's build/callback (a bad Future anywhere in the
/// app) reach [AppLog] rather than just terminating the isolate.
void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLog.instance.init();
    AppLog.instance.log('App starting');

    FlutterError.onError = (details) {
      AppLog.instance.log(
        'Flutter error: ${details.exceptionAsString()}\n${details.stack}',
        level: LogLevel.error,
      );
      FlutterError.presentError(details);
    };

    runApp(const MeshConsoleApp());
  }, (error, stack) {
    AppLog.instance.log('Uncaught error: $error\n$stack', level: LogLevel.error);
  });
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final MeshOS _mesh = MeshOS();
  final ChatHistoryStore _historyStore = ChatHistoryStore();
  final BroadcastLog _broadcastLog = BroadcastLog();

  bool _ready = false;
  bool _slowStart = false;
  String? _error;
  List<MeshDevice> _devices = const [];
  List<Contact> _contacts = const [];

  StreamSubscription<List<MeshDevice>>? _deviceSub;
  StreamSubscription<List<Contact>>? _contactSub;
  StreamSubscription<String>? _diagSub;
  StreamSubscription<InboundMessage>? _messageSub;
  Timer? _slowStartTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Subscribed before start() is even called, so every diagnostic --
    // including the very first one -- ends up in the error log.
    _diagSub = _mesh.diagnostics.listen(AppLog.instance.log);
    _bootstrap();
  }

  /// Android suspends/throttles both Nearby Connections and BLE
  /// scanning/advertising while the app is backgrounded (most
  /// aggressively once the screen is off), and neither radio
  /// automatically resumes just because the app becomes visible again --
  /// observed on real devices as two phones sitting right next to each
  /// other, both freshly resumed, showing each other as "not nearby"
  /// indefinitely. See [MeshOS.refreshDiscovery]'s doc comment and
  /// NEXT_STEPS.md.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_ready) return;
    AppLog.instance.log('App resumed -- refreshing discovery');
    unawaited(_mesh.refreshDiscovery());
  }

  Future<void> _bootstrap() async {
    try {
      // Loaded before start() so both stores are ready the moment the
      // mesh.messages listener below is subscribed -- no window where an
      // early incoming message could arrive before there's anywhere to
      // put it.
      await Future.wait([_historyStore.init(), _broadcastLog.init()]);

      AppLog.instance.log('Loading identity...');
      await _mesh.initialize();
      AppLog.instance.log('Identity loaded: ${_mesh.identity.nodeId}');

      _deviceSub = _mesh.deviceUpdates.listen((devices) {
        if (!mounted) return;
        setState(() => _devices = devices);
      });
      _contactSub = _mesh.contactUpdates.listen((contacts) {
        if (!mounted) return;
        setState(() => _contacts = contacts);
      });
      // The one place incoming chat/broadcast messages are handled --
      // deliberately not inside ChatScreen/BroadcastScreen, which are
      // only alive while that exact screen is on top. HomeScreen stays
      // subscribed for as long as the app is running in the foreground,
      // regardless of what's currently showing, so a message no longer
      // requires the recipient to have the right screen open to be
      // received. See ChatHistoryStore's doc comment for the full story.
      _messageSub = _mesh.messages.listen(_onMessage);

      // Purely informational, not a failure: some devices legitimately
      // take longer than this to clear permission dialogs and radio
      // setup (BLE's own authorize() calls alone can take up to 20s to
      // time out on a device that never grants them -- see
      // NEXT_STEPS.md). start() below is still awaited to completion no
      // matter how long it takes -- a previous version used
      // `.timeout()`, which stopped *waiting* for start() once the
      // deadline passed but didn't stop start() itself, so a start()
      // that finished a few seconds after the deadline left the UI
      // stuck on a permanent error screen despite having actually
      // succeeded. This only changes what's on screen while waiting.
      _slowStartTimer = Timer(const Duration(seconds: 20), () {
        if (!mounted || _ready) return;
        AppLog.instance.log('start() is taking longer than 20s -- still waiting', level: LogLevel.warning);
        setState(() => _slowStart = true);
      });

      await _mesh.start();
      _slowStartTimer?.cancel();

      final contacts = await _mesh.contacts;
      if (!mounted) return;
      setState(() {
        _ready = true;
        _slowStart = false;
        _error = null;
        _contacts = contacts;
      });
    } catch (e, stack) {
      _slowStartTimer?.cancel();
      AppLog.instance.log('Startup failed: $e\n$stack', level: LogLevel.error);
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// [MeshOS.messages] carries both broadcast/publish traffic
  /// (`topic != null`) and ordinary chat -- routed here to the matching
  /// persistent store either way, so both survive regardless of which
  /// screen -- if any -- happens to be open when they arrive.
  void _onMessage(InboundMessage message) {
    if (message.topic != null) {
      _broadcastLog.add(BroadcastEntry(
        senderNodeId: message.senderNodeId,
        text: utf8.decode(message.plaintext),
        timestamp: DateTime.now(),
      ));
      return;
    }
    unawaited(_historyStore.add(
      message.senderNodeId,
      ChatMessageRecord(
        id: newChatMessageId(),
        outgoing: false,
        text: utf8.decode(message.plaintext),
        timestamp: DateTime.now(),
        status: 'received',
      ),
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slowStartTimer?.cancel();
    _deviceSub?.cancel();
    _contactSub?.cancel();
    _diagSub?.cancel();
    _messageSub?.cancel();
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
      MaterialPageRoute<void>(builder: (_) => BroadcastScreen(mesh: _mesh, log: _broadcastLog)),
    );
  }

  Future<void> _showDebug() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MeshDebugScreen(mesh: _mesh)),
    );
  }

  Future<void> _showSimulator() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const MeshSimulatorScreen()),
    );
  }

  Future<void> _showErrorLog() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ErrorLogScreen()),
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

  /// Closes the drawer, then runs [action] -- every drawer item uses
  /// this so tapping one doesn't leave the drawer open behind the new
  /// screen.
  void _fromDrawer(Future<void> Function() action) {
    Navigator.of(context).pop();
    action();
  }

  Drawer _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text('MeshOS Console', style: TextStyle(fontSize: 20)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.science),
            title: const Text('Mesh Simulator'),
            onTap: () => _fromDrawer(_showSimulator),
          ),
          ListTile(
            leading: const Icon(Icons.hub),
            title: const Text('Mesh Debug'),
            onTap: () => _fromDrawer(_showDebug),
          ),
          ListTile(
            leading: const Icon(Icons.campaign),
            title: const Text('Broadcast'),
            onTap: () => _fromDrawer(_showBroadcast),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text('My QR Code'),
            onTap: () => _fromDrawer(_showMyCode),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Scan QR Code'),
            onTap: () => _fromDrawer(_scanCode),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: const Text('Error Log'),
            onTap: () => _fromDrawer(_showErrorLog),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MeshOS Console')),
      drawer: _buildDrawer(),
      body: !_ready && _error == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    if (_slowStart) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Still starting -- this is taking longer than usual.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _showErrorLog,
                        icon: const Icon(Icons.bug_report),
                        label: const Text('View error log'),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to start: $_error', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _showErrorLog,
                          icon: const Icon(Icons.bug_report),
                          label: const Text('View error log'),
                        ),
                      ],
                    ),
                  ),
                )
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

  // File transfers are session-only (not persisted to ChatHistoryStore,
  // unlike text messages) -- a dev-harness scope decision, not a platform
  // limitation; see ROADMAP.md Checkpoint 7's notes. Unlike text
  // messages, this screen still misses a file transfer that completes
  // while it isn't open -- a known, narrower version of the same gap
  // text messages used to have; see NEXT_STEPS.md.
  final List<_FileEvent> _fileEvents = [];
  final Map<String, _FileEvent> _outgoingTransfers = {};

  StreamSubscription<Map<String, List<ChatMessageRecord>>>? _historySub;
  StreamSubscription<IncomingFile>? _fileSub;
  StreamSubscription<FileTransferProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    // widget.historyStore is already loaded and up to date by the time
    // any ChatScreen can be opened (HomeScreen awaits its init() during
    // bootstrap, before ChatScreen is reachable) -- messages() below
    // reads it directly, no async load needed here. This subscription is
    // just for live updates while the screen stays open, including for
    // a message from this peer that HomeScreen's listener persists while
    // this screen is the one on top.
    _historySub = widget.historyStore.updates.listen((_) {
      if (!mounted) return;
      setState(() {});
      _scrollToBottom();
    });
    _fileSub = widget.mesh.incomingFiles.listen(_onIncomingFile);
    _progressSub = widget.mesh.outgoingFileProgress.listen(_onOutgoingProgress);
    _scrollToBottom();
  }

  @override
  void dispose() {
    _historySub?.cancel();
    _fileSub?.cancel();
    _progressSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<ChatMessageRecord> get _messages => widget.historyStore.forPeer(widget.peerNodeId);

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

    final id = newChatMessageId();
    await widget.historyStore.add(
      widget.peerNodeId,
      ChatMessageRecord(
        id: id,
        outgoing: true,
        text: text,
        timestamp: DateTime.now(),
        status: 'sending',
      ),
    );
    // widget.historyStore.updates (subscribed in initState) drives the
    // rebuild once the write above lands -- no local setState needed
    // here or in the status update below.
    _scrollToBottom();

    try {
      final status = await widget.mesh.send(
        destination: widget.peerNodeId,
        payload: utf8.encode(text),
      );
      await widget.historyStore.updateStatus(
        widget.peerNodeId,
        id,
        status == DeliveryStatus.delivered ? 'delivered' : 'failed',
      );
    } catch (e) {
      await widget.historyStore.updateStatus(widget.peerNodeId, id, 'failed');
    }
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
