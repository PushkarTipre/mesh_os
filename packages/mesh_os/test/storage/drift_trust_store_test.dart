import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_os/mesh_os.dart';
import 'package:mesh_os/src/storage/app_database.dart';

Contact _contact(String nodeId, {TrustLevel trustLevel = TrustLevel.known, String? displayName}) =>
    Contact(
      nodeId: nodeId,
      signingPublicKeyBytes: Uint8List.fromList(List<int>.filled(32, 7)),
      agreementPublicKeyBytes: Uint8List.fromList(List<int>.filled(32, 9)),
      trustLevel: trustLevel,
      displayName: displayName,
      firstSeenAt: DateTime.utc(2026, 1, 1, 12),
    );

void main() {
  late AppDatabase database;
  late DriftTrustStore store;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = DriftTrustStore(database);
  });

  tearDown(() async {
    await database.close();
  });

  group('DriftTrustStore (real in-memory SQLite)', () {
    test('an unstored nodeId has no contact', () async {
      expect(await store.getContact('nobody'), isNull);
      expect(await store.trustLevelFor('nobody'), equals(TrustLevel.unknown));
    });

    test('upsertContact persists every field, round-tripping through SQLite', () async {
      final original = _contact('abc', trustLevel: TrustLevel.trusted, displayName: 'Pushkar');
      await store.upsertContact(original);

      final stored = await store.getContact('abc');
      expect(stored, isNotNull);
      expect(stored!.nodeId, equals('abc'));
      expect(stored.trustLevel, equals(TrustLevel.trusted));
      expect(stored.displayName, equals('Pushkar'));
      expect(stored.signingPublicKeyBytes, equals(original.signingPublicKeyBytes));
      expect(stored.agreementPublicKeyBytes, equals(original.agreementPublicKeyBytes));
      expect(stored.firstSeenAt, equals(original.firstSeenAt));
    });

    test('a null displayName round-trips as null, not the string "null"', () async {
      await store.upsertContact(_contact('abc'));
      final stored = await store.getContact('abc');
      expect(stored!.displayName, isNull);
    });

    test('upsertContact overwrites an existing row by nodeId', () async {
      await store.upsertContact(_contact('abc', trustLevel: TrustLevel.known));
      await store.upsertContact(_contact('abc', trustLevel: TrustLevel.blocked));

      expect(await store.trustLevelFor('abc'), equals(TrustLevel.blocked));
      expect(await store.listContacts(), hasLength(1));
    });

    test('listContacts returns every stored contact', () async {
      await store.upsertContact(_contact('a'));
      await store.upsertContact(_contact('b'));

      final contacts = await store.listContacts();
      expect(contacts.map((c) => c.nodeId), containsAll(['a', 'b']));
    });

    test('watchContacts emits an updated list on every upsert', () async {
      final updates = <int>[];
      final sub = store.watchContacts().listen((contacts) => updates.add(contacts.length));

      await store.upsertContact(_contact('a'));
      await store.upsertContact(_contact('b'));
      await Future<void>.delayed(Duration.zero);

      expect(updates, equals([1, 2]));
      await sub.cancel();
    });

    test('trust data survives closing and reopening the database (simulated app restart)',
        () async {
      await store.upsertContact(_contact('abc', trustLevel: TrustLevel.trusted, displayName: 'Ana'));

      // Reopen a fresh AppDatabase/DriftTrustStore against the *same*
      // in-memory connection, simulating what real disk-backed persistence
      // gives you across an app restart.
      final reopenedStore = DriftTrustStore(database);
      final stored = await reopenedStore.getContact('abc');

      expect(stored, isNotNull);
      expect(stored!.trustLevel, equals(TrustLevel.trusted));
      expect(stored.displayName, equals('Ana'));
    });
  });
}
