## 0.1.0

Initial development release -- not yet published. Pre-1.0: expect breaking API changes between minor versions until 1.0.

- Node identity: Ed25519 signing + X25519 agreement keypairs, permanent Node ID, rotating anti-tracking temporary ID, stable routing address for multi-hop addressing.
- `MeshPacket` binary wire format with fragmentation/reassembly for transports with small payload ceilings.
- `MeshLink`: transport-agnostic session handshake, encryption, single-hop reliable delivery (ACK/retry/dedup), multi-hop routing (flooding + store-and-forward + end-to-end ack), trust enforcement, relay policy and rate limiting, broadcast and topic pub/sub, chunked resumable file transfer, and live mesh activity stats (`MeshLinkStats`).
- `Transport` interface plus `MultiTransport`, which runs several transport implementations side by side and picks the best available link per peer automatically.
- `TrustStore`/`Contact`/`IdentityCard` trust and contact primitives.
- `FakeTransport`/`FakeTransportNetwork` test doubles for exercising the whole stack without radio hardware.
