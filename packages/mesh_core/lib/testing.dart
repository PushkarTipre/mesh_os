/// Test doubles for exercising MeshOS's protocol logic (identity, crypto,
/// handshake, routing, relay, trust, broadcast/pub-sub, file transfer)
/// with zero radio hardware -- used by `mesh_core`'s own test suite, and
/// available here for any consumer that wants the same capability (e.g.
/// `mesh_console`'s in-app Mesh Simulator screen).
///
/// Deliberately a separate entry point from `package:mesh_core/mesh_core.dart`
/// -- a real app's production code should never end up importing test
/// doubles by accident.
library;

export 'src/testing/fake_transport.dart';
