import 'package:drift/drift.dart';

/// SQLite table backing `DriftTrustStore`. Named `ContactRows` (rather than
/// `Contacts`) so drift's generated data class (`ContactRow`) doesn't
/// collide with mesh_core's own `Contact` model -- `DriftTrustStore` maps
/// between the two.
class ContactRows extends Table {
  TextColumn get nodeId => text()();
  BlobColumn get signingPublicKey => blob()();
  BlobColumn get agreementPublicKey => blob()();

  /// 0 = known, 1 = trusted, 2 = blocked (see `_levelToInt`/`_levelFromInt`
  /// in `DriftTrustStore`). `TrustLevel.unknown` is never stored -- see
  /// that enum's doc comment.
  IntColumn get trustLevel => integer()();

  TextColumn get displayName => text().nullable()();
  DateTimeColumn get firstSeenAt => dateTime()();

  @override
  Set<Column> get primaryKey => {nodeId};
}
