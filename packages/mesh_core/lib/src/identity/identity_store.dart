/// Pluggable persistence for a `NodeIdentity`'s storable form.
///
/// mesh_core stays pure Dart, so it only defines this interface. A real
/// on-device implementation (backed by platform secure storage) lives in
/// the mesh_os package; [InMemoryIdentityStore] here exists for tests and
/// for callers that manage persistence themselves.
abstract class IdentityStore {
  Future<Map<String, dynamic>?> read();

  Future<void> write(Map<String, dynamic> data);

  Future<void> clear();
}

class InMemoryIdentityStore implements IdentityStore {
  Map<String, dynamic>? _data;

  @override
  Future<Map<String, dynamic>?> read() async => _data;

  @override
  Future<void> write(Map<String, dynamic> data) async {
    _data = data;
  }

  @override
  Future<void> clear() async {
    _data = null;
  }
}
