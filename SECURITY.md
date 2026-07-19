# MeshOS Security Model

MeshOS is a peer-to-peer offline mesh networking SDK (see [ARCHITECTURE.md](ARCHITECTURE.md)). This document states plainly what it protects against, what it does not, and why — so an app built on it can make informed decisions rather than assume guarantees that don't exist. It reflects the v1 (Android-only, Checkpoints 0–9) design; nothing here is aspirational.

MeshOS is early-stage software that has **not** had an independent security audit. Treat every claim below as "designed to," not "proven to."

## What's protected

**Message confidentiality.** Direct and routed messages (`MeshOS.send`) are encrypted to the *destination's* public key: X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305 AEAD (`EncryptedEnvelope`). Only the destination can decrypt. A relay carrying the packet sees only the encrypted payload and the routing header (`tempSourceId`/`tempDestId`, both opaque, rotating or pseudonymous — see below).

**Message integrity and authenticity.** Every packet is Ed25519-signed by its origin. A relay can verify a packet came from whoever it claims (via a temp ID it may not even recognize) without being able to read it, and without a prior key exchange — the identity handshake, broadcast, and QR trust exchange are all *self-certifying*: the signature must verify against a public key embedded in the same payload, which is proof of private-key possession on its own.

**Private key custody.** Signing and agreement private keys never leave the device and are never transmitted, in any packet type. They're generated on first launch (`NodeIdentity.generate`) and persisted in platform secure storage (`flutter_secure_storage`), not in the SQLite trust/contacts database.

**Trust is explicit, not ambient.** Meeting a stranger over the mesh (the discovery handshake) only ever promotes them to `known` — messaging works, but nothing implies endorsement. `trusted` only ever comes from an explicit, user-initiated `IdentityCard` (QR) exchange. `blocked` is enforced at both handshake time (refuse the session, disconnect) and on every subsequent packet, direct or routed, as defense in depth.

**Basic flood/DoS hygiene.** A per-source sliding-window cap (`MeshLink`'s relay rate limiter) stops one noisy or hostile neighbor from turning any node into an unbounded amplifier for their traffic.

## What's explicitly *not* protected (v1 trade-offs)

**Traffic analysis.** Packet sizes, timing, and hop counts are all observable by anyone in radio range or relaying for you. MeshOS pads nothing and doesn't attempt timing obfuscation. An observer positioned as a relay can infer conversation patterns (who talks to whom, how often, roughly how much) even without reading content.

**Metadata resistance is partial, not real anonymity.**
- The rotating `TemporaryId` (`SHA-256(signing pubkey ‖ 10-minute time slot)[0:8]`) is what's broadcast during discovery, so passive scanning across a single time slot can't trivially link two sightings of the same device to the same permanent identity. It's a mitigation, not a guarantee — an adversary who correlates across the 10-minute rotation boundary, or who connects (triggering the handshake, which reveals the permanent public key to *that peer*), defeats it.
- Multi-hop routing needs a *non-rotating* `routingAddress` (`SHA-256(signing pubkey)[0:8]`) instead, because store-and-forward packets can sit for hours — a rotating address would go stale before delivery. This is a deliberate, narrower privacy trade-off scoped only to routed traffic (see ARCHITECTURE.md §3): a relay that sees the same `routingAddress` repeatedly *can* correlate that it's the same node across that traffic, even without knowing who that node is.
- BLE peripheral advertising address stability depends on the OS/chipset (some randomize periodically for privacy, most don't reliably); Nearby Connections' own address behavior is opaque, controlled by Google Play services, not MeshOS.

**Flooding-based routing is inherently spammable beyond the rate limiter.** v1 routing (ARCHITECTURE.md §7) is plain TTL-bounded flooding with dedup — the simplest and most bandwidth-wasteful option on the routing roadmap, chosen deliberately to get multi-hop delivery working before optimizing it. The per-source rate limit caps *one neighbor's* ability to flood, but a handful of colluding or compromised nodes can still degrade mesh bandwidth for everyone nearby. Smarter routing (gossip, distance-vector, AODV) is on the roadmap specifically to reduce this, not to add security beyond what flooding already has.

**No protection against a malicious relay dropping or reordering your traffic.** A relay can silently refuse to forward (or selectively forward) anything it's asked to relay — MeshOS has no reputation system, path diversity, or delivery-receipt-based relay accountability in v1. Reliability (ACK/retry, end-to-end ack for routed sends) recovers from *accidental* loss, not adversarial dropping — if a hostile relay is the *only* path to a destination, delivery simply fails or times out, and the sender has no way to tell "no path exists" apart from "someone is blocking me."

**No forward secrecy across sessions.** Each direct message is encrypted with a key derived fresh from ECDH at encrypt time (`identity.encryptFor`), but the long-term X25519 agreement keypair itself doesn't rotate. A future compromise of a device's stored private key would let an attacker decrypt any past traffic they'd recorded, for any peer, back to when that keypair was generated. (This is a materially different risk from most messengers' Double-Ratchet designs, which rotate key material continuously — MeshOS doesn't do this in v1.)

**Broadcast and pub/sub are always unencrypted.** By design — a broadcast has no single destination to encrypt for, and its trust model is "the signature proves who sent it," not confidentiality. Never send anything through `broadcast()`/`publish()` that shouldn't be readable by every device in range, indefinitely.

**No account/device revocation beyond local blocking.** Blocking a contact stops *your* device from talking to them; it does nothing to their standing anywhere else on the mesh, and there's no compromised-key revocation mechanism if a device (and its private keys) is lost or stolen. The affected person's only recourse today is generating a new identity.

**Physical/OS-level compromise is entirely out of scope.** A rooted/compromised device, a malicious keyboard, or OS-level malware can read anything MeshOS can read, regardless of any of the above.

## Threat actors this is (and isn't) designed against

| Actor | Designed to resist? |
|---|---|
| Passive eavesdropper reading raw radio traffic | Yes — payloads are encrypted, signatures don't leak content |
| A relay you don't know or trust, forwarding your traffic | Yes, for confidentiality/integrity — no, for availability (see "malicious relay" above) |
| A blocked contact trying to reconnect or route around the block | Yes, at handshake and per-packet |
| Someone passively scanning for MeshOS devices nearby | Partially — temp-ID rotation limits *casual* correlation, not determined tracking |
| A well-resourced adversary doing traffic analysis across many observation points | No |
| Someone who has physically compromised your device | No — out of scope |
| A relay deliberately dropping your traffic to censor you | No mitigation beyond "try another path if one exists" |

## Reporting a vulnerability

MeshOS doesn't have a dedicated security contact or bug bounty yet — it's pre-release, unaudited software. Until that changes, report suspected vulnerabilities via the project's issue tracker, or directly to a maintainer if you'd prefer the report not be public before a fix lands. Please don't test against other people's devices without their consent — everything above should be reproducible against your own two test phones (see [README.md](README.md)).

## See also

[ARCHITECTURE.md](ARCHITECTURE.md) §3 (identity), §4 (trust model), §7 (routing/relay), §8 (security model summary) go into implementation detail behind the claims above, including exactly which checkpoint each protection landed in and which file to read.
