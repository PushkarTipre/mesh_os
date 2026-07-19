import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';

/// CP7 exit-criterion demo: a plain (topic-less) broadcast reaches every
/// nearby device, relayed hop by hop -- unlike [MeshOS.send], it needs no
/// prior contact with anyone. See ROADMAP.md Checkpoint 7.
///
/// Deliberately scoped to plain broadcast only: [MeshOS.publish] and
/// [MeshOS.subscribe] (topic-filtered pub/sub) are implemented and
/// covered by mesh_core's test suite, but aren't surfaced in this demo
/// UI -- the exit-criterion demo only calls for a broadcast reaching
/// every device, not a topic-routing UI.
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key, required this.mesh});

  final MeshOS mesh;

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastEntry {
  _BroadcastEntry({required this.senderNodeId, required this.text, required this.timestamp});

  final String senderNodeId;
  final String text;
  final DateTime timestamp;
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final TextEditingController _textController = TextEditingController();
  final List<_BroadcastEntry> _log = [];

  StreamSubscription<InboundMessage>? _messageSub;

  @override
  void initState() {
    super.initState();
    // MeshOS.messages carries broadcast/publish traffic alongside
    // ordinary chat -- InboundMessage.topic is only non-null for the
    // former (empty string for a plain broadcast, see MeshLink.broadcast).
    _messageSub = widget.mesh.messages.listen((message) {
      if (message.topic == null) return;
      setState(() {
        _log.add(_BroadcastEntry(
          senderNodeId: message.senderNodeId,
          text: utf8.decode(message.plaintext),
          timestamp: DateTime.now(),
        ));
      });
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    await widget.mesh.broadcast(utf8.encode(text));
    // A node never receives its own broadcast back off the wire (there's
    // nothing to loop it through) -- append it to the log locally, same
    // as ChatScreen does for outgoing chat messages.
    setState(() {
      _log.add(_BroadcastEntry(
        senderNodeId: widget.mesh.identity.nodeId,
        text: text,
        timestamp: DateTime.now(),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Broadcast')),
      body: Column(
        children: [
          Expanded(
            child: _log.isEmpty
                ? const Center(child: Text('No broadcasts yet'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (context, index) {
                      final entry = _log[index];
                      final isMe = entry.senderNodeId == widget.mesh.identity.nodeId;
                      return ListTile(
                        dense: true,
                        title: Text(entry.text),
                        subtitle: Text(
                          isMe ? 'you' : entry.senderNodeId,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                      );
                    },
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
                    decoration: const InputDecoration(hintText: 'Broadcast to everyone nearby'),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.campaign), onPressed: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
