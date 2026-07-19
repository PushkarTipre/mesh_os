# MeshOS

**Decentralized offline networking runtime for Flutter.**

MeshOS turns every phone into an equal network node: devices discover each other nearby, exchange end-to-end-encrypted packets, relay for strangers without reading their traffic, and store-and-forward messages until they can be delivered — all with no internet, no servers, and no accounts.

MeshOS is not a chat app. It is a reusable SDK any Flutter application can build on:

```dart
final mesh = MeshOS();
await mesh.initialize();
await mesh.start();

await mesh.send(destination: nodeId, payload: bytes);
mesh.messages.listen((msg) => ...);
```

## Status

🚧 Early development — **Checkpoints 0–8 done in code** (project scaffolding; identity & crypto core; packet layer; Nearby Connections transport; the public `MeshOS` facade with reliable single-hop messaging; trust/contacts/QR exchange with SQLite persistence; multi-hop routing with flooding, store-and-forward, and end-to-end ack; broadcast + topic pub/sub + resumable file transfer; a second transport (BLE) with automatic selection between it and Nearby). None of CP3–CP8's on-device demos — real phones actually discovering, chatting, exchanging QR codes, relaying for each other, broadcasting, transferring files, and falling back to BLE — have been run yet; see "Try it" below. **Android-only for v1**; iOS is deferred (see the platform reality check in ARCHITECTURE.md §11). See [ROADMAP.md](ROADMAP.md) for the checkpoint plan and what "done" means at each stage.

## Repo layout

```
packages/mesh_core/            pure-Dart SDK core: identity, crypto, packets, transport-agnostic session handshake, trust primitives, MultiTransport
packages/mesh_os/              public SDK: the MeshOS facade -- mesh_core + transports + platform storage (secure storage, SQLite via drift)
packages/mesh_transport_nearby/ Transport implementation over Google Nearby Connections (Android)
packages/mesh_transport_ble/   Transport implementation over Bluetooth Low Energy (Android) -- reaches devices without Google Play services
apps/mesh_console/             dev/demo Flutter app (not a product) -- uses the MeshOS facade, not the pieces directly
```

Root `pubspec.yaml` is a Dart pub workspace — `flutter pub get` once at the repo root resolves all five packages.

## Try it

Everything that runs without hardware:

```
flutter pub get                          # from repo root
(cd packages/mesh_core && dart test)     # 116 unit tests: identity/crypto/packets/session/delivery/trust/routing/broadcast/pub-sub/file-transfer/multi-transport (CP1-CP8)
(cd packages/mesh_os && flutter test)    # 7 unit tests: DriftTrustStore against real in-memory SQLite
flutter analyze                          # whole workspace
(cd packages/mesh_core && dart run example/identity_demo.dart)  # see the crypto core in action
```

The CP3–CP5 demo, two Android phones (Nearby Connections has no emulator support and QR scanning needs real cameras):

1. `flutter run` from `apps/mesh_console` on both phones.
2. Grant the Nearby/Bluetooth/location/camera permission prompts on each.
3. Each phone shows its Node ID and starts advertising + discovering + auto-connecting automatically -- no manual pairing.
4. Within a few seconds each phone lists the other, first as "Connecting...", then "Handshaking...", then "Ready to chat · known" — note: no name yet, just the Node ID.
5. Tap the peer on either phone to open a chat screen; send a message. It should appear on the other phone almost immediately, and the sender's copy should flip from "sending" to "delivered".
6. On phone A, tap the QR icon in the app bar, type a display name, and show the generated code. On phone B, tap the scan icon and scan it. B should get a "Trusted <name>" confirmation, and B's device-list entry for A should now show that name instead of A's Node ID. Repeat in the other direction so both sides are trusted.
7. Long-press (via the trailing menu) either device and choose **Block**. The connection should drop within moments, and the two phones should not reconnect while the block is in place. **Unblock** should let them find each other again.
8. Force-quit and reopen the app on either phone — the Node ID, the chat history, and the trusted contact's name should all still be there.

The CP6 demo, which needs a **third** phone (this is the first checkpoint where two isn't enough):

1. On phones A and C, do the QR trust exchange from step 6 above (directly, while they're still in range of each other) — multi-hop send requires the destination to already be a known contact, since reaching them means encrypting for their public key.
2. Walk A and C out of range of each other, but bring phone B within range of both (A↔B and B↔C, not A↔C).
3. On A, phone C should now appear under a new **"Other known contacts"** section (not "Nearby devices" — A and C aren't in direct range). Tap it to open the same chat screen as before.
4. Send a message from A. It should still arrive on C, routed through B, and A's copy should still flip to "delivered" once C's ack makes it back — same as the direct case, just slower and via a third phone neither UI surfaces explicitly (that's the point: `MeshOS.send()` doesn't ask which path to use).
5. Turn phone C off entirely. Send another message from A to C. It should sit as "sending" -- B is holding it in its own store-and-forward cache. Turn C back on within range of B (A can stay out of range the whole time) -- the message should arrive on C, and A's copy should flip to "delivered" once C's ack finds its way back.

The CP7 demo, back to two phones (broadcast) plus the same third-phone setup above if you want to confirm a broadcast crosses a relay too:

1. On both phones, tap the megaphone icon in the app bar to open the Broadcast screen. Type a message on phone A and send it -- it should appear on phone B's Broadcast screen within moments, with A's Node ID as sender, even if A and B have never exchanged QR codes or chatted before (broadcast needs no prior contact).
2. Open a chat with a trusted/known peer and tap the paperclip icon -- pick a photo from the gallery. It should appear as an outgoing bubble on the sender's screen with a live progress bar, and arrive on the peer's screen as an inline image once complete.
3. Mid-transfer (pick a larger photo, or a slower/farther connection, to give yourself a window), walk the two phones out of range of each other. The sender's bubble should show "paused" partway through. Walk back into range -- the transfer should resume from where it left off (not restart) and finish, with the full image arriving correctly on the receiving phone.

The CP8 demo, two phones, needs Android's Bluetooth (and, on one phone, a way to disable Nearby specifically -- e.g. toggling Wi-Fi off, since Nearby needs it for its bandwidth upgrade, while BLE doesn't):

1. With both phones fully enabled (Bluetooth + Wi-Fi), `flutter run` on both -- everything should behave exactly like the CP3-CP7 demos above; you shouldn't be able to tell Nearby and BLE apart from the UI, which is the point.
2. On one phone, disable whatever it takes to make Nearby Connections fail on this device (airplane mode + Bluetooth-only re-enable is one way; Nearby needs more than Bluetooth to fully function, BLE doesn't). The two phones should still find each other and chat -- confirming `MultiTransport` actually fell back to `BleTransport`, not just that Nearby was still secretly working.
3. With both phones fully enabled again, send a large file (a big photo, or several) between them and casually time it, then repeat after forcing BLE-only on one side as in step 2. The BLE-only transfer should be noticeably slower -- confirming `MultiTransport` really does prefer the higher-bandwidth transport when both are available, not picking arbitrarily.

`apps/mesh_console` no longer touches `mesh_transport_nearby` directly (that was a CP3-only shortcut) -- it only calls `MeshOS`, same as any other app built on the SDK would. Checkpoint 8's transport swap (`MultiTransport([NearbyTransport(), BleTransport()])` instead of `NearbyTransport()` alone) happens entirely inside `MeshOS.start()` -- `mesh_console` needed zero changes for it.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — system design: identity, trust model, packet format, routing, security model, platform constraints.
- [ROADMAP.md](ROADMAP.md) — checkpoints CP0–CP9 with exit-criterion demos, hardware needs, and standing risks.
