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

🚧 Early development — currently at **Checkpoint 0** (project scaffolding). **Android-only for v1**; iOS is deferred (see the platform reality check in ARCHITECTURE.md §11). See [ROADMAP.md](ROADMAP.md) for the checkpoint plan and what "done" means at each stage.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — system design: identity, trust model, packet format, routing, security model, platform constraints.
- [ROADMAP.md](ROADMAP.md) — checkpoints CP0–CP9 with exit-criterion demos, hardware needs, and standing risks.
