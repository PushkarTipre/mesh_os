/// A nearby MeshOS peer, from the app's point of view -- combines what
/// [Transport] discovery/connection events report with what [MeshLink]'s
/// handshake has learned so far.
class MeshDevice {
  const MeshDevice({
    required this.remoteId,
    this.nodeId,
    required this.connected,
    required this.sessionReady,
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

  MeshDevice copyWith({
    String? nodeId,
    bool? connected,
    bool? sessionReady,
  }) {
    return MeshDevice(
      remoteId: remoteId,
      nodeId: nodeId ?? this.nodeId,
      connected: connected ?? this.connected,
      sessionReady: sessionReady ?? this.sessionReady,
    );
  }
}
