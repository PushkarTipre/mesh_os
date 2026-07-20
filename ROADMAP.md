# MeshOS — Roadmap & Checkpoints

How we get from an empty Flutter template to the MeshOS SDK. Each checkpoint has a **goal**, **tasks**, and an **exit criterion (demo)** — a checkpoint is done only when its demo works. Do not start a checkpoint until the previous one's demo passes.

Ordering rationale: everything that is pure Dart (identity, crypto, packets, routing logic) is built and unit-tested **before** touching Bluetooth, because transport work needs physical devices and is the highest-risk area. By the time we open the BLE box, everything above it already works.

---

## Checkpoint 0 — Project scaffolding ✅ done (2026-07-10)

**Goal:** repo shaped like an SDK, not an app.

- [x] Restructure to a monorepo: `packages/mesh_core`, `packages/mesh_os`, `apps/mesh_console` (moved from `lib/main.dart`). Uses Dart's native pub workspaces (`resolution: workspace`, Dart 3.6+) rather than melos — one `pub get` at the root resolves all three packages, no extra tool dependency.
- [x] `mesh_core` is pure Dart (only depends on `cryptography`; no `flutter` import anywhere).
- [x] Added dependencies: `cryptography` (mesh_core), `flutter_secure_storage` (mesh_os), lints/flutter_lints. `drift`/`sqflite` deferred to CP5 (local storage isn't needed until trust/contacts persistence).
- [x] CI (GitHub Actions, `.github/workflows/ci.yml`): `flutter pub get` + `flutter analyze` + `dart test` on `mesh_core`, on every push/PR.
- [x] `git init` + first commit of the original Flutter template, then the restructure as a second commit.

**Exit criterion:** ✅ `flutter pub get && flutter analyze` is clean workspace-wide; `dart test` in `packages/mesh_core` is green. (`mesh_console` builds on a physical/emulated device — not yet run on real hardware, do this before relying on it.)

---

## Checkpoint 1 — Identity & crypto core (pure Dart) ✅ done (2026-07-10)

**Goal:** a node can be born.

- [x] `NodeIdentity`: generate Ed25519 signing pair + X25519 agreement pair; derive Node ID = SHA-256(pubkey)[0..16] hex. (`packages/mesh_core/lib/src/identity/node_identity.dart`)
- [x] Persist/load identity via a storage interface: `IdentityStore` + `InMemoryIdentityStore` in `mesh_core`; `SecureStorageIdentityStore` (flutter_secure_storage-backed) in `mesh_os`.
- [x] Sign/verify bytes (Ed25519); ECDH (X25519) → HKDF-SHA256 → ChaCha20-Poly1305 encrypt/decrypt round-trip between two in-memory identities, serializable via `EncryptedEnvelope`.
- [x] Temporary-ID rotation: `TemporaryId.derive` — SHA-256(signing public key ‖ 10-minute time slot), truncated to 8 bytes. Documented assumption: this only protects against passive tracking if the permanent public key is *not* broadcast in open discovery beacons — enforced at the discovery/transport layer, not here (flagged for CP3/CP5).

**Exit criterion:** ✅ 20/20 unit tests green in `packages/mesh_core/test/identity/` — node ID generation/uniqueness, sign/verify (including tamper and wrong-key rejection), encrypt/decrypt round-trip (including tamper and wrong-recipient rejection), temp ID rotation, and identity persistence across a simulated restart (`loadOrCreate` called twice against the same store returns the same key material). `mesh_console` now generates/loads a `NodeIdentity` via `SecureStorageIdentityStore` on launch and displays the Node ID — restart-persistence still needs to be confirmed on a real device (see "Next up").

---

## Checkpoint 2 — Packet layer (pure Dart) ✅ done (2026-07-10)

**Goal:** the wire format exists and is bulletproof.

- [x] Binary codec for the packet header (version, type, id, timestamp, temp src/dst, TTL, hops, priority) + payload + signature + checksum. (`packages/mesh_core/lib/src/packet/mesh_packet.dart`) 105-byte fixed header, payload is everything after it (no length prefix needed or possible to get wrong).
- [x] All 7 packet types (`discovery`, `data`, `broadcast`, `ack`, `sync`, `file`, `heartbeat`). (`packet_type.dart`)
- [x] Duplicate-detection cache (packet-ID LRU with expiry). (`packet_dedup_cache.dart`) — expiry-based eviction is O(k) in evicted entries, not a full scan, since insertion order tracks chronological order.
- [x] Fragmentation/reassembly layer (MTU-parameterized). (`fragment.dart`, `fragmenter.dart`, `reassembler.dart`) Tolerates out-of-order and duplicate fragment delivery; abandons incomplete messages after inactivity. Exercised against synthetic MTU sizes here — plugged into a real transport's negotiated MTU in CP3.
- [x] Fuzz/property tests: encode→decode round-trips; corrupt bytes never crash the decoder, they return errors.

**Design decision worth flagging:** the Ed25519 signature covers only the fields the *origin sender* sets (version, type, packetId, timestamp, tempSourceId, tempDestId, priority, payload) and deliberately excludes `ttl`/`hopCount`. Relays don't hold the sender's private key, so they can decrement TTL and increment hop count in place without invalidating the signature — `MeshPacket.forwarded()` does this and the signature still verifies after any number of hops (tested explicitly). The CRC-32 `checksum` is a separate, unsigned, per-hop transmission-integrity check that gets recomputed fresh by every relay in `toBytes()`.

**Exit criterion:** ✅ `dart test` green — 54/54 tests in `packages/mesh_core`, including: round-trip for all 7 packet types plus empty/large payloads; TTL/hop-count mutation via `forwarded()` with signature surviving relay; signature correctly rejecting a wrong signer or a tampered payload; the dedup cache's expiry and capacity eviction; fragmentation/reassembly with out-of-order and duplicate delivery and incomplete-message eviction; and a fuzz suite that truncates a valid packet at every possible length, applies random single- and multi-byte corruption (500 trials each), and feeds 1000 random-length random-content buffers — asserting the decoder only ever throws `PacketDecodeException`, never a raw crash.

---

## Checkpoint 3 — Nearby Connections transport, single hop ⚠️ code done, on-device demo still needed

**Goal:** two physical phones exchange raw MeshOS packets with the screen on.

Android-only scope means transport v1 is **Google Nearby Connections**, not BLE (see ARCHITECTURE §11) — it handles discovery/connection for us and upgrades to Wi-Fi for bandwidth, cutting the riskiest part of the original plan.

- [x] `Transport` interface in `mesh_core` (advertise, discover, connect, send bytes, byte stream in). (`packages/mesh_core/lib/src/transport/transport.dart`) Transport-agnostic so BLE can slot in later (CP8).
- [x] `mesh_transport_nearby`: wraps the `nearby_connections` plugin (P2P_CLUSTER strategy). (`packages/mesh_transport_nearby/`) Its real API was read directly from the installed package source (not from memory) before writing the adapter, to avoid guessing wrong on callback shapes.
- [x] Fragmentation from CP2 wired in for packets above `Transport.maxPayloadSize` — every send is prefixed with a 1-byte envelope marker (whole-packet vs. fragment); tested end-to-end through `MeshLink` with an artificially tiny MTU.
- [x] Android runtime-permission flow (`BLUETOOTH_SCAN/ADVERTISE/CONNECT`, `NEARBY_WIFI_DEVICES`, location) via `NearbyPermissions` + manifest entries in `mesh_console`.
- [x] `mesh_console` debug screen: nearby devices list, connect/accept/disconnect, per-peer send-test-packet button, scrolling packet log.

**Design choice worth flagging:** encrypting a packet requires the recipient's public key, which CP3 doesn't have a trust store for yet (that's CP5). So the transport-agnostic `MeshLink` (`packages/mesh_core/lib/src/session/mesh_link.dart`) implements a minimal, ephemeral, **self-certifying** handshake: on connect, both sides send a signed `discovery` packet whose payload *is* their public keys — a signature that verifies against its own embedded key is proof of private-key possession, no prior exchange needed. This is explicitly **not** the real discovery/trust protocol (ARCHITECTURE.md §7-9, landing in CP5); it's the minimum needed to prove the crypto stack works over a real transport. `MeshLink` only touches the abstract `Transport` interface, so it's fully unit-tested (handshake, verify, encrypt/decrypt, fragmentation, tamper-drop, disconnect/reconnect) against a `FakeTransport` test double with zero hardware — 60/60 tests green in `packages/mesh_core`. `NearbyTransport` itself is a thin, deliberately dumb platform-channel wrapper with no protocol logic of its own, which confines the untestable-without-hardware surface to as little code as possible.

**Exit criterion (demo):** two Android phones with no internet (Wi-Fi with no uplink or airplane mode + BT/Wi-Fi radios on) discover each other and exchange signed, encrypted packets; packet log shows verify+decrypt success. **This demo is the project's biggest de-risking moment — and it's the one part of this checkpoint that hasn't been run yet.** Nearby Connections has no emulator support, so this needs two real Android phones. See README.md for how to run it.

---

## Checkpoint 4 — Direct encrypted messaging (= PDF Phase 1 complete) ✅ code done, on-device demo still needed

**Goal:** the public API works end-to-end for one hop.

- [x] `MeshOS` facade: `initialize()`, `start()`, `send()`, `messages`, `devices`, `deviceUpdates`. (`packages/mesh_os/lib/src/mesh_os.dart`) Wraps CP3's `MeshLink` + `NearbyTransport` rather than reimplementing them; auto-connects to every discovered peer and auto-accepts incoming requests (trust-gating that is CP5).
- [x] Formalized (rather than replaced) CP3's handshake as the real v1 discovery mechanism, and documented the resulting privacy boundary explicitly in ARCHITECTURE.md §3/§5: passive scanning only ever reveals the rotating temp ID; the permanent public key is revealed only in the post-connection handshake, to peers you actually connect to.
- [x] ACK + retry + delivery status for direct messages (`MeshLink.sendData` now returns `Future<DeliveryStatus>`), plus duplicate-delivery suppression via `PacketDedupCache` for the case where a retry's *ack* was what got lost, not the original data. All of this — retry-then-deliver, retry-exhaustion failure, immediate failure on disconnect, and the lost-ack/no-duplicate-surfaced case — is unit tested against `FakeTransport` with zero hardware.
- [x] Minimal chat UI in `mesh_console`: device list → tap a handshaked peer → per-peer chat screen, with message history persisted (keyed by the peer's permanent Node ID, not the ephemeral transport remoteId — see `PeerSession.nodeId`'s doc comment for why that distinction matters) and per-message delivery status (sending/delivered/failed).

**Exit criterion (demo):** two phones, airplane mode, chat both directions; kill and reopen the app — identity and message history survive. **Not yet run on real hardware** — same situation as CP3: everything up to the transport boundary is proven in `packages/mesh_core`'s test suite (66 tests), but the actual two-phone demo needs real devices. See README.md.

---

## Checkpoint 5 — Trust, contacts & persistence (= PDF Phase 2) ✅ code done, on-device demo still needed

**Goal:** the trust model is real.

- [x] SQLite schema via `drift`: contacts (node id, public keys, trust level, display name, first-seen) in `packages/mesh_os/lib/src/storage/`. Pending packets/routing cache/preferences aren't needed yet -- they join this database in later checkpoints rather than starting a new one.
- [x] Trust levels (trusted/known/unknown/blocked) enforced in `MeshLink`: a first-ever handshake auto-creates a `known` contact; a `blocked` contact is refused a session (or dropped from one, at both send and receive) at every checkpoint in the packet pipeline. See ARCHITECTURE.md §4 for the one clarified departure from the original table (known/unknown both message freely -- that's what CP4's exit criterion already required).
- [x] QR-code identity exchange (show + scan): `IdentityCard` (`mesh_core`) is a self-certifying signed bundle of public keys + display name; `mesh_console` renders/scans it via `qr_flutter`/`mobile_scanner`. `MeshOS.trustFromIdentityCard()` verifies and trusts in one step.
- [x] Display name shared to trusted contacts only -- never included in the ordinary discovery handshake (only in the explicit `IdentityCard` exchange), so it's structurally impossible for an untrusted peer to learn it.
- [x] `trust(nodeId)` / `block(nodeId)` / `unblock(nodeId)` API on `MeshOS`, with `block()` proactively disconnecting the peer if currently connected rather than waiting for their next packet.

**Design note:** the ordinary discovery handshake was deliberately *not* changed to reference the trust store for anything beyond blocking -- known and unknown nodes still complete the same self-certifying handshake from CP3/CP4 and can message immediately. This matches the roadmap as originally scoped here, not the PDF's literal (and, on inspection, self-contradictory-with-CP4) trust table; see ARCHITECTURE.md §4 for the reasoning.

**Exit criterion (demo):** two strangers see each other with no name (just their Node ID). QR exchange → names appear on both sides. Block → the blocked device is disconnected within moments and can't reconnect. **Not yet run on real hardware** — same situation as CP3/CP4: the trust/crypto logic is proven in `packages/mesh_core`'s test suite (82 tests) and the SQLite layer against real (in-memory) SQLite in `packages/mesh_os` (7 tests), but actually scanning a QR code between two phones needs real cameras. See README.md.

---

## Checkpoint 6 — Multi-hop routing + store-and-forward (= PDF Phase 3) ✅ code done, on-device demo still needed

**Goal:** messages travel through strangers. This is the moment it becomes a *mesh*.

- [x] Flooding router: TTL decrement, hop count, dedup cache, per-peer rate limiting (basic DoS hygiene). (`MeshLink._relayPacket`/`_floodOrStore`, `packages/mesh_core/lib/src/session/mesh_link.dart`)
- [x] Relay policy enforcement (user relay settings from ARCHITECTURE §4) — `RelayPolicy`: `everything` / `trustedContactsOnly` / `disabled`. Battery/charging/Wi-Fi-gated policy from the original design is deferred (not core routing logic).
- [x] Store-and-forward: pending-packet store with expiry; forward on encounter, plus a periodic sweep so a packet can still expire (and its `sendToNode` caller still gets `failed`) even for a node with zero further connectivity. In-memory only for now — doesn't survive an app restart; see ARCHITECTURE.md §7's noted limitation.
- [x] End-to-end ACK propagated back across hops (`MeshLink.sendToNode`) — resolves whenever the destination's ack eventually arrives, however many hops away that turns out to be, or fails once the packet expires unacked.

**The one genuinely hard design problem this checkpoint had to solve:** rotating temp IDs (10-minute rotation, built for anti-tracking) are incompatible with store-and-forward across meaningful time gaps — an address computed at send time can't match a destination's temp ID hours later. Solved with a third, *stable* identifier (`NodeIdentity.routingAddress`) used only for multi-hop packet addressing, documented in ARCHITECTURE.md §3 as a deliberate, narrower privacy trade-off scoped to routed traffic specifically.

**A real bug the test suite caught before this ever reached a device:** the first implementation distinguished "direct message" from "routed packet passing through me" by whether the packet's signature verified against the immediate sender's own session key. That's wrong for the *first hop* specifically — a packet A routes toward C via B is still genuinely signed by A, and A is B's real direct peer, so it always passed that check, causing B to try to decrypt a message meant for C and silently drop it instead of relaying. Fixed by branching on `tempDestId` (the `broadcastDestination` sentinel means direct; anything else means routed) instead of on whether the signature happens to verify. Caught immediately by the multi-hop test suite (`packages/mesh_core/test/routing/multi_hop_test.dart`) rather than during on-device testing.

**Exit criterion (demo):** three phones A–B–C where A and C are out of range of each other: A's message reaches C through B, and B (an "Unknown" relay) can be shown to have seen only encrypted bytes. Then: turn C off, send from A, walk B near C later → delivered. **Not yet run on real hardware** — the entire scenario above, plus store-and-forward, end-to-end ack, blocked-sender-dropped, relay policy, and rate limiting, is proven in `packages/mesh_core`'s test suite (92 tests) against a simulated 3-node network, but this is the first checkpoint whose exit criterion needs *three* physical phones, not two. See README.md.

---

## Checkpoint 7 — File transfer, broadcast, pub/sub (= PDF Phase 4) ✅ code done, on-device demo still needed

**Goal:** get bytes to everyone, or a whole file to one person, without either needing a prior encryption relationship for the former or reinventing reliability for the latter.

- [x] `broadcast()` with TTL-bounded flooding: self-certifying (embedded pubkey + signature, no destination to encrypt for), reuses the existing relay/dedup machinery (`MeshLink._handleBroadcast`, `packages/mesh_core/lib/src/session/mesh_link.dart`).
- [x] Topic-based publish/subscribe (`publish`/`subscribe`/`unsubscribe`): a `publish` is a `broadcast` with a topic tag; every relay-capable node still forwards every topic regardless of its own subscriptions (local filtering only, not topic-aware routing) — see ARCHITECTURE.md §7.
- [x] Chunked file transfer with resume (`FileTransferManager`, `packages/mesh_core/lib/src/files/file_transfer.dart`) — built entirely on `sendToNode`/`sendData` (a new `PacketType.file` tag, threaded through both) rather than a parallel reliability mechanism, so it inherits direct/routed addressing, retry, and acking for free. A stalled chunk (15s bound per attempt) pauses the transfer; it resumes automatically, from the last acked chunk, the next time `MeshLink.sessionEstablished` fires for the same destination.
- [x] `MeshOS` facade: `broadcast`/`publish`/`subscribe`/`unsubscribe`/`sendFile`/`outgoingFileProgress`/`incomingFiles`; `messages` now filters out file chunks (`InboundMessage.isFileChunk`).
- [x] `mesh_console` demo UI: a Broadcast screen (send/receive plain broadcasts — topic pub/sub is implemented and tested at the SDK level but not surfaced in this demo UI, to keep it thin); an attach-photo button in chat (via `image_picker`) with a progress indicator per outgoing transfer and inline image rendering for received files.

**Known limitation, documented honestly:** file-transfer state (in-flight chunks, resume point) is in-memory only, like the CP6 relay store — an app restart mid-transfer loses it. `mesh_console` also keeps file messages session-only (not written to `ChatHistoryStore`, unlike text).

**Test coverage (no hardware needed):** 13 new tests in `packages/mesh_core` (105 total) — 8 broadcast/pub-sub tests (3-node relay reach with no prior contact required, topic filtering, a non-subscriber still relaying for a subscriber further along, a forged-signature broadcast dropped and not relayed) in `test/routing/broadcast_test.dart`; 5 file-transfer tests (byte-exact small/multi-chunk/zero-byte transfers, ordinary chat messages never leaking into `incomingFiles`, and — the interesting one — a transfer that loses its ack, gets disconnected before the retry timer fires, pauses, then resumes and completes byte-exact after reconnecting, with no duplication despite the resend) in `test/files/file_transfer_test.dart`.

**Exit criterion (demo):** a photo transfers between two phones offline with a progress indicator and survives an interruption mid-transfer; a broadcast reaches all 3 test devices. **Not yet run on real hardware** — the scenario above (including the ack-loss/pause/resume path) is proven in `packages/mesh_core`'s simulated-network test suite, but this checkpoint's actual exit demo needs physical phones with a real camera roll and a real walk-out-of-range interruption. See README.md.

---

## Checkpoint 8 — Second transport: BLE + automatic transport selection (= PDF Phase 5) ✅ code done, on-device demo still needed

**Goal:** reach the devices Nearby Connections can't (no Google Play services), and stop needing two separate demo builds for two separate radios.

- [x] `mesh_transport_ble` (Android): GATT server/client, advertising, MTU negotiation. (`packages/mesh_transport_ble/lib/src/ble_transport.dart`) Built on the `bluetooth_low_energy` plugin, which supports both central and peripheral roles -- every MeshOS node runs both at once, same "every node is an equal peer" principle as `NearbyTransport`. The "spike the plugin, fall back to custom platform channels" from the original plan didn't need its fallback.
- [x] Transport abstraction (`MultiTransport`, `packages/mesh_core/lib/src/transport/multi_transport.dart`) runs multiple transports side by side and picks the best available link automatically: correlates a peer discovered on more than one transport into a single logical device (via the already-advertised rotating `TemporaryId`, no new protocol needed), and `connect` commits to the first transport (by preference order) with a discovered path -- Nearby first for bandwidth, BLE second for reach. `MeshOS.start()` now constructs `MultiTransport([NearbyTransport(), BleTransport()])`.
- [x] `mesh_console` needs no changes at all for this -- it was already built against the `MeshOS` facade, not `mesh_transport_nearby` directly (a CP3-only shortcut removed back in CP4), so the transport swap underneath it is entirely invisible.

**Known limitations, documented honestly:** `Transport.maxPayloadSize` is connection-agnostic, so `MultiTransport` reports the minimum across every underlying transport (correct, not maximally efficient -- see ARCHITECTURE.md §7). No dynamic mid-session transport upgrade (once `connect` picks one, that's the link for the session). `BleTransport.maxPayloadSize` is fixed at BLE's un-negotiated default MTU floor (20 bytes) rather than the real negotiated value, for the same single-property-interface reason. Legacy BLE advertising's 31-byte cap interacting with a full 128-bit custom service UUID is a real, unverified-without-hardware risk (ARCHITECTURE.md §11).

**Test coverage (no hardware needed):** 11 new tests in `packages/mesh_core` (116 total) in `test/transport/multi_transport_test.dart` -- discovery merging across two simulated "radios" into one device, transport preference order, fallback when the preferred transport has no path, a full connect+send+receive round trip, an inbound connection with no prior discovery still getting a working (fallback) synthetic id, disconnect targeting the right underlying transport, and one transport throwing on every call not blocking the other. `FakeTransport`/`FakeTransportNetwork` gained a settable `name` (to distinguish simulated transports) and a `lost` device event on `stopAdvertising` (previously unsupported) as part of this.

**Exit criterion (demo):** with Nearby disabled on one device, the pair still exchanges messages over BLE; with both enabled, a large payload measurably picks the faster transport. **Not yet run on real hardware** -- `MultiTransport`'s selection/merging logic is fully proven against simulated transports, but `BleTransport` itself (GATT server/client, advertising, MTU negotiation, legacy-advertising byte budget) has zero real-radio verification, same category of gap as `NearbyTransport` was through CP3-CP5. See README.md.

---

## Checkpoint 9 — SDK polish & release (= PDF Phase 6) ✅ done -- staying a private project by decision

**Goal:** make the SDK legible and usable by someone who isn't the person who wrote it -- and be honest about which parts of "release" are actually this checkpoint's to do.

- [x] Network topology debug view + mesh analytics in `mesh_console`. (`MeshDebugScreen`, hub icon in the app bar) Deliberately plain -- lists and live-updating numbers, not a graph renderer, per this file's own "keep `mesh_console` ugly" guidance below. Backed by a new `MeshLinkStats` (`packages/mesh_core/lib/src/session/mesh_link.dart`): packets/bytes sent/received/relayed, active sessions, store-and-forward queue depth, updated at the same choke points every packet already passes through. Exposed on the facade as `MeshOS.stats`/`statsUpdates`.
- [x] API docs: `dart doc` runs clean (0 warnings, 0 errors) across `mesh_core` and `mesh_os` -- fixed 6 broken `[symbol]` cross-references found by actually running it, not just assumed correct.
- [x] README quick-start: a new top-of-file section gets a from-scratch reader to a working two-phone message exchange, matching this checkpoint's exit criterion, distinct from the existing per-checkpoint "Try it" walkthroughs.
- [x] `SECURITY.md` threat model: what's protected, what explicitly isn't (traffic analysis, flooding DoS beyond rate limiting, temp-ID rotation limits, no forward secrecy, no relay accountability), and which threat actors MeshOS is/isn't designed to resist -- consolidates and expands on notes that were previously scattered across ARCHITECTURE.md's per-checkpoint sections.
- [x] `mesh_console` documented as a starting template (README section: what to copy, what to delete) -- true today because it was already built against the public `MeshOS` facade only, nothing SDK-internal to strip out.
- [x] Semantic versioning: every package already used it correctly (`0.1.0`, pre-1.0 = expect breaking changes); added `CHANGELOG.md` to each publishable package to make that practice concrete going forward.
- [x] **Decided: this stays a private project.** No pub.dev publish, no public repo, no LICENSE needed for that purpose. Pub.dev exists to let people outside this repo add the package with one line instead of pointing at the source directly -- with no intended external consumer, it has nothing to offer here; a path (or, if this ever splits across repos, `git:`) dependency does everything pub.dev would, without publishing anything. See [NEXT_STEPS.md](NEXT_STEPS.md) and README.md's "Release status."

**Test coverage (no hardware needed):** 5 new tests in `packages/mesh_core` (121 total) in `test/session/mesh_link_stats_test.dart` -- session count tracking, packet/byte counters incrementing on send and receive, live `statsUpdates` stream, `packetsRelayed` incrementing only on the middle node of a 3-hop relay (never the endpoints), and `storedRelayPackets` reflecting the store-and-forward queue depth as a packet waits and then gets delivered.

**Exit criterion:** a developer who has never seen the codebase follows the README and sends an offline message between two devices in under 30 minutes. **Not yet verified against an actual outside developer** -- the Quick Start section is written to satisfy it, but by definition this needs someone who hasn't already been working in this codebase to try it and report back.

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
