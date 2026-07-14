import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

Contact _contact(String nodeId, {TrustLevel trustLevel = TrustLevel.known}) => Contact(
      nodeId: nodeId,
      signingPublicKeyBytes: Uint8List(32),
      agreementPublicKeyBytes: Uint8List(32),
      trustLevel: trustLevel,
      firstSeenAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('InMemoryTrustStore', () {
    test('an unknown nodeId has no contact and trust level unknown', () async {
      final store = InMemoryTrustStore();
      expect(await store.getContact('nobody'), isNull);
      expect(await store.trustLevelFor('nobody'), equals(TrustLevel.unknown));
    });

    test('upsertContact stores and retrieves a contact', () async {
      final store = InMemoryTrustStore();
      await store.upsertContact(_contact('abc', trustLevel: TrustLevel.trusted));

      final stored = await store.getContact('abc');
      expect(stored, isNotNull);
      expect(stored!.trustLevel, equals(TrustLevel.trusted));
      expect(await store.trustLevelFor('abc'), equals(TrustLevel.trusted));
    });

    test('upsertContact overwrites an existing contact by nodeId', () async {
      final store = InMemoryTrustStore();
      await store.upsertContact(_contact('abc', trustLevel: TrustLevel.known));
      await store.upsertContact(_contact('abc', trustLevel: TrustLevel.blocked));

      expect(await store.trustLevelFor('abc'), equals(TrustLevel.blocked));
      expect(await store.listContacts(), hasLength(1));
    });

    test('listContacts returns every stored contact', () async {
      final store = InMemoryTrustStore();
      await store.upsertContact(_contact('a'));
      await store.upsertContact(_contact('b'));

      final contacts = await store.listContacts();
      expect(contacts.map((c) => c.nodeId), containsAll(['a', 'b']));
    });

    test('watchContacts emits the updated list on every upsert', () async {
      final store = InMemoryTrustStore();
      final updates = <int>[];
      final sub = store.watchContacts().listen((contacts) => updates.add(contacts.length));

      await store.upsertContact(_contact('a'));
      await store.upsertContact(_contact('b'));
      await Future<void>.delayed(Duration.zero);

      expect(updates, equals([1, 2]));
      await sub.cancel();
    });

    test('Contact.copyWith changes only the requested fields', () async {
      final original = _contact('abc', trustLevel: TrustLevel.known);
      final trusted = original.copyWith(trustLevel: TrustLevel.trusted, displayName: 'Alice');

      expect(trusted.nodeId, equals(original.nodeId));
      expect(trusted.trustLevel, equals(TrustLevel.trusted));
      expect(trusted.displayName, equals('Alice'));
      expect(original.trustLevel, equals(TrustLevel.known)); // unchanged
    });
  });
}
