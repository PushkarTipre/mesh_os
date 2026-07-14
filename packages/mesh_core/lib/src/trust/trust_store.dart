import 'dart:async';

import 'contact.dart';
import 'trust_level.dart';

/// Pluggable persistence for [Contact]s. mesh_core stays pure Dart, so it
/// only defines this interface and an in-memory implementation for tests;
/// the real on-device implementation (SQLite via drift) lives in mesh_os.
abstract class TrustStore {
  Future<Contact?> getContact(String nodeId);

  Future<void> upsertContact(Contact contact);

  Future<List<Contact>> listContacts();

  /// Emits the full contact list every time it changes.
  Stream<List<Contact>> watchContacts();

  /// Convenience: [TrustLevel.unknown] if there's no stored contact.
  Future<TrustLevel> trustLevelFor(String nodeId) async {
    final contact = await getContact(nodeId);
    return contact?.trustLevel ?? TrustLevel.unknown;
  }
}

class InMemoryTrustStore implements TrustStore {
  final Map<String, Contact> _contacts = {};
  final StreamController<List<Contact>> _controller =
      StreamController<List<Contact>>.broadcast();

  @override
  Future<Contact?> getContact(String nodeId) async => _contacts[nodeId];

  @override
  Future<void> upsertContact(Contact contact) async {
    _contacts[contact.nodeId] = contact;
    _controller.add(_contacts.values.toList());
  }

  @override
  Future<List<Contact>> listContacts() async => _contacts.values.toList();

  @override
  Stream<List<Contact>> watchContacts() => _controller.stream;

  @override
  Future<TrustLevel> trustLevelFor(String nodeId) async =>
      _contacts[nodeId]?.trustLevel ?? TrustLevel.unknown;
}
