import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';

void main() {
  runApp(const MeshConsoleApp());
}

class MeshConsoleApp extends StatelessWidget {
  const MeshConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshOS Console',
      home: const IdentityScreen(),
    );
  }
}

/// CP1 exit-criterion demo: generates (or loads) this device's NodeIdentity
/// on launch and displays its Node ID. Force-quit and reopen the app --
/// the same Node ID should appear, proving the identity is persisted via
/// platform secure storage rather than regenerated every run.
class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final _store = SecureStorageIdentityStore();
  late final Future<NodeIdentity> _identity = NodeIdentity.loadOrCreate(_store);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MeshOS Console')),
      body: Center(
        child: FutureBuilder<NodeIdentity>(
          future: _identity,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text('Failed to load identity: ${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const CircularProgressIndicator();
            }
            final identity = snapshot.data!;
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Node ID'),
                  const SizedBox(height: 8),
                  SelectableText(
                    identity.nodeId,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Force-quit and reopen the app -- this ID should stay '
                    'the same.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
