import 'package:cryptography/cryptography.dart';

/// Key material learned about a peer via the discovery handshake
/// ([MeshLink]), scoped to the lifetime of one transport connection. Not a
/// trust decision -- persisted, user-visible trust/contacts is a later
/// checkpoint (ARCHITECTURE.md §7, §9); this is just "who am I currently
/// talking to and what are their keys" for the duration of a live link.
class PeerSession {
  const PeerSession({
    required this.remoteId,
    required this.signingPublicKey,
    required this.agreementPublicKey,
  });

  final String remoteId;
  final SimplePublicKey signingPublicKey;
  final SimplePublicKey agreementPublicKey;
}
