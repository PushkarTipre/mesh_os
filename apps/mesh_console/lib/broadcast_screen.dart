import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';

import 'broadcast_log.dart';

/// CP7 exit-criterion demo: a plain (topic-less) broadcast reaches every
/// nearby device, relayed hop by hop -- unlike [MeshOS.send], it needs no
/// prior contact with anyone. See ROADMAP.md Checkpoint 7.
///
/// Deliberately scoped to plain broadcast only: [MeshOS.publish] and
/// [MeshOS.subscribe] (topic-filtered pub/sub) are implemented and
/// covered by mesh_core's test suite, but aren't surfaced in this demo
/// UI -- the exit-criterion demo only calls for a broadcast reaching
/// every device, not a topic-routing UI.
///
/// Renders [log] rather than keeping its own message list -- incoming
/// broadcasts are received and persisted by `HomeScreen` regardless of
/// whether this screen is open (see [BroadcastLog]'s doc comment); this
/// screen just reflects that shared, already-up-to-date state.
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key, required this.mesh, required this.log});

  final MeshOS mesh;
  final BroadcastLog log;

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final TextEditingController _textController = TextEditingController();

  StreamSubscription<List<BroadcastEntry>>? _logSub;

  @override
  void initState() {
    super.initState();
    _logSub = widget.log.updates.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    try {
      await widget.mesh.broadcast(utf8.encode(text));
    } catch (e) {
      // Most likely MeshOS.start() hasn't finished yet (still waiting on
      // a permission dialog, for example) -- surface it rather than
      // silently doing nothing, which just looks like a broken button.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not broadcast: $e')),
      );
      return;
    }
    // A node never receives its own broadcast back off the wire (there's
    // nothing to loop it through) -- append it to the log locally, same
    // as ChatScreen does for outgoing chat messages.
    widget.log.add(BroadcastEntry(
      senderNodeId: widget.mesh.identity.nodeId,
      text: text,
      timestamp: DateTime.now(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.log.entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Broadcast')),
      body: Column(
        children: [
          Expanded(
            child: log.isEmpty
                ? const Center(child: Text('No broadcasts yet'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: log.length,
                    itemBuilder: (context, index) {
                      final entry = log[index];
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
