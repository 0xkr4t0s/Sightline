# Security policy

Sightline pairs a phone with Blender over the local network (SRP-6a pairing, per-session keys, authenticated UDP; see [`docs/protocol/vcp.md`](../docs/protocol/vcp.md)). Please report weaknesses in pairing, session crypto, packet parsing or the native module privately rather than in a public issue.

Report through **Security → Report a vulnerability** on this repository (GitHub private vulnerability reporting). Include the affected component (iOS app, Blender extension or `native/` crate), the commit, and steps or a packet capture to reproduce it.

There are no releases yet, so fixes land on `main`.
