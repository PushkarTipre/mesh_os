import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mesh_os/mesh_os.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Becoming Contacts" (ARCHITECTURE.md §9): shows this device's identity
/// card as a QR code, choosing a display name that's revealed only to
/// whoever scans it.
class MyIdentityCardScreen extends StatefulWidget {
  const MyIdentityCardScreen({super.key, required this.mesh});

  final MeshOS mesh;

  @override
  State<MyIdentityCardScreen> createState() => _MyIdentityCardScreenState();
}

class _MyIdentityCardScreenState extends State<MyIdentityCardScreen> {
  static const _prefsKey = 'mesh_console.last_display_name';

  final TextEditingController _nameController = TextEditingController();
  String? _encodedCard;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLastName();
  }

  Future<void> _loadLastName() async {
    final prefs = await SharedPreferences.getInstance();
    final lastName = prefs.getString(_prefsKey);
    if (lastName == null || !mounted) return;
    _nameController.text = lastName;
    // Same name as last time -- regenerate immediately so returning to
    // this screen shows a code right away instead of an empty form
    // requiring the exact same name to be typed in again.
    unawaited(_generate());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    try {
      final card = await widget.mesh.createIdentityCard(displayName: name);
      if (!mounted) return;
      setState(() {
        _encodedCard = card;
        _error = null;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, name);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Identity Card')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display name',
                hintText: 'What should this contact see you as?',
              ),
              onSubmitted: (_) => _generate(),
            ),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _generate, child: const Text('Show my code')),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_encodedCard != null) ...[
              const SizedBox(height: 24),
              QrImageView(data: _encodedCard!, size: 240),
              const SizedBox(height: 12),
              const Text(
                'Have the other person scan this. This name is only ever '
                'shared with people who scan your code.',
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The scanning half of "Becoming Contacts": camera view that processes
/// the first valid `IdentityCard` it sees and trusts that peer.
class ScanIdentityCardScreen extends StatefulWidget {
  const ScanIdentityCardScreen({super.key, required this.mesh});

  final MeshOS mesh;

  @override
  State<ScanIdentityCardScreen> createState() => _ScanIdentityCardScreenState();
}

class _ScanIdentityCardScreenState extends State<ScanIdentityCardScreen> {
  bool _processing = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final rawValue = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (rawValue == null) return;

    setState(() => _processing = true);
    final contact = await widget.mesh.trustFromIdentityCard(rawValue);
    if (!mounted) return;

    if (contact == null) {
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not a valid MeshOS identity card.')),
      );
      return;
    }

    Navigator.of(context).pop(contact);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Identity Card')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
