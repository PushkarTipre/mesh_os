# MeshOS — Roadmap & Checkpoints

How we get from an empty Flutter template to the MeshOS SDK. Each checkpoint has a **goal**, **tasks**, and an **exit criterion (demo)** — a checkpoint is done only when its demo works. Do not start a checkpoint until the previous one's demo passes.

Ordering rationale: everything that is pure Dart (identity, crypto, packets, routing logic) is built and unit-tested **before** touching Bluetooth, because transport work needs physical devices and is the highest-risk area. By the time we open the BLE box, everything above it already works.

---

## Checkpoint 0 — Project scaffolding ✅ definition of "started"

**Goal:** repo shaped like an SDK, not an app.

- [ ] Restructure to a melos/pub-workspace monorepo: `packages/mesh_core`, `packages/mesh_os`, `apps/mesh_console` (move current `lib/main.dart` there).
- [ ] `mesh_core` is pure Dart — enforce with `flutter analyze` + a CI check that it never imports `flutter/`.
- [ ] Add dependencies: `cryptography`, `flutter_secure_storage`, `drift` (or `sqflite`), lints.
- [ ] CI (GitHub Actions): `dart analyze` + `dart test` on every push.
- [ ] `git init` + first commit (repo is currently not under version control).

**Exit criterion:** `melos bootstrap && dart test` runs green from a clean clone; `mesh_console` app builds and runs on a phone.

---

## Checkpoint 1 — Identity & crypto core (pure Dart)

**Goal:** a node can be born.

- [ ] `NodeIdentity`: generate Ed25519 signing pair + X25519 agreement pair; derive Node ID = SHA-256(pubkey)[0..16].
- [ ] Persist/load identity via a storage interface (secure-storage impl lives in `mesh_os`, mock in tests).
- [ ] Sign/verify bytes; ECDH → ChaCha20-Poly1305 encrypt/decrypt round-trip between two in-memory identities.
- [ ] Temporary-ID rotation: derive rotating temp ID from (permanent key, time slot); trusted peers can match it, strangers can't.

**Exit criterion:** unit tests — two `NodeIdentity` instances exchange an encrypted+signed payload entirely in memory; tampered payloads fail verification; app restart preserves identity.

---

## Checkpoint 2 — Packet layer (pure Dart)

**Goal:** the wire format exists and is bulletproof.

- [ ] Binary codec for the packet header (version, type, id, timestamp, temp src/dst, TTL, hops, priority) + payload + signature + checksum.
- [ ] All 7 packet types (`discovery`, `data`, `broadcast`, `ack`, `sync`, `file`, `heartbeat`).
- [ ] Duplicate-detection cache (packet-ID LRU with expiry).
- [ ] Fragmentation/reassembly layer (MTU-parameterized) — written here, exercised for real in CP3.
- [ ] Fuzz/property tests: encode→decode round-trips; corrupt bytes never crash the decoder, they return errors.

**Exit criterion:** `dart test` green including a fuzz suite (random payloads, random corruption, truncated buffers).

---

## Checkpoint 3 — Nearby Connections transport, single hop ⚠️ highest risk so far

**Goal:** two physical phones exchange raw MeshOS packets with the screen on.

Android-only scope means transport v1 is **Google Nearby Connections**, not BLE (see ARCHITECTURE §11) — it handles discovery/connection for us and upgrades to Wi-Fi for bandwidth, cutting the riskiest part of the original plan.

- [ ] `Transport` interface in `mesh_core` (advertise, discover, connect, send bytes, byte stream in) — transport-agnostic so BLE can slot in later (CP8).
- [ ] `mesh_transport_nearby`: wrap the `nearby_connections` plugin (P2P_CLUSTER strategy) — time-boxed spike first to confirm plugin quality; fallback = own platform channels over the native Nearby API.
- [ ] Fragmentation from CP2 wired in for packets above the `BYTES` payload cap (~32 KB).
- [ ] Android runtime-permission flow (`BLUETOOTH_SCAN/ADVERTISE/CONNECT`, `NEARBY_WIFI_DEVICES`, location on older APIs).
- [ ] `mesh_console` debug screen: nearby devices list, connect/disconnect events, send-test-packet button, packet log.

**Exit criterion (demo):** two Android phones with no internet (Wi-Fi with no uplink or airplane mode + BT/Wi-Fi radios on) discover each other and exchange signed, encrypted packets; packet log shows verify+decrypt success. **This demo is the project's biggest de-risking moment.**

---

## Checkpoint 4 — Direct encrypted messaging (= PDF Phase 1 complete)

**Goal:** the public API works end-to-end for one hop.

- [ ] `MeshOS` facade: `initialize()`, `start()`, `send()`, `messages`, `devices`.
- [ ] Session establishment: discovery handshake (temp ID, pubkey, version, transports) → ECDH session.
- [ ] ACK + retry + delivery status for direct messages.
- [ ] Minimal chat UI in `mesh_console` (this is a test harness, not a product).

**Exit criterion (demo):** two phones, airplane mode, chat both directions; kill and reopen the app — identity and message history survive.

---

## Checkpoint 5 — Trust, contacts & persistence (= PDF Phase 2)

**Goal:** the trust model is real.

- [ ] SQLite schema: known nodes, contacts, keys, preferences (drift migrations from day one).
- [ ] Trust levels (trusted/known/unknown/blocked) enforced in the packet pipeline: profile data only to trusted; blocked = dropped at ingress.
- [ ] QR-code identity exchange (show + scan), mutual-accept flow.
- [ ] Display name/nickname/avatar shared to trusted contacts only.
- [ ] `trust(nodeId)` / `block(nodeId)` API.

**Exit criterion (demo):** two strangers see each other as "Unknown" (no names). QR exchange → names appear. Block → all traffic from that node ignored.

---

## Checkpoint 6 — Multi-hop routing + store-and-forward (= PDF Phase 3)

**Goal:** messages travel through strangers. This is the moment it becomes a *mesh*.

- [ ] Flooding router: TTL decrement, hop count, dedup cache, per-peer rate limiting (basic DoS hygiene).
- [ ] Relay policy enforcement (user relay settings from ARCHITECTURE §4).
- [ ] Store-and-forward: pending-packet store with expiry; forward on encounter.
- [ ] End-to-end ACK propagated back across hops.

**Exit criterion (demo):** three phones A–B–C where A and C are out of range of each other: A's message reaches C through B, and B (an "Unknown" relay) can be shown to have seen only encrypted bytes. Then: turn C off, send from A, walk B near C later → delivered.

---

## Checkpoint 7 — File transfer, broadcast, pub/sub (= PDF Phase 4)

- [ ] Chunked file transfer with resume (built on `file` packets + sequence numbers).
- [ ] `broadcast()` with TTL-bounded flooding.
- [ ] Topic-based publish/subscribe.

**Exit criterion (demo):** a photo transfers between two phones offline with a progress indicator and survives an interruption mid-transfer; a broadcast reaches all 3 test devices.

---

## Checkpoint 8 — Second transport: BLE + automatic transport selection (= PDF Phase 5)

- [ ] `mesh_transport_ble` (Android): GATT server/client, advertising, MTU negotiation — covers devices without Google Play services, and pre-builds the interop path for when iOS support returns.
- [ ] Transport abstraction runs multiple transports side by side and picks the best available link automatically (Nearby for bandwidth, BLE for reach).
- [ ] Spike `bluetooth_low_energy` plugin for peripheral mode; fallback = own platform channels.

**Exit criterion (demo):** with Nearby disabled on one device, the pair still exchanges messages over BLE; with both enabled, a large payload measurably picks the faster transport.

---

## Checkpoint 9 — SDK polish & release (= PDF Phase 6)

- [ ] Network topology debug view + mesh analytics in `mesh_console`.
- [ ] API docs, README quick-start, `SECURITY.md` threat model (honest about limits: traffic analysis, flooding DoS, tracking reduction).
- [ ] Example app extracted as a template; semantic versioning; publish `mesh_os` to pub.dev / open-source release.

**Exit criterion:** a developer who has never seen the codebase follows the README and sends an offline message between two devices in under 30 minutes.

---

## Deferred (post-1.0)

**iOS support** (BLE GATT interop via the CP8 transport; MultipeerConnectivity as an iOS-side option), background operation (foreground service on Android first, iOS later), smarter routing (distance vector → AODV → encounter-graph adaptive), CRDT sync, internet bridge nodes, desktop support, custom transport plugin API, developer dashboard.

---

## Hardware you'll need

| When | Hardware |
|---|---|
| CP0–CP2 | none (laptop only — everything is pure Dart) |
| CP3–CP5 | 2 Android phones (with Google Play services) |
| CP6+ | 3rd Android phone |
| when iOS returns | 1 iPhone |

## Standing risks

| Risk | Mitigation |
|---|---|
| `nearby_connections` plugin quality unknown | Time-boxed spike at the start of CP3; fallback = own platform channels over the native Nearby API |
| Nearby requires Google Play services | Acceptable for v1; BLE transport in CP8 covers de-Googled devices |
| Flutter BLE plugins can't do peripheral mode well | Risk moved to CP8; spike `bluetooth_low_energy` there, same fallback |
| Flooding is spammable | Rate limiting lands with routing in CP6, not later |
| Crypto misuse | Only `cryptography` package primitives, no hand-rolled crypto; round-trip + tamper tests in CP1 |

## How to proceed right now

1. **CP0 this week:** `git init`, restructure to the monorepo layout, add dependencies, CI.
2. Then CP1 + CP2 back-to-back — pure Dart, fast progress, no hardware needed.
3. Order 2 test Android phones (or gather old ones) **now** so they're on hand when CP3 starts.
4. Keep `mesh_console` ugly. It's an instrument panel, not a product. The product is the SDK.
