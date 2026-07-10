import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mesh_core/mesh_core.dart';

/// [IdentityStore] backed by the platform secure storage (Android
/// Keystore / iOS Keychain via `flutter_secure_storage`), so a node's
/// private key material never touches plain-text disk.
class SecureStorageIdentityStore implements IdentityStore {
  SecureStorageIdentityStore({
    FlutterSecureStorage? storage,
    this.key = 'mesh_os.node_identity',
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final String key;

  @override
  Future<Map<String, dynamic>?> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    await _storage.write(key: key, value: jsonEncode(data));
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: key);
  }
}
