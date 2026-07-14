/// The four trust levels from ARCHITECTURE.md §4.
///
/// [unknown] is never actually persisted -- it's what [TrustStore.trustLevelFor]
/// returns when there's no stored [Contact] at all. The moment a node is
/// stored (which happens automatically on the first completed discovery
/// handshake -- see `MeshLink`), it's at least [known].
enum TrustLevel {
  unknown,
  known,
  trusted,
  blocked,
}
