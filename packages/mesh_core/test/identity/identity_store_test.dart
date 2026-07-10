import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryIdentityStore', () {
    test('read returns null before any write', () async {
      final store = InMemoryIdentityStore();
      expect(await store.read(), isNull);
    });

    test('write then read round-trips the data', () async {
      final store = InMemoryIdentityStore();
      await store.write({'a': 1, 'b': 'two'});
      expect(await store.read(), equals({'a': 1, 'b': 'two'}));
    });

    test('clear removes the stored data', () async {
      final store = InMemoryIdentityStore();
      await store.write({'a': 1});
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
