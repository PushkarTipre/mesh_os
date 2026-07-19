## 0.1.0

Initial development release -- not yet published. Pre-1.0: expect breaking API changes between minor versions until 1.0.

- `MeshOS` facade: `initialize`/`start`, reactive nearby-device list, `send` (direct or multi-hop, transparently), `messages`.
- Trust/contacts: `trust`/`block`/`unblock`, QR-based `IdentityCard` exchange, SQLite-backed (`drift`) persistent contact storage, secure-storage-backed identity persistence.
- Broadcast, topic pub/sub, and chunked resumable file transfer with progress reporting.
- Live mesh activity stats (`stats`/`statsUpdates`).
- Wraps `mesh_core`'s transport-agnostic protocol logic with `mesh_transport_nearby` (Google Nearby Connections) and `mesh_transport_ble` (Bluetooth Low Energy) running side by side via `MultiTransport`.
