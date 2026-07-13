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

🚧 Early development — **Checkpoints 0–3 done in code** (project scaffolding; identity & crypto core; packet layer; Nearby Connections transport). CP3's on-device demo — two real phones exchanging signed, encrypted packets — hasn't been run yet; see "Try it" below. **Android-only for v1**; iOS is deferred (see the platform reality check in ARCHITECTURE.md §11). See [ROADMAP.md](ROADMAP.md) for the checkpoint plan and what "done" means at each stage.

## Repo layout

```
packages/mesh_core/            pure-Dart SDK core: identity, crypto, packets, transport-agnostic session handshake
packages/mesh_os/              public SDK: mesh_core + platform storage
packages/mesh_transport_nearby/ Transport implementation over Google Nearby Connections (Android)
apps/mesh_console/             dev/demo Flutter app (not a product)
```

Root `pubspec.yaml` is a Dart pub workspace — `flutter pub get` once at the repo root resolves all four packages.

## Try it

Everything that runs without hardware:

```
flutter pub get                          # from repo root
(cd packages/mesh_core && dart test)     # 60 unit tests: identity/crypto (CP1), packet layer (CP2), session+transport (CP3)
flutter analyze                          # whole workspace
(cd packages/mesh_core && dart run example/identity_demo.dart)  # see the crypto core in action
```

The CP3 demo, which does need hardware (two Android phones, Nearby Connections has no emulator support):

1. `flutter run` from `apps/mesh_console` on both phones.
2. Grant the Nearby/Bluetooth/location permission prompts on each.
3. Each phone shows its Node ID and Temporary ID, and starts advertising + discovering automatically.
4. Within a few seconds each phone should list the other under "Nearby devices" — tap **Connect** on one side.
5. Both phones auto-accept the connection request; once the log shows "Discovery handshake complete ... session ready" on both, the **Send test packet** button lights up.
6. Tap it on either phone — the log on the *other* phone should show `Received from <id>: "Hello from ..." (signature verified, decrypted OK)`.

`apps/mesh_console` also still shows the device's generated Node ID on launch, persisted via platform secure storage from CP1 — force-quitting and reopening the app should show the same ID.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — system design: identity, trust model, packet format, routing, security model, platform constraints.
- [ROADMAP.md](ROADMAP.md) — checkpoints CP0–CP9 with exit-criterion demos, hardware needs, and standing risks.
