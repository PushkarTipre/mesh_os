/// Governs whether [MeshLink] relays a packet that isn't addressed to this
/// node (ARCHITECTURE.md §4, §18).
///
/// Deliberately just three levels for v1 -- battery/charging/Wi-Fi-gated
/// relaying from the original design is a later polish item, not core
/// routing logic.
enum RelayPolicy {
  /// Relay for anyone, regardless of trust level.
  everything,

  /// Only relay packets that arrived from a [TrustLevel.trusted] direct
  /// peer (a proxy for "only spend my battery/bandwidth relaying for
  /// people I trust").
  trustedContactsOnly,

  /// Never relay -- still send/receive directly, just don't forward
  /// other nodes' traffic.
  disabled,
}
