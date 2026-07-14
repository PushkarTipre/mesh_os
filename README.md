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

🚧 Early development — **Checkpoints 0–5 done in code** (project scaffolding; identity & crypto core; packet layer; Nearby Connections transport; the public `MeshOS` facade with reliable single-hop messaging; trust/contacts/QR exchange with SQLite persistence). None of CP3/CP4/CP5's on-device demos — two real phones actually discovering, chatting, and exchanging QR codes — have been run yet; see "Try it" below. **Android-only for v1**; iOS is deferred (see the platform reality check in ARCHITECTURE.md §11). See [ROADMAP.md](ROADMAP.md) for the checkpoint plan and what "done" means at each stage.

## Repo layout

```
packages/mesh_core/            pure-Dart SDK core: identity, crypto, packets, transport-agnostic session handshake, trust primitives
packages/mesh_os/              public SDK: the MeshOS facade -- mesh_core + a transport + platform storage (secure storage, SQLite via drift)
packages/mesh_transport_nearby/ Transport implementation over Google Nearby Connections (Android)
apps/mesh_console/             dev/demo Flutter app (not a product) -- uses the MeshOS facade, not the pieces directly
```

Root `pubspec.yaml` is a Dart pub workspace — `flutter pub get` once at the repo root resolves all four packages.

## Try it

Everything that runs without hardware:

```
flutter pub get                          # from repo root
(cd packages/mesh_core && dart test)     # 82 unit tests: identity/crypto/packets/session/delivery/trust (CP1-CP5)
(cd packages/mesh_os && flutter test)    # 7 unit tests: DriftTrustStore against real in-memory SQLite
flutter analyze                          # whole workspace
(cd packages/mesh_core && dart run example/identity_demo.dart)  # see the crypto core in action
```

The CP3/CP4/CP5 demo, which does need hardware (two Android phones, Nearby Connections has no emulator support and QR scanning needs real cameras):

1. `flutter run` from `apps/mesh_console` on both phones.
2. Grant the Nearby/Bluetooth/location/camera permission prompts on each.
3. Each phone shows its Node ID and starts advertising + discovering + auto-connecting automatically -- no manual pairing.
4. Within a few seconds each phone lists the other, first as "Connecting...", then "Handshaking...", then "Ready to chat · known" — note: no name yet, just the Node ID.
5. Tap the peer on either phone to open a chat screen; send a message. It should appear on the other phone almost immediately, and the sender's copy should flip from "sending" to "delivered".
6. On phone A, tap the QR icon in the app bar, type a display name, and show the generated code. On phone B, tap the scan icon and scan it. B should get a "Trusted <name>" confirmation, and B's device-list entry for A should now show that name instead of A's Node ID. Repeat in the other direction so both sides are trusted.
7. Long-press (via the trailing menu) either device and choose **Block**. The connection should drop within moments, and the two phones should not reconnect while the block is in place. **Unblock** should let them find each other again.
8. Force-quit and reopen the app on either phone — the Node ID, the chat history, and the trusted contact's name should all still be there.

`apps/mesh_console` no longer touches `mesh_transport_nearby` directly (that was a CP3-only shortcut) -- it only calls `MeshOS`, same as any other app built on the SDK would.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — system design: identity, trust model, packet format, routing, security model, platform constraints.
- [ROADMAP.md](ROADMAP.md) — checkpoints CP0–CP9 with exit-criterion demos, hardware needs, and standing risks.
