import 'package:drift/drift.dart';
import 'package:mesh_core/mesh_core.dart';

import 'app_database.dart';

int _levelToInt(TrustLevel level) => switch (level) {
      TrustLevel.trusted => 1,
      TrustLevel.blocked => 2,
      TrustLevel.known || TrustLevel.unknown => 0,
    };

TrustLevel _levelFromInt(int value) => switch (value) {
      1 => TrustLevel.trusted,
      2 => TrustLevel.blocked,
      _ => TrustLevel.known,
    };

/// SQLite-backed [TrustStore] (ARCHITECTURE.md §9), via drift.
class DriftTrustStore implements TrustStore {
  DriftTrustStore([AppDatabase? database]) : _db = database ?? AppDatabase();

  final AppDatabase _db;

  @override
  Future<Contact?> getContact(String nodeId) async {
    final row = await (_db.select(_db.contactRows)
          ..where((t) => t.nodeId.equals(nodeId)))
        .getSingleOrNull();
    return row == null ? null : _toContact(row);
  }

  @override
  Future<void> upsertContact(Contact contact) async {
    await _db.into(_db.contactRows).insertOnConflictUpdate(
          ContactRowsCompanion.insert(
            nodeId: contact.nodeId,
            signingPublicKey: contact.signingPublicKeyBytes,
            agreementPublicKey: contact.agreementPublicKeyBytes,
            trustLevel: _levelToInt(contact.trustLevel),
            displayName: Value(contact.displayName),
            firstSeenAt: contact.firstSeenAt,
          ),
        );
  }

  @override
  Future<List<Contact>> listContacts() async {
    final rows = await _db.select(_db.contactRows).get();
    return rows.map(_toContact).toList();
  }

  @override
  Stream<List<Contact>> watchContacts() {
    return _db.select(_db.contactRows).watch().map(
          (rows) => rows.map(_toContact).toList(),
        );
  }

  @override
  Future<TrustLevel> trustLevelFor(String nodeId) async {
    final contact = await getContact(nodeId);
    return contact?.trustLevel ?? TrustLevel.unknown;
  }

  Contact _toContact(ContactRow row) => Contact(
        nodeId: row.nodeId,
        signingPublicKeyBytes: Uint8List.fromList(row.signingPublicKey),
        agreementPublicKeyBytes: Uint8List.fromList(row.agreementPublicKey),
        trustLevel: _levelFromInt(row.trustLevel),
        displayName: row.displayName,
        // drift's dateTime() column round-trips the same instant but
        // reconstructs it as local time, not UTC -- normalize back to UTC
        // so it matches what's stored everywhere else in this codebase.
        firstSeenAt: row.firstSeenAt.toUtc(),
      );

  Future<void> close() => _db.close();
}
