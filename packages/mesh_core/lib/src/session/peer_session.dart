import 'package:cryptography/cryptography.dart';

/// Key material learned about a peer via the discovery handshake
/// ([MeshLink]), scoped to the lifetime of one transport connection. Not a
/// trust decision -- persisted, user-visible trust/contacts is a later
/// checkpoint (ARCHITECTURE.md §7, §9); this is just "who am I currently
/// talking to and what are their keys" for the duration of a live link.
class PeerSession {
  const PeerSession({
    required this.remoteId,
    required this.nodeId,
    required this.signingPublicKey,
    required this.agreementPublicKey,
  });

  /// Transport-level connection-addressable id -- ephemeral, changes
  /// across reconnects (e.g. Nearby's `endpointId`).
  final String remoteId;

  /// This peer's permanent Node ID, derived from [signingPublicKey] --
  /// stable across reconnects. Use this, not [remoteId], for anything
  /// that should survive the peer disconnecting and reconnecting (e.g.
  /// message history).
  final String nodeId;

  final SimplePublicKey signingPublicKey;
  final SimplePublicKey agreementPublicKey;
}
