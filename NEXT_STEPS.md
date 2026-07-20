# MeshOS — Next Steps

Where things stand: **Checkpoints 0–9 are done in code** (see [ROADMAP.md](ROADMAP.md) for what each one covers). This file is the actual to-do list from here — what's genuinely outstanding, ordered by priority, plus what's deliberately *not* planned and why.

This is a private project (see README.md's "Release status") — nothing here assumes or leads toward a public release.

---

## Priority 1: Hardware verification

This is the real remaining work. Every checkpoint's protocol logic is proven against simulated transports (134 tests across `mesh_core`/`mesh_os`/`mesh_console`, zero hardware), but **none of it has run on an actual phone**. `FakeTransport` proves the logic is correct; it can't prove `NearbyTransport`/`BleTransport` actually talk to real radios correctly, or that the on-device UX holds up. Until this happens, treat every checkpoint as "should work" rather than "works."

Needed: 2 Android phones with Google Play services minimum, a 3rd for anything multi-hop (CP6+), Bluetooth on both for CP8.

Work through these in order — each depends on the identity/session/trust plumbing the previous ones exercise:

- [ ] **CP3–CP5**: install on two phones, confirm auto-discovery/connect/handshake, send messages both directions, do the QR trust exchange, block/unblock, force-quit and confirm identity + chat history + trust survive restart. (README.md "Try it," steps under "CP3–CP5 demo.")
- [ ] **CP6**: bring in a 3rd phone, confirm multi-hop delivery through a relay that never sees plaintext, and store-and-forward when the destination is temporarily offline.
- [ ] **CP7**: confirm a broadcast reaches phones with no prior contact; send a real photo with file transfer, and specifically force an interruption (walk out of range mid-transfer) to confirm it pauses and resumes instead of corrupting or restarting.
- [ ] **CP8**: disable Nearby specifically on one phone (not just airplane mode — needs to isolate "no Nearby" from "no radio at all") and confirm `MultiTransport` actually falls back to BLE, not that Nearby was secretly still working. Time a large transfer both ways to confirm Nearby is actually faster when both are available.
- [ ] **CP9**: watch the debug view's counters move live during ordinary use; hand the README to someone who hasn't touched this codebase and see if they get two phones talking in under 30 minutes without help.

If any of these fail, that's expected to surface real bugs — the simulated tests can't catch radio-specific issues (real MTU negotiation, real advertising payload limits, real Android permission dialogs, timing under actual Bluetooth/Wi-Fi latency). Fix what breaks, add regression tests where the fix is expressible in `FakeTransport` terms, and note in ROADMAP.md what was hardware-specific.

**No second device yet?** The **Mesh Simulator** screen in `mesh_console` (beaker icon in the app bar, `apps/mesh_console/lib/mesh_simulator_screen.dart`) runs a real 3-node mesh in-process on one device/emulator, using the actual `MeshLink`/`FileTransferManager` code over an in-memory fake radio -- see README.md's "Try it." It's real evidence the protocol stack works correctly compiled into a running app, and it's the thing to reach for first if something seems broken (it'll tell you whether the bug is in the protocol logic or specifically in the transport/radio layer). It is **not a substitute for the checklist above** — it structurally cannot exercise `NearbyTransport`/`BleTransport` themselves, since that requires two real radios in range of each other.

## Priority 2: Known limitations worth revisiting after hardware testing

These are documented (ARCHITECTURE.md, SECURITY.md) as accepted v1 trade-offs, not bugs — but hardware testing may reveal some matter more than expected:

- [ ] **BLE legacy advertising byte budget** (ARCHITECTURE.md §11): a full 128-bit service UUID plus the advertised name may not fit in a 31-byte legacy advertising packet on older chipsets. Unverified without hardware — if CP8 testing shows truncation, the fix is likely dropping to a shorter service-scoping scheme or leaning on extended advertising exclusively.
- [ ] **Relay store and file-transfer state are in-memory only** (ARCHITECTURE.md §7): an app restart mid-relay or mid-transfer loses that state. Low priority unless real usage shows this actually happens often enough to matter.
- [ ] **`MultiTransport.maxPayloadSize`** is the minimum across transports (correctness over efficiency) — fine unless real throughput testing shows this meaningfully hurts Nearby's performance in practice.

## Priority 3: Post-1.0 features (not started, no scoping done yet)

From ROADMAP.md's "Deferred" list — these are real future directions, not committed to a specific checkpoint order. Sequencing them is itself a future decision.

- [ ] **iOS support** — BLE GATT interop via the existing `mesh_transport_ble` design (the `Transport` interface was kept clean for this), or `MultipeerConnectivity` as an iOS-native alternative. Biggest single undertaking on this list; effectively re-runs CP3/CP8's transport work for a second platform.
- [ ] **Background operation** — foreground service on Android first (v1 is foreground-only by explicit scope decision), iOS background modes later. Needed for MeshOS to be useful as "always-on" infrastructure rather than only while the app is open.
- [ ] **Smarter routing** — the staged path from ARCHITECTURE.md §7's table: flooding (done, v1) → breadth-first/probabilistic gossip → distance vector → AODV → adaptive routing on historical encounter graphs. Each step trades implementation complexity for less wasted relay bandwidth. Worth revisiting once real mesh sizes/densities are known from actual usage — premature to build v2 routing against guessed traffic patterns.
- [ ] **CRDT sync** — conflict-free replicated data types for offline-first shared state (beyond simple message passing) — e.g. shared documents, collaborative lists. A genuinely new subsystem, not an extension of existing messaging.
- [ ] **Internet bridge nodes** — a node with real internet connectivity relaying mesh traffic to/from the wider internet. Raises new trust/security questions (a bridge node sees traffic patterns no purely offline relay would) that need real design work, not just implementation.
- [ ] **Desktop support** — would need its own transport work (different Bluetooth/Wi-Fi APIs per desktop OS) and UI adaptation; no groundwork laid yet.
- [ ] **Custom transport plugin API** — right now, adding a transport means implementing `Transport` and wiring it into `MultiTransport` by hand inside `mesh_os`. A real plugin API would mean a stable, documented, externally-implementable interface with its own versioning guarantees — worth doing once there's a second real consumer of `Transport` beyond Nearby/BLE to design against.
- [ ] **Developer dashboard** — a proper topology/analytics tool beyond `mesh_console`'s intentionally-plain debug screen (CP9). Only worth building once there's an actual need driving specific requirements (what would you want to see, that the debug view doesn't show?).

## Explicitly not planned

- **Publishing to pub.dev.** Decided against — this stays a private project, consumed via path dependency within this workspace (or `git:` if it's ever split across repos). Pub.dev's entire value is letting people *outside* this repo add the package with one line instead of pointing at source directly; with no intended external consumer, it adds nothing. See README.md's "Release status."
- **Open-source release / public repo.** Same reasoning — not applicable to a private project.
- **LICENSE file.** Only matters once (if ever) code leaves this repo's control — e.g. if you later share it with a collaborator, contractor, or another project outside your own ownership. Not needed for solo private use. Worth a five-minute decision *if* that situation ever comes up, not before.
