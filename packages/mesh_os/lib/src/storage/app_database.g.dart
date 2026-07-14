// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ContactRowsTable extends ContactRows
    with TableInfo<$ContactRowsTable, ContactRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ContactRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nodeIdMeta = const VerificationMeta('nodeId');
  @override
  late final GeneratedColumn<String> nodeId = GeneratedColumn<String>(
    'node_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signingPublicKeyMeta = const VerificationMeta(
    'signingPublicKey',
  );
  @override
  late final GeneratedColumn<Uint8List> signingPublicKey =
      GeneratedColumn<Uint8List>(
        'signing_public_key',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _agreementPublicKeyMeta =
      const VerificationMeta('agreementPublicKey');
  @override
  late final GeneratedColumn<Uint8List> agreementPublicKey =
      GeneratedColumn<Uint8List>(
        'agreement_public_key',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _trustLevelMeta = const VerificationMeta(
    'trustLevel',
  );
  @override
  late final GeneratedColumn<int> trustLevel = GeneratedColumn<int>(
    'trust_level',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _firstSeenAtMeta = const VerificationMeta(
    'firstSeenAt',
  );
  @override
  late final GeneratedColumn<DateTime> firstSeenAt = GeneratedColumn<DateTime>(
    'first_seen_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    nodeId,
    signingPublicKey,
    agreementPublicKey,
    trustLevel,
    displayName,
    firstSeenAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'contact_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<ContactRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('node_id')) {
      context.handle(
        _nodeIdMeta,
        nodeId.isAcceptableOrUnknown(data['node_id']!, _nodeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_nodeIdMeta);
    }
    if (data.containsKey('signing_public_key')) {
      context.handle(
        _signingPublicKeyMeta,
        signingPublicKey.isAcceptableOrUnknown(
          data['signing_public_key']!,
          _signingPublicKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_signingPublicKeyMeta);
    }
    if (data.containsKey('agreement_public_key')) {
      context.handle(
        _agreementPublicKeyMeta,
        agreementPublicKey.isAcceptableOrUnknown(
          data['agreement_public_key']!,
          _agreementPublicKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_agreementPublicKeyMeta);
    }
    if (data.containsKey('trust_level')) {
      context.handle(
        _trustLevelMeta,
        trustLevel.isAcceptableOrUnknown(data['trust_level']!, _trustLevelMeta),
      );
    } else if (isInserting) {
      context.missing(_trustLevelMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('first_seen_at')) {
      context.handle(
        _firstSeenAtMeta,
        firstSeenAt.isAcceptableOrUnknown(
          data['first_seen_at']!,
          _firstSeenAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_firstSeenAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {nodeId};
  @override
  ContactRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ContactRow(
      nodeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}node_id'],
      )!,
      signingPublicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}signing_public_key'],
      )!,
      agreementPublicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}agreement_public_key'],
      )!,
      trustLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}trust_level'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      ),
      firstSeenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}first_seen_at'],
      )!,
    );
  }

  @override
  $ContactRowsTable createAlias(String alias) {
    return $ContactRowsTable(attachedDatabase, alias);
  }
}

class ContactRow extends DataClass implements Insertable<ContactRow> {
  final String nodeId;
  final Uint8List signingPublicKey;
  final Uint8List agreementPublicKey;

  /// 0 = known, 1 = trusted, 2 = blocked (see `_levelToInt`/`_levelFromInt`
  /// in `DriftTrustStore`). `TrustLevel.unknown` is never stored -- see
  /// that enum's doc comment.
  final int trustLevel;
  final String? displayName;
  final DateTime firstSeenAt;
  const ContactRow({
    required this.nodeId,
    required this.signingPublicKey,
    required this.agreementPublicKey,
    required this.trustLevel,
    this.displayName,
    required this.firstSeenAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['node_id'] = Variable<String>(nodeId);
    map['signing_public_key'] = Variable<Uint8List>(signingPublicKey);
    map['agreement_public_key'] = Variable<Uint8List>(agreementPublicKey);
    map['trust_level'] = Variable<int>(trustLevel);
    if (!nullToAbsent || displayName != null) {
      map['display_name'] = Variable<String>(displayName);
    }
    map['first_seen_at'] = Variable<DateTime>(firstSeenAt);
    return map;
  }

  ContactRowsCompanion toCompanion(bool nullToAbsent) {
    return ContactRowsCompanion(
      nodeId: Value(nodeId),
      signingPublicKey: Value(signingPublicKey),
      agreementPublicKey: Value(agreementPublicKey),
      trustLevel: Value(trustLevel),
      displayName: displayName == null && nullToAbsent
          ? const Value.absent()
          : Value(displayName),
      firstSeenAt: Value(firstSeenAt),
    );
  }

  factory ContactRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ContactRow(
      nodeId: serializer.fromJson<String>(json['nodeId']),
      signingPublicKey: serializer.fromJson<Uint8List>(
        json['signingPublicKey'],
      ),
      agreementPublicKey: serializer.fromJson<Uint8List>(
        json['agreementPublicKey'],
      ),
      trustLevel: serializer.fromJson<int>(json['trustLevel']),
      displayName: serializer.fromJson<String?>(json['displayName']),
      firstSeenAt: serializer.fromJson<DateTime>(json['firstSeenAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'nodeId': serializer.toJson<String>(nodeId),
      'signingPublicKey': serializer.toJson<Uint8List>(signingPublicKey),
      'agreementPublicKey': serializer.toJson<Uint8List>(agreementPublicKey),
      'trustLevel': serializer.toJson<int>(trustLevel),
      'displayName': serializer.toJson<String?>(displayName),
      'firstSeenAt': serializer.toJson<DateTime>(firstSeenAt),
    };
  }

  ContactRow copyWith({
    String? nodeId,
    Uint8List? signingPublicKey,
    Uint8List? agreementPublicKey,
    int? trustLevel,
    Value<String?> displayName = const Value.absent(),
    DateTime? firstSeenAt,
  }) => ContactRow(
    nodeId: nodeId ?? this.nodeId,
    signingPublicKey: signingPublicKey ?? this.signingPublicKey,
    agreementPublicKey: agreementPublicKey ?? this.agreementPublicKey,
    trustLevel: trustLevel ?? this.trustLevel,
    displayName: displayName.present ? displayName.value : this.displayName,
    firstSeenAt: firstSeenAt ?? this.firstSeenAt,
  );
  ContactRow copyWithCompanion(ContactRowsCompanion data) {
    return ContactRow(
      nodeId: data.nodeId.present ? data.nodeId.value : this.nodeId,
      signingPublicKey: data.signingPublicKey.present
          ? data.signingPublicKey.value
          : this.signingPublicKey,
      agreementPublicKey: data.agreementPublicKey.present
          ? data.agreementPublicKey.value
          : this.agreementPublicKey,
      trustLevel: data.trustLevel.present
          ? data.trustLevel.value
          : this.trustLevel,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      firstSeenAt: data.firstSeenAt.present
          ? data.firstSeenAt.value
          : this.firstSeenAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ContactRow(')
          ..write('nodeId: $nodeId, ')
          ..write('signingPublicKey: $signingPublicKey, ')
          ..write('agreementPublicKey: $agreementPublicKey, ')
          ..write('trustLevel: $trustLevel, ')
          ..write('displayName: $displayName, ')
          ..write('firstSeenAt: $firstSeenAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    nodeId,
    $driftBlobEquality.hash(signingPublicKey),
    $driftBlobEquality.hash(agreementPublicKey),
    trustLevel,
    displayName,
    firstSeenAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ContactRow &&
          other.nodeId == this.nodeId &&
          $driftBlobEquality.equals(
            other.signingPublicKey,
            this.signingPublicKey,
          ) &&
          $driftBlobEquality.equals(
            other.agreementPublicKey,
            this.agreementPublicKey,
          ) &&
          other.trustLevel == this.trustLevel &&
          other.displayName == this.displayName &&
          other.firstSeenAt == this.firstSeenAt);
}

class ContactRowsCompanion extends UpdateCompanion<ContactRow> {
  final Value<String> nodeId;
  final Value<Uint8List> signingPublicKey;
  final Value<Uint8List> agreementPublicKey;
  final Value<int> trustLevel;
  final Value<String?> displayName;
  final Value<DateTime> firstSeenAt;
  final Value<int> rowid;
  const ContactRowsCompanion({
    this.nodeId = const Value.absent(),
    this.signingPublicKey = const Value.absent(),
    this.agreementPublicKey = const Value.absent(),
    this.trustLevel = const Value.absent(),
    this.displayName = const Value.absent(),
    this.firstSeenAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ContactRowsCompanion.insert({
    required String nodeId,
    required Uint8List signingPublicKey,
    required Uint8List agreementPublicKey,
    required int trustLevel,
    this.displayName = const Value.absent(),
    required DateTime firstSeenAt,
    this.rowid = const Value.absent(),
  }) : nodeId = Value(nodeId),
       signingPublicKey = Value(signingPublicKey),
       agreementPublicKey = Value(agreementPublicKey),
       trustLevel = Value(trustLevel),
       firstSeenAt = Value(firstSeenAt);
  static Insertable<ContactRow> custom({
    Expression<String>? nodeId,
    Expression<Uint8List>? signingPublicKey,
    Expression<Uint8List>? agreementPublicKey,
    Expression<int>? trustLevel,
    Expression<String>? displayName,
    Expression<DateTime>? firstSeenAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (nodeId != null) 'node_id': nodeId,
      if (signingPublicKey != null) 'signing_public_key': signingPublicKey,
      if (agreementPublicKey != null)
        'agreement_public_key': agreementPublicKey,
      if (trustLevel != null) 'trust_level': trustLevel,
      if (displayName != null) 'display_name': displayName,
      if (firstSeenAt != null) 'first_seen_at': firstSeenAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ContactRowsCompanion copyWith({
    Value<String>? nodeId,
    Value<Uint8List>? signingPublicKey,
    Value<Uint8List>? agreementPublicKey,
    Value<int>? trustLevel,
    Value<String?>? displayName,
    Value<DateTime>? firstSeenAt,
    Value<int>? rowid,
  }) {
    return ContactRowsCompanion(
      nodeId: nodeId ?? this.nodeId,
      signingPublicKey: signingPublicKey ?? this.signingPublicKey,
      agreementPublicKey: agreementPublicKey ?? this.agreementPublicKey,
      trustLevel: trustLevel ?? this.trustLevel,
      displayName: displayName ?? this.displayName,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (nodeId.present) {
      map['node_id'] = Variable<String>(nodeId.value);
    }
    if (signingPublicKey.present) {
      map['signing_public_key'] = Variable<Uint8List>(signingPublicKey.value);
    }
    if (agreementPublicKey.present) {
      map['agreement_public_key'] = Variable<Uint8List>(
        agreementPublicKey.value,
      );
    }
    if (trustLevel.present) {
      map['trust_level'] = Variable<int>(trustLevel.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (firstSeenAt.present) {
      map['first_seen_at'] = Variable<DateTime>(firstSeenAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ContactRowsCompanion(')
          ..write('nodeId: $nodeId, ')
          ..write('signingPublicKey: $signingPublicKey, ')
          ..write('agreementPublicKey: $agreementPublicKey, ')
          ..write('trustLevel: $trustLevel, ')
          ..write('displayName: $displayName, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ContactRowsTable contactRows = $ContactRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [contactRows];
}

typedef $$ContactRowsTableCreateCompanionBuilder =
    ContactRowsCompanion Function({
      required String nodeId,
      required Uint8List signingPublicKey,
      required Uint8List agreementPublicKey,
      required int trustLevel,
      Value<String?> displayName,
      required DateTime firstSeenAt,
      Value<int> rowid,
    });
typedef $$ContactRowsTableUpdateCompanionBuilder =
    ContactRowsCompanion Function({
      Value<String> nodeId,
      Value<Uint8List> signingPublicKey,
      Value<Uint8List> agreementPublicKey,
      Value<int> trustLevel,
      Value<String?> displayName,
      Value<DateTime> firstSeenAt,
      Value<int> rowid,
    });

class $$ContactRowsTableFilterComposer
    extends Composer<_$AppDatabase, $ContactRowsTable> {
  $$ContactRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get nodeId => $composableBuilder(
    column: $table.nodeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get signingPublicKey => $composableBuilder(
    column: $table.signingPublicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get agreementPublicKey => $composableBuilder(
    column: $table.agreementPublicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get trustLevel => $composableBuilder(
    column: $table.trustLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get firstSeenAt => $composableBuilder(
    column: $table.firstSeenAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ContactRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $ContactRowsTable> {
  $$ContactRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get nodeId => $composableBuilder(
    column: $table.nodeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get signingPublicKey => $composableBuilder(
    column: $table.signingPublicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get agreementPublicKey => $composableBuilder(
    column: $table.agreementPublicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get trustLevel => $composableBuilder(
    column: $table.trustLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get firstSeenAt => $composableBuilder(
    column: $table.firstSeenAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ContactRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ContactRowsTable> {
  $$ContactRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get nodeId =>
      $composableBuilder(column: $table.nodeId, builder: (column) => column);

  GeneratedColumn<Uint8List> get signingPublicKey => $composableBuilder(
    column: $table.signingPublicKey,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get agreementPublicKey => $composableBuilder(
    column: $table.agreementPublicKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get trustLevel => $composableBuilder(
    column: $table.trustLevel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get firstSeenAt => $composableBuilder(
    column: $table.firstSeenAt,
    builder: (column) => column,
  );
}

class $$ContactRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ContactRowsTable,
          ContactRow,
          $$ContactRowsTableFilterComposer,
          $$ContactRowsTableOrderingComposer,
          $$ContactRowsTableAnnotationComposer,
          $$ContactRowsTableCreateCompanionBuilder,
          $$ContactRowsTableUpdateCompanionBuilder,
          (
            ContactRow,
            BaseReferences<_$AppDatabase, $ContactRowsTable, ContactRow>,
          ),
          ContactRow,
          PrefetchHooks Function()
        > {
  $$ContactRowsTableTableManager(_$AppDatabase db, $ContactRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ContactRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ContactRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ContactRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> nodeId = const Value.absent(),
                Value<Uint8List> signingPublicKey = const Value.absent(),
                Value<Uint8List> agreementPublicKey = const Value.absent(),
                Value<int> trustLevel = const Value.absent(),
                Value<String?> displayName = const Value.absent(),
                Value<DateTime> firstSeenAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ContactRowsCompanion(
                nodeId: nodeId,
                signingPublicKey: signingPublicKey,
                agreementPublicKey: agreementPublicKey,
                trustLevel: trustLevel,
                displayName: displayName,
                firstSeenAt: firstSeenAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String nodeId,
                required Uint8List signingPublicKey,
                required Uint8List agreementPublicKey,
                required int trustLevel,
                Value<String?> displayName = const Value.absent(),
                required DateTime firstSeenAt,
                Value<int> rowid = const Value.absent(),
              }) => ContactRowsCompanion.insert(
                nodeId: nodeId,
                signingPublicKey: signingPublicKey,
                agreementPublicKey: agreementPublicKey,
                trustLevel: trustLevel,
                displayName: displayName,
                firstSeenAt: firstSeenAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ContactRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ContactRowsTable,
      ContactRow,
      $$ContactRowsTableFilterComposer,
      $$ContactRowsTableOrderingComposer,
      $$ContactRowsTableAnnotationComposer,
      $$ContactRowsTableCreateCompanionBuilder,
      $$ContactRowsTableUpdateCompanionBuilder,
      (
        ContactRow,
        BaseReferences<_$AppDatabase, $ContactRowsTable, ContactRow>,
      ),
      ContactRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ContactRowsTableTableManager get contactRows =>
      $$ContactRowsTableTableManager(_db, _db.contactRows);
}
