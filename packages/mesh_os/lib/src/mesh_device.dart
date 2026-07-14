import 'package:mesh_core/mesh_core.dart';

/// A nearby MeshOS peer, from the app's point of view -- combines what
/// [Transport] discovery/connection events report with what [MeshLink]'s
/// handshake has learned, and what the [TrustStore] has on file for them.
class MeshDevice {
  const MeshDevice({
    required this.remoteId,
    this.nodeId,
    required this.connected,
    required this.sessionReady,
    this.trustLevel = TrustLevel.unknown,
    this.displayName,
  });

  /// Transport-level connection-addressable id. Ephemeral -- changes
  /// across reconnects.
  final String remoteId;

  /// Permanent Node ID, known once the discovery handshake completes.
  /// Null before that (discovered but not yet connected/handshaked).
  final String? nodeId;

  final bool connected;

  /// True once the discovery handshake has completed and [MeshOS.send]
  /// can reach this peer.
  final bool sessionReady;

  /// This peer's current trust level (ARCHITECTURE.md §4). Every
  /// handshaked peer is at least [TrustLevel.known].
  final TrustLevel trustLevel;

  /// Only ever set for [TrustLevel.trusted] peers, via an explicit
  /// `IdentityCard` exchange (ARCHITECTURE.md §5's privacy boundary) --
  /// never learned from the ordinary discovery handshake.
  final String? displayName;

  MeshDevice copyWith({
    String? nodeId,
    bool? connected,
    bool? sessionReady,
    TrustLevel? trustLevel,
    String? displayName,
  }) {
    return MeshDevice(
      remoteId: remoteId,
      nodeId: nodeId ?? this.nodeId,
      connected: connected ?? this.connected,
      sessionReady: sessionReady ?? this.sessionReady,
      trustLevel: trustLevel ?? this.trustLevel,
      displayName: displayName ?? this.displayName,
    );
  }
}
