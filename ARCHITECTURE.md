# MeshOS — Architecture

**Decentralized offline networking runtime for Flutter.**
Version 1.0 (working document — derived from the original architecture proposal, annotated with concrete technology choices and platform constraints).

MeshOS is **not a chat app**. It is a reusable networking SDK that lets any Flutter app communicate without internet, servers, phone numbers, emails, Firebase, or cloud databases. Every device running MeshOS is an equal node that can discover peers, relay encrypted packets, store-and-forward messages, and participate in a self-organizing mesh.

---

## 1. Core principles

1. **No central authority** — no backend, no master server, no login, no cloud routing. Every node is equal.
2. **Privacy first** — unknown devices learn only enough to relay packets. Personal info is shared only with explicitly trusted contacts.
3. **End-to-end encryption** — every payload is encrypted. Relays never see message contents, files, or contact lists.
4. **Trust-based networking** — each device decides whom it trusts; trust gates visibility, communication, and relay permissions.
5. **Offline first** — the entire network functions in airplane mode. Internet is optional, never required.

---

## 2. System layers

```
Applications (chat, file share, notes, games, IoT, attendance, ...)
        ↓
MeshOS SDK (public Dart API)
        ↓
┌─────────────────────────────────────────────────┐
│ Identity | Discovery | Routing | Transport      │
│ Encryption | Storage | Synchronization          │
└─────────────────────────────────────────────────┘
        ↓
BLE | Bluetooth Classic | Nearby Connections | Wi-Fi Direct | Local Wi-Fi
```

The application never touches Bluetooth directly. It calls `mesh.send()` and listens to `mesh.messages`.

### Repository layout (target)

The SDK core must be **pure Dart** (unit-testable on a laptop, no device needed). Platform transports live in separate packages. The current app becomes the example/dev-harness app.

```
mesh_os/
├── packages/
│   ├── mesh_core/            # pure Dart: identity, packets, crypto, routing,
│   │                         #   store-and-forward, trust model (no Flutter imports)
│   ├── mesh_transport_nearby/# Google Nearby Connections — transport v1 (Android)
│   ├── mesh_transport_ble/   # BLE transport — later (no-Play-services devices,
│   │                         #   and the interop path when iOS support returns)
│   └── mesh_os/              # the public SDK: glues core + transports + storage
├── apps/
│   └── mesh_console/         # dev/demo app (this repo's current lib/ moves here)
└── docs/
```

**Design rule:** anything that can be pure Dart *must* be pure Dart. Only transports and secure key storage touch platform channels.

---

## 3. Node identity

Generated on first launch, stored on-device, never uploaded.

| Item | Choice |
|---|---|
| Signing keypair | **Ed25519** (authenticity / packet signatures) |
| Key-agreement keypair | **X25519** (ECDH for payload encryption) |
| Node ID | `SHA-256(public signing key)` — first 16 bytes, hex |
| Payload cipher | **ChaCha20-Poly1305** (or AES-GCM) with the ECDH-derived key |
| Dart package | `cryptography` (pure Dart, supports all of the above) |
| Private key storage | `flutter_secure_storage` (Keychain / Android Keystore) |

No phone numbers, usernames, emails, or passwords.

### Human-friendly identity (optional)
Display name, nickname, avatar — shared **only** with trusted contacts. Unknown nodes never receive it.

### Temporary identity (anti-tracking)
Nodes broadcast a rotating temporary ID (e.g. every 10 minutes) instead of the permanent Node ID. Only trusted peers can associate temporary IDs with permanent identities (via a keyed derivation only contacts can compute). Reduces passive tracking.

---

## 4. Trust model

Every discovered node is in exactly one level:

| Level | Sees profile | Can message | Can relay via us | Notes |
|---|---|---|---|---|
| **Trusted** | full | yes | yes | mutual, explicit key exchange (QR/NFC/code) |
| **Known** | limited | yes | yes | interacted before |
| **Unknown** | none | no (relay only) | policy-dependent | auto-discovered |
| **Blocked** | none | no | no | ignored entirely, no routing |

Becoming contacts = both users intentionally exchange identities (QR code, nearby exchange, NFC, share code). Once accepted: public keys stored, nicknames visible, secure comms begin.

### Relay permissions (user-controlled)
Relay everything / trusted-contacts only / emergency only / disabled — optionally gated by charging state, Wi-Fi, or battery threshold.

---

## 5. Discovery

Continuous scan + advertise. Nodes exchange **only**: temporary ID, public key, MeshOS version, supported transports. Nothing personal.

---

## 6. Packet structure

Binary format, fixed header + encrypted payload:

```
Version | Type | Packet ID | Timestamp | Temp Source ID | Temp Dest ID |
TTL | Hop Count | Priority | Encrypted Payload | Signature | Checksum
```

Packet types: `discovery`, `data`, `broadcast`, `ack`, `sync`, `file`, `heartbeat`.

**Practical constraint:** every transport has a payload ceiling (Nearby Connections `BYTES` ≈ 32 KB; BLE MTU is 23–512 bytes negotiated). The transport layer must implement **fragmentation and reassembly**; the packet layer stays transport-agnostic.

---

## 7. Routing

Deliberately staged — do not build AODV first:

| Version | Algorithm |
|---|---|
| v1 | Flooding (TTL + dedup cache) |
| v2 | Breadth-first / probabilistic gossip |
| v3 | Distance vector |
| v4 | AODV |
| future | Adaptive routing on historical encounter graphs |

Routing metrics (later versions): signal quality, hop count, battery, reliability, historical success rate.

### Store and forward
If the destination is unreachable, packets persist locally and hop opportunistically (`Alice → stored → Charlie appears → forwarded → Charlie stores → Bob appears → delivered`). Every packet has TTL + expiration so the mesh doesn't fill with dead traffic.

### Reliability
ACKs, retries, duplicate detection (packet-ID cache), sequence numbers, expiration, delivery confirmation.

---

## 8. Security model

- Payloads encrypted to the **receiver's** key (X25519 ECDH → symmetric AEAD). Only the receiver decrypts.
- Every packet **signed** (Ed25519) — relays can verify integrity without reading content.
- Relays see only: routing header + encrypted bytes.
- Private keys never leave the device.

**Known limitations to document honestly (not solved in v1):** traffic-analysis resistance is partial (packet sizes/timing are observable), flooding is DoS-able by a hostile node (mitigation: per-peer rate limits), and temporary-ID rotation only *reduces* tracking. These are acceptable v1 trade-offs; record them in a `SECURITY.md` threat model as the design matures.

---

## 9. Local storage

SQLite (`drift` or `sqflite`) for: known nodes, trusted contacts, pending packets, delivered-packet dedup cache, routing cache, public keys, preferences. Private keys go in secure storage, **not** SQLite.

---

## 10. Public Flutter API (target)

```dart
final mesh = MeshOS();
await mesh.initialize();       // load/create identity
await mesh.start();            // start discovery + transports

await mesh.send(destination: nodeId, payload: bytes);
await mesh.broadcast(bytes);

mesh.devices;                  // reactive list of nearby nodes
mesh.messages.listen((msg) => ...);

await mesh.trust(nodeId);
await mesh.block(nodeId);
```

---

## 11. Platform reality check (constraints the design must respect)

**Scope decision (2026-07): v1 targets Android only. iOS is deferred.** This changes the transport calculus — read before picking up any transport work:

1. **Transport v1 = Google Nearby Connections.** With iOS out of scope, we don't need the lowest-common-denominator transport. Nearby Connections works fully offline, handles advertising/discovery/connection for us, and automatically upgrades links from Bluetooth to Wi-Fi Direct/hotspot for bandwidth — orders of magnitude faster than BLE and far less implementation risk than BLE peripheral mode in Flutter. Candidate plugin: `nearby_connections`.
2. **Nearby Connections caveats:** requires Google Play services (de-Googled/AOSP devices are excluded until the BLE transport exists); `BYTES` payloads are capped (~32 KB), so the CP2 fragmentation layer still applies to larger packets; simultaneous connections are limited to a handful of peers — fine for a mesh, where each node only needs a few neighbors.
3. **BLE remains on the roadmap as transport v2**, for two reasons: devices without Play services, and it is the only Android↔iOS interop path when iOS support returns. The `Transport` interface in `mesh_core` must stay clean enough that BLE slots in without touching core.
4. **Android permissions are a project of their own:** `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (API 31+), `NEARBY_WIFI_DEVICES` (API 33+), location permission on older APIs, plus foreground-service requirements for background operation. v1 targets **foreground operation**; background service work is a later, explicitly-scoped effort.
5. **Physical devices are required for transport testing.** Emulators don't do Bluetooth/Wi-Fi Direct. Minimum hardware: 2 Android phones with Play services (3 for multi-hop).

---

## 12. Example applications the SDK should eventually power

Secure chat, offline file sharing, classroom collaboration, multiplayer games, disaster communication, team coordination, sensor networks, collaborative notes.

## 13. Success criteria

A Flutter developer can add resilient offline communication to an app **without** implementing Bluetooth protocols, routing, encryption, sync, or packet forwarding themselves. Long-term: offline networking as simple as an HTTP client, while preserving decentralization, privacy, and end-to-end security.
