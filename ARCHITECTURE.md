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

**Resolved privacy boundary (as implemented, CP3/CP4):** the permanent public key is never included in what advertising/discovery broadcasts — only the temporary ID (via the transport's advertised name, e.g. Nearby's `userNickName`). A device doing passive scanning without ever connecting learns nothing but a rotating token. The permanent public key is revealed only in the post-*connection* discovery handshake (`MeshLink`, §5) — i.e. to peers you actually establish a link with, not to everyone who can see you nearby. Through CP4, every discovered MeshOS node is auto-connected to (see §5), so in practice this boundary is "connect" vs. "don't," not yet a deliberate trust decision — gating *who gets a handshake at all* behind trust/relay policy is Checkpoint 5.

### Routing address (a third identifier, added Checkpoint 6)

Multi-hop delivery introduced a real problem the temp-ID scheme can't solve: a packet in store-and-forward can sit with a relay for hours, but the destination's temp ID has already rotated (every 10 minutes) many times over by the time it arrives, so an address computed at send time can never match at delivery time.

The fix is a **third identifier**, distinct from both the display-facing Node ID and the rotating temp ID: a stable 8-byte `routingAddress`, derived the same way as the Node ID (a prefix of `SHA-256(signing public key)`, just fewer bytes) but never rotating. Multi-hop `data`/`ack` packets address `tempSourceId`/`tempDestId` with routing addresses instead of temp IDs; direct, single-hop packets are unaffected and keep using the rotating temp ID exactly as before (they're distinguished on the wire by whether `tempDestId` is the `broadcastDestination` sentinel — direct — or a real routing address — routed).

This is a deliberate, narrower privacy trade-off than the temp-ID system, scoped only to multi-hop traffic: an observer who sees the same routing address recur across packets over time can infer "these all go to/from the same node," without learning who that is (a routing address, like a Node ID, doesn't reveal the public key itself). Recording this trade-off explicitly here rather than leaving it implicit in the code is the point — it should be revisited if MeshOS ever needs stronger anonymity guarantees for routed traffic specifically.

---

## 4. Trust model

Every discovered node is in exactly one level:

| Level | Sees profile | Can message | Can relay via us | Notes |
|---|---|---|---|---|
| **Trusted** | full | yes | yes | mutual, explicit key exchange (QR/NFC/code) |
| **Known** | limited | yes | yes | interacted before |
| **Unknown** | none | no (relay only) | policy-dependent | auto-discovered |
| **Blocked** | none | no | no | ignored entirely, no routing |

**Implemented as of Checkpoint 5** (`TrustStore`/`Contact`/`TrustLevel` in `mesh_core`, enforced in `MeshLink`), with one clarified departure from the table above: through CP5, **Known and Unknown behave identically** -- both can message (matching CP4's exit criterion, where two never-met phones already chat with no prior trust step), and "Unknown" in practice just means "no stored `Contact` yet," which stops being true the instant a discovery handshake completes (auto-promoted to Known -- "interacted before"). What actually differs by level today:
- **Blocked** — refused a session at handshake time, or torn down immediately if already connected, at both send and receive (`MeshLink._handleDiscovery`/`_onDataEvent`/`sendData`). As of Checkpoint 6, this also covers *routed* traffic: if a multi-hop packet's resolved original sender is blocked, the recipient drops it silently instead of delivering it, even though it successfully routed through one or more relays to get there.
- **Trusted** — the only level with a `displayName` (see §5's privacy boundary below).
- **"Can relay via us"** (Checkpoint 6's `RelayPolicy`) is keyed off the *direct* peer handing a node its bytes, not the packet's ultimate origin — `RelayPolicy.trustedContactsOnly` means "only relay for direct peers I've explicitly trusted," which is a stricter, simpler v1 reading of the "policy-dependent" cell above (not yet the full per-level matrix from the original table).

Becoming contacts = both users intentionally exchange identities (QR code, nearby exchange, NFC, share code). Once accepted: public keys stored, nicknames visible, secure comms begin. Implemented via `IdentityCard` (`mesh_core`) -- a self-certifying, signed bundle of public keys + a chosen display name, exchanged as a QR code in `mesh_console` (`qr_flutter` to show, `mobile_scanner` to scan). `MeshOS.trustFromIdentityCard()` verifies and upgrades that peer to Trusted in one step.

### Relay permissions (user-controlled)
Relay everything / trusted-contacts only / emergency only / disabled — optionally gated by charging state, Wi-Fi, or battery threshold. Not implemented yet -- lands with routing in Checkpoint 6.

---

## 5. Discovery

Continuous scan + advertise. Two distinct phases, with different information exposure:

1. **Passive discovery** (advertise/scan, no connection yet): nodes exchange only the temporary ID (carried in the transport's advertised name) and whatever the transport itself exposes (e.g. Nearby's service ID, used to filter to MeshOS nodes only). No public key, no personal information.
2. **Post-connection handshake** (`MeshLink`, implemented CP3): once two nodes connect, both immediately send a signed packet containing their permanent signing + agreement public keys. This is *self-certifying* — a signature only verifies against the public key it claims to belong to, so a valid signature over that packet is proof of private-key possession, with no separate key-exchange step needed. This is what lets `MeshOS.send()` encrypt to a specific recipient (§10) without a pre-existing trust relationship.

Through Checkpoint 4, connection itself is unconditional: every discovered MeshOS node is auto-connected to and auto-accepted, so every direct peer eventually learns your permanent public key. Checkpoint 5 adds the missing piece — trust/relay policy deciding *whether to connect at all*, not just what happens after.

---

## 6. Packet structure

Binary format, fixed header + encrypted payload:

```
Version | Type | Packet ID | Timestamp | Temp Source ID | Temp Dest ID |
TTL | Hop Count | Priority | Encrypted Payload | Signature | Checksum
```

Packet types: `discovery`, `data`, `broadcast`, `ack`, `sync`, `file`, `heartbeat`. `broadcast` and `file` are implemented as of Checkpoint 7 (§7) -- `sync` and `heartbeat` remain reserved, unused.

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

**v1 flooding implemented as of Checkpoint 6** (`MeshLink`): a `data`/`ack` packet not addressed to this node (its `tempDestId` doesn't match this node's `routingAddress`, §3) is decremented via `MeshPacket.forwarded()` and flooded to every other connected peer, deduplicated by packet ID so it's forwarded at most once per relay. Relay policy (`RelayPolicy`: `everything` / `trustedContactsOnly` / `disabled`) gates whether a node relays *at all* on behalf of a given direct peer — battery/charging/Wi-Fi-gated policy from the original design is deferred. A simple per-source sliding-window cap (basic DoS hygiene) stops one noisy or hostile neighbor from turning a node into an unbounded flood amplifier for their traffic.

### Store and forward
If the destination is unreachable, packets persist locally and hop opportunistically (`Alice → stored → Charlie appears → forwarded → Charlie stores → Bob appears → delivered`). Every packet has TTL + expiration so the mesh doesn't fill with dead traffic.

**Implemented as of Checkpoint 6**, in-memory only: `MeshLink` keeps an unrouted packet (one it originated via `sendToNode`, or one it's relaying for someone else) in a local cache until it either gets forwarded successfully or its `storeAndForwardExpiry` (default 24h) elapses. Every new connection is a fresh delivery opportunity — the store is re-flooded to a peer the moment their discovery handshake completes. **Known limitation:** this doesn't survive an app restart (it's not SQLite-backed, unlike contacts/trust — see §9); a relay that's killed and relaunched loses whatever it was holding. Persisting the relay store the same way contacts are persisted is a natural, not-yet-built follow-up.

### Reliability
ACKs, retries, duplicate detection (packet-ID cache), sequence numbers, expiration, delivery confirmation.

**Single-hop implemented as of Checkpoint 4** (`MeshLink.sendData`): a `data` packet is retried on a timer until the peer's `ack` packet arrives or retries are exhausted (`DeliveryStatus.delivered`/`failed`); a retry can cause the same packet to arrive twice (e.g. only the ack was lost), so incoming packets are deduplicated by packet ID (`PacketDedupCache`) before being surfaced to the app — the receiver still re-sends the ack either way.

**End-to-end (multi-hop) implemented as of Checkpoint 6** (`MeshLink.sendToNode`): once the actual destination decrypts a routed packet, it sends its own `ack` back through the mesh (flooded/stored exactly like data traffic, addressed via routing address), which the original sender eventually receives and matches to resolve its pending `sendToNode` call. Unlike the bounded, timed retry of a direct send, a routed send has no fixed retry schedule — it just waits, resolving `delivered` whenever the ack eventually shows up (which could be much later) or `failed` once the packet expires from the local store-and-forward cache without one. `MeshOS.send()` picks whichever path applies automatically: direct if the destination is a live neighbor, routed otherwise — callers never need to know how many hops a message took.

### Broadcast and topic pub/sub

**Implemented as of Checkpoint 7** (`MeshLink.broadcast`/`publish`/`subscribe`, `packages/mesh_core/lib/src/session/mesh_link.dart`). A `broadcast` packet has no destination at all -- unlike `data`/`ack`, it's never addressed via `routingAddress`, it's just flooded (TTL decrement + dedup, same machinery as §7's relay path) to every reachable node. Because there's no destination to encrypt for, the payload isn't encrypted; instead it's **self-certifying**, the same trick used by the discovery handshake (§5) and `IdentityCard` (§9): the payload embeds the sender's Ed25519 public key, and the packet's signature must verify against that embedded key. This is what lets a node relay or receive a broadcast from someone it has never met -- there's no prior key exchange to require. A forged payload (embedded key that doesn't match whoever actually signed it) fails verification and is dropped, not relayed.

Topic pub/sub (`publish`/`subscribe`) reuses the identical wire mechanism -- a `publish` is a `broadcast` with a UTF-8 topic tag prepended to the payload (empty tag = plain broadcast). **Subscription is local-only filtering, not topic-aware routing:** every broadcast-capable node relays every broadcast/publish it sees regardless of its own subscriptions (a node with no interest in a topic might still be the only bridge to a node that does care), and only decides whether to *surface* it to the app based on `subscribe`d topics. This keeps the routing layer simple at the cost of some wasted relay bandwidth on topics nobody nearby cares about -- an acceptable v1 trade-off, matching the flooding-based routing model's own trade-offs (§7).

### File transfer

**Implemented as of Checkpoint 7** (`FileTransferManager`, `packages/mesh_core/lib/src/files/file_transfer.dart`), built entirely on top of `MeshLink.sendToNode`/`sendData` rather than a parallel reliability mechanism -- a file is split into chunks (default 16 KB), each sent as an ordinary point-to-point message tagged `PacketType.file` instead of `PacketType.data` (a `type` parameter threaded through `sendData`/`sendToNode`), so it inherits direct/routed addressing, retry, and acking for free. Chunks are sent strictly in order, one at a time, each bounded to a 15s wait (rather than inheriting the routed path's up-to-24h store-and-forward default) so a stalled transfer surfaces as `FileTransferStatus.paused` promptly instead of hanging; because every attempt uses a fresh packet ID, a late ack for a timed-out attempt is simply ignored, never double-counted. A paused transfer resumes automatically, from the last acked chunk (not from scratch), the next time `MeshLink.sessionEstablished` reports a completed handshake with the same destination node -- this is what makes it survive walking out of range and back into it. **Known limitation:** transfer state (in-flight chunks, resume point) is in-memory only, like the relay store (§7) -- an app restart mid-transfer loses it; `mesh_console`'s demo UI also keeps received/sent files session-only, not written to any chat history.

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

**Implemented as of Checkpoint 5**, contacts only so far: `drift` (`packages/mesh_os/lib/src/storage/`), one `ContactRows` table backing `DriftTrustStore`. Pending packets, routing cache, and preferences don't exist yet -- they land in later checkpoints (store-and-forward is Checkpoint 6) and will join the same database rather than starting a new one. Tested against a real (in-memory) SQLite engine via `NativeDatabase.memory()`, not mocked.

---

## 10. Public Flutter API

```dart
final mesh = MeshOS();
await mesh.initialize();       // load/create identity
await mesh.start();            // start discovery + transports

await mesh.send(destination: nodeId, payload: bytes);  // direct or multi-hop, transparently -- returns DeliveryStatus
await mesh.broadcast(bytes);                            // fan-out to everyone within TTL, self-certifying
await mesh.publish('topic', bytes);                     // broadcast + topic tag
mesh.subscribe('topic');                                // surface that topic's publishes on messages
mesh.unsubscribe('topic');

final transferId = mesh.sendFile(                        // chunked, resumable, progress-tracked
  destination: nodeId, filename: 'photo.jpg', bytes: fileBytes,
);
mesh.outgoingFileProgress.listen((progress) => ...);
mesh.incomingFiles.listen((file) => ...);

mesh.devices;                  // reactive list of nearby nodes
mesh.deviceUpdates.listen((devices) => ...);
mesh.messages.listen((msg) => ...);            // chat + broadcast/publish (msg.topic != null); never file chunks

await mesh.trust(nodeId);
await mesh.block(nodeId);
await mesh.unblock(nodeId);
await mesh.createIdentityCard(displayName: 'Pushkar');   // QR/NFC/share-code payload
await mesh.trustFromIdentityCard(scannedPayload);        // verifies + trusts in one step
```

`initialize`, `start`, `send`, `devices`, `deviceUpdates`, and `messages` are implemented as of Checkpoint 4 (`packages/mesh_os/lib/src/mesh_os.dart`), backed by `mesh_core`'s `MeshLink` (handshake, crypto, ACK/retry) and a `Transport` implementation (`mesh_transport_nearby`, Checkpoint 3). `trust`/`block`/`unblock`/`createIdentityCard`/`trustFromIdentityCard` are implemented as of Checkpoint 5, backed by `mesh_core`'s `TrustStore`/`IdentityCard` and `mesh_os`'s SQLite-backed `DriftTrustStore` (§9). As of Checkpoint 6, `send` transparently routes through relays (`MeshLink.sendToNode`, §7) when the destination isn't a direct neighbor -- callers never chose "direct" vs "routed" and don't need to. As of Checkpoint 7, `broadcast`/`publish`/`subscribe`/`unsubscribe`/`sendFile`/`outgoingFileProgress`/`incomingFiles` are implemented, thin wrappers over `mesh_core`'s `MeshLink` broadcast/pub-sub methods and `FileTransferManager` (§7). `messages` now filters out file-transfer chunks (`InboundMessage.isFileChunk`) before surfacing to the app -- use `incomingFiles` for those instead.

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
