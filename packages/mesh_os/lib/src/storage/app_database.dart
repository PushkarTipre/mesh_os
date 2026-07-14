import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'contact_rows.dart';

part 'app_database.g.dart';

/// The on-device SQLite database (ARCHITECTURE.md §9). Only holds
/// contacts/trust data for now -- pending packets, routing cache, etc.
/// join this as later checkpoints need them.
@DriftDatabase(tables: [ContactRows])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'mesh_os'));

  /// For tests: pass an in-memory or otherwise isolated executor instead
  /// of touching the real on-device file.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;
}
