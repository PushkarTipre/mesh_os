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

🚧 Early development — **Checkpoints 0 and 1 done** (project scaffolding; identity & crypto core). Next up: Checkpoint 2 (packet layer). **Android-only for v1**; iOS is deferred (see the platform reality check in ARCHITECTURE.md §11). See [ROADMAP.md](ROADMAP.md) for the checkpoint plan and what "done" means at each stage.

## Repo layout

```
packages/mesh_core/    pure-Dart SDK core: identity, crypto, (soon) packets & routing
packages/mesh_os/      public SDK: mesh_core + platform storage/transports
apps/mesh_console/     dev/demo Flutter app (not a product)
```

Root `pubspec.yaml` is a Dart pub workspace — `flutter pub get` once at the repo root resolves all three packages.

## Try it

```
flutter pub get                          # from repo root
(cd packages/mesh_core && dart test)     # 20 unit tests: identity, crypto, temp-ID rotation, persistence
flutter analyze                          # whole workspace
```

`apps/mesh_console` currently shows the device's generated Node ID on launch, persisted via platform secure storage — force-quitting and reopening the app should show the same ID.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — system design: identity, trust model, packet format, routing, security model, platform constraints.
- [ROADMAP.md](ROADMAP.md) — checkpoints CP0–CP9 with exit-criterion demos, hardware needs, and standing risks.
