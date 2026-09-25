# VCP — VCam Protocol, version 1

| Field | Value |
|---|---|
| Status | Draft 1 (2026-09-24). Covers T1: tracking, T1 controls, clock sync, status, pairing, and session setup. |
| Implements | SRS v3 PR-001..004, PR-006, DM-001..003, NET-002/003, NFR-SEC-001, FR-UX-002, FR-TRK-002/003, FR-CTL-004/009 |
| Golden vectors | `testdata/vcp/` (task 1.1.2). If this document and the vectors disagree, fix whichever is wrong; neither wins by default. |
| Implementations | Rust `native/vcam-protocol` (Blender side), Swift `SightlineIOS` (iPhone side) |

The keywords MUST, SHOULD, and MAY are used as in RFC 2119.

## 1. Overview

VCP connects one iPhone (the **device**) to one Blender session (the **host**).

```
device (iPhone)                                  host (Blender + vcam_native)
      |------- TCP: HELLO / pairing / session setup ------->|   control channel, stays open
      |<------------------------------------------------------|
      |======= UDP: POSE (60 Hz), CONTROL_STATE, CLOCK reply =>|   authenticated (HMAC trailer)
      |<====== UDP: CLOCK request (1 Hz), STATUS (2 Hz) =======|
```

- The device finds the host over DNS-SD (NET-001; §3), opens the TCP control channel, pairs once with a 6-digit code (§9), and then sets up a **session** on every connection (§10).
- A session has a random non-zero `session_id` and two directional 256-bit keys. Every UDP datagram carries both.
- Closing the TCP connection ends the session. Reconnecting starts a new session without re-pairing (NET-004).

Reserved for Phase 2 and later (not specified in v1): `VIDEO_FRAGMENT`, `ACK_KEYFRAME_REQ`, lens/focus/aperture/record/transport fields in `CONTROL_STATE`, take-list TCP messages.

## 2. Conventions

- **Byte order:** little-endian for every integer and float field (PR-001). The one exception is the SRP numbers in §9, which are big-endian byte strings as defined by RFC 5054 and are treated as opaque bytes on the wire.
- **Types:** `u8/u16/u32/u64` unsigned integers; `f32` IEEE 754 binary32; `bytes[n]` a fixed-length byte string; `str8` a `u8` byte length followed by that many bytes of UTF-8 (no terminator).
- **Reserved** fields and bits MUST be sent as zero and MUST be ignored on receipt.
- **Forward compatibility:** a receiver MUST accept a payload *longer* than the layout it knows and ignore the extra bytes. A payload *shorter* than the v1 layout MUST be dropped. Later minor additions append fields; they never reorder them.
- **Clocks** (all in nanoseconds, `u64`):
  - **Device clock:** the clock that `ARFrame.timestamp` uses, in ns. `POSE.capture_time_ns` and the device's `CLOCK` timestamps MUST come from this same clock. (Open item O-1: confirm which system clock this is in task 1.4.2.)
  - **Host clock:** a monotonic clock in the native module (for example, ns since the module started). It never goes backwards and isn't wall time.

## 3. Transport and discovery

| Channel | Carries | Notes |
|---|---|---|
| TCP (host listens; port advertised) | `HELLO`, pairing, session setup, `ERROR` | One connection per device. It stays open for the session. |
| UDP (host listens; port given in `SESSION_CHALLENGE`) | `POSE`, `CONTROL_STATE`, `CLOCK`, `STATUS` | Every datagram is authenticated (§4.2). |

- **DNS-SD** (NET-001): the host advertises `_vcam-ctl._tcp` for the control port and `_vcam._udp` for the UDP port while the host session is enabled/listening, including before a device pairs. Both TXT records contain `vcp=1` (highest supported protocol version), `blend=<.blend file name>` (empty for an unsaved file), `host=<machine name>`, `tcp=<decimal TCP port>` and `udp=<decimal UDP port>`. SRV and TXT ports are the actual bound ports. Each TXT key/value entry must fit the DNS-SD 255-byte limit, including `=`. The device uses the UDP port from authenticated `SESSION_CHALLENGE`, not from DNS-SD. Disabling the host session withdraws both services.
- **Addresses:** the device sends UDP to the host's TCP peer address and the `udp_port` from `SESSION_CHALLENGE`. The host sends UDP to the source address and port of the **most recent authenticated** datagram from the device, so it follows Wi-Fi roaming (NET-004).
- **Size limits:** a UDP datagram MUST NOT exceed 1200 bytes, which avoids IP fragmentation on typical Wi-Fi paths. A TCP message payload MUST NOT exceed 4096 bytes in v1. A receiver MUST drop, and never allocate for, anything larger.

## 4. Message frame

### 4.1 Header (PR-001), 12 bytes

| Offset | Field | Type | Value |
|---|---|---|---|
| 0 | `magic` | bytes[4] | ASCII `VCP1` (`56 43 50 31`) |
| 4 | `version` | u8 | `1` |
| 5 | `type` | u8 | §5 |
| 6 | `session_id` | u32 | `0` on the TCP channel before a session exists; otherwise the session's id |
| 10 | `len` | u16 | payload length in bytes (excludes the header and trailer) |

### 4.2 Authentication trailer (PR-006), 8 bytes

Every **UDP** datagram is `header ‖ payload ‖ tag`, where

```
tag = HMAC-SHA256(k_dir, header ‖ payload)[0..8]
```

`k_dir` is `k_d2h` for device→host and `k_h2d` for host→device (§10.3). Separate direction keys stop a datagram from being reflected back to its sender. TCP messages in v1 carry **no** trailer: pairing and session messages authenticate themselves through their proofs.

### 4.3 Receive rules (UDP)

A receiver processes a datagram in this order and **silently drops** it at the first failure. It never panics or allocates on bad input (PR-005, NFR-REL-001):

1. Datagram length ≥ 20 (header + trailer) and ≤ 1200.
2. `magic` = `VCP1`.
3. `version` = 1. Unknown versions are dropped without an error (PR-001).
4. `12 + len + 8` = the datagram length.
5. `session_id` is non-zero and equals the current session's id.
6. The tag verifies, compared in constant time.
7. `type` is known for this direction. Unknown types are dropped without an error (PR-001).
8. The payload is at least as long as the v1 layout for that type (§2).
9. Per-type freshness rules (§6).

## 5. Message types

| Type | Name | Channel | Direction | Rate |
|---|---|---|---|---|
| `0x01` | `POSE` | UDP | device → host | one per `ARFrame` (typically 60 Hz) |
| `0x02` | `CONTROL_STATE` | UDP | device → host | on change, then repeated at 2 Hz until acknowledged |
| `0x03` | `CLOCK` | UDP | request host → device, reply device → host | 1 Hz |
| `0x04` | `STATUS` | UDP | host → device | 2 Hz and on change |
| `0x05` | `VIDEO_FRAGMENT` | UDP | host → device | reserved (Phase 2) |
| `0x06` | `ACK_KEYFRAME_REQ` | UDP | device → host | reserved (Phase 3) |
| `0x40` | `HELLO` | TCP | device → host | first message on every connection |
| `0x41` | `PAIR_CHALLENGE` | TCP | host → device | |
| `0x42` | `PAIR_PROOF` | TCP | device → host | |
| `0x43` | `PAIR_ACCEPT` | TCP | host → device | |
| `0x44` | `SESSION_CHALLENGE` | TCP | host → device | |
| `0x45` | `SESSION_PROOF` | TCP | device → host | |
| `0x46` | `SESSION_ACCEPT` | TCP | host → device | |
| `0x4F` | `ERROR` | TCP | either | then the sender closes the connection |

## 6. UDP messages

### 6.1 `POSE` (0x01), 42 bytes (DM-001, ARC-004, FR-TRK-002)

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `seq` | u32 | +1 per pose within the session, starting at 1 |
| 4 | `capture_time_ns` | u64 | device clock at capture (`ARFrame.timestamp`) |
| 12 | `position_m` | f32[3] | x, y, z in canonical axes, metres (§7) |
| 24 | `orientation` | f32[4] | unit quaternion **x, y, z, w** in canonical axes (§7) |
| 40 | `tracking_state` | u8 | table below |
| 41 | `flags` | u8 | bit 0: intrinsics follow (reserved in v1, MUST be 0); bits 1–7 reserved |

| `tracking_state` | ARKit state |
|---|---|
| 0 | `.notAvailable` |
| 1 | `.limited(.initializing)` |
| 2 | `.limited(.excessiveMotion)` |
| 3 | `.limited(.insufficientFeatures)` |
| 4 | `.limited(.relocalizing)` |
| 5 | `.normal` |
| 6 | `.limited` with any other or future reason |

- **Freshness (NET-002):** the host keeps only the pose with the highest `seq` seen in this session. Anything with a lower or equal `seq` is dropped, which also defeats replay. Poses are never retransmitted.
- If `tracking_state` ≠ 5, the pose values are whatever ARKit reported. The host decides whether to hold the last good pose (FR-TRK-002).
- A non-finite float or a quaternion whose norm is outside 0.9–1.1 makes the pose invalid: drop it. The host renormalises accepted quaternions.

Example (session keys from §11):

```
header   56 43 50 31 01 01 cd ab 34 12 2a 00
payload  01 00 00 00 00 ca 9a 3b 00 00 00 00 00 00 00 3f
         00 00 a0 bf cd cc cc 3f f3 04 35 3f 00 00 00 00
         00 00 00 00 f3 04 35 3f 05 00
tag      07 e8 fd 15 5e 7c 87 5a
```

That is `seq=1`, `capture_time_ns=1000000000`, `position=(0.5, −1.25, 1.6)`, `orientation=(0.7071068, 0, 0, 0.7071068)`, `tracking_state=5`, `flags=0`.

### 6.2 `CONTROL_STATE` (0x02), 16 bytes in v1 (FR-CTL-004, FR-CTL-009, FR-TRK-003)

This message carries the **complete** current control state, never a delta, so a lost packet can't leave the two ends out of sync.

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `state_seq` | u32 | +1 on every change, starting at 1 |
| 4 | `fields` | u32 | presence bits: bit 0 `motion_scale`, bit 1 `lock_flags`, bit 2 `origin_epoch`; bits 3–31 reserved for T2/T3 fields, which will be appended after offset 16 |
| 8 | `motion_scale` | f32 | host metres per device metre (1:10 → `10.0`). MUST be finite and in [0.001, 1000] |
| 12 | `lock_flags` | u8 | bit 0 lock height, bit 1 lock roll, bit 2 pan only (lock position); bits 3–7 reserved |
| 13 | reserved | u8 | 0 |
| 14 | `origin_epoch` | u16 | +1 each time the operator presses **Set origin**. On a change, the host re-zeros the rig's position and yaw to the current pose (FR-TRK-003, FR-BL-003) |

- The host applies a `CONTROL_STATE` only if `state_seq` is greater than the last one applied, and echoes the applied `state_seq` in `STATUS.control_ack`.
- The device sends on every change, then repeats the latest state every 500 ms until `STATUS.control_ack` ≥ its `state_seq`.
- A field whose presence bit is 0 keeps its previous value. The first state in a session MUST set all v1 bits.
- `origin_epoch` wraps at 65535 → 0. The host treats *any change* as a reset request; it doesn't compare magnitudes.

Example: `state_seq=7`, all three fields present, scale `10.0`, lock roll, `origin_epoch=3`:

```
header   56 43 50 31 01 02 cd ab 34 12 10 00
payload  07 00 00 00 07 00 00 00 00 00 20 41 02 00 03 00
tag      30 d3 1c 22 a8 13 fd 2b
```

### 6.3 `CLOCK` (0x03), 28 bytes (NET-003)

NTP-style four-timestamp exchange. The host initiates at 1 Hz. `CLOCK` also serves as the heartbeat in both directions.

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `mode` | u8 | 0 = request (host → device), 1 = reply (device → host) |
| 1 | reserved | u8[3] | 0 |
| 4 | `t1` | u64 | host clock when the request was sent (echoed in the reply) |
| 12 | `t2` | u64 | device clock when the request was received (0 in a request) |
| 20 | `t3` | u64 | device clock when the reply was sent (0 in a request) |

The host records `t4` (host clock) when the reply arrives and computes:

```
offset θ = ((t2 − t1) + (t3 − t4)) / 2      device clock − host clock
delay  δ = (t4 − t1) − (t3 − t2)            round trip
host_time(capture_time_ns) = capture_time_ns − θ
```

- The host accepts a reply only if its `t1` matches one of its last 4 outstanding requests, sent less than 2 s ago. This blocks replayed or forged-timing replies within the session. A matched request is consumed, so a repeated reply is rejected; a reply with `t4 < t1`, `t3 < t2` or δ < 0 is rejected as impossible. The host records a request only once it has been sent.
- The host SHOULD estimate θ from the samples with the lowest δ in a sliding window, and report offset and jitter (the spread of θ across that window) in its stats. Reference estimator (Rust `ClockEstimator`, vectors `testdata/vcp/clock_sync.json`): the window is the last 8 accepted samples (8 s at 1 Hz); offset and δ come from the lowest-δ sample (the newest on ties); jitter is the integer RMS of every windowed θ around that offset, in ns. Division in θ truncates toward zero. The estimate resets with each session.
- Worked example: `t1=5.000000000 s`, `t2=1.000400000 s`, `t3=1.000450000 s`, `t4=5.001000000 s` gives θ = −4.000075 s and δ = 0.95 ms.

Request example (host → device, `t1=5000000000`):

```
header   56 43 50 31 01 03 cd ab 34 12 1c 00
payload  00 00 00 00 00 f2 05 2a 01 00 00 00 00 00 00 00
         00 00 00 00 00 00 00 00 00 00 00 00
tag      c2 ed c7 e9 11 66 52 0f
```

Reply example (device → host, `t2=1000400000`, `t3=1000450000`):

```
header   56 43 50 31 01 03 cd ab 34 12 1c 00
payload  01 00 00 00 00 f2 05 2a 01 00 00 00 80 e4 a0 3b
         00 00 00 00 d0 a7 a1 3b 00 00 00 00
tag      22 4e b2 35 b6 32 91 db
```

### 6.4 `STATUS` (0x04), at least 16 bytes

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `status_seq` | u32 | +1 per `STATUS` sent. The device ignores lower or equal values |
| 4 | `applied_pose_seq` | u32 | `seq` of the last pose the host applied (0 = none) |
| 8 | `control_ack` | u32 | `state_seq` of the last `CONTROL_STATE` applied (0 = none) |
| 12 | `error_code` | u16 | 0 = none; 1 = no camera; 2 = camera deleted; 3 = host paused; others reserved |
| 14 | `flags` | u8 | bit 0 session active, bit 1 camera bound; bits 2–7 reserved |
| 15 | `camera_name` | str8 | name of the driven camera object, ≤ 63 bytes |

Example: `status_seq=2`, `applied_pose_seq=1`, `control_ack=7`, no error, both flags set, camera `Camera`:

```
header   56 43 50 31 01 04 cd ab 34 12 16 00
payload  02 00 00 00 01 00 00 00 07 00 00 00 00 00 03 06
         43 61 6d 65 72 61
tag      36 5e ea 92 63 1a ca fe
```

## 7. Canonical pose and coordinates (DM-001..003)

- **Canonical axes = Blender's:** right-handed, Z up, metres. A camera with the identity orientation looks down its local **−Z**, with local **+Y** up (DM-002).
- **ARKit world** with `worldAlignment = .gravity`: right-handed, Y up (gravity is (0, −1, 0) per `ARConfiguration.h`), metres, origin at the device's position when the session started.
- **Conversion, done once on the device (DM-002):** a +90° rotation about X maps ARKit Y-up to canonical Z-up.

```
position:    (x, y, z)_arkit  →  (x, −z, y)_canonical
orientation: q_canonical = q_C ⊗ q_arkit,  q_C = (x = sin 45°, y = 0, z = 0, w = cos 45°)
```

Here `q_arkit` is the rotation of the ARKit camera transform. Because both sides use the same camera-local convention (looks −Z, +Y up), no right-multiplied local correction is needed. **Open item O-2:** confirm ARKit's camera-local axes for the landscape orientation the app uses, on a device (task 1.4.2). If they differ, the iOS converter adds a fixed local rotation; the wire format doesn't change.
- No Euler angles appear on the wire (DM-003).
- `testdata/coords/` (task 1.1.2) pins this mapping with golden vectors: identity, ±90° pan/tilt/roll, combined, and translated (DM-004).

## 8. Liveness and recovery

- The device treats the session as lost if no authenticated host datagram (`CLOCK` request or `STATUS`) arrives for 3 s, or if the TCP connection closes. It then reconnects with `HELLO` mode 1 (§10), retrying at least every 500 ms while the network is up (NET-004: reconnect within 3 s).
- The host marks the device stale in its UI after 1 s without an authenticated device datagram. It ends the session when the TCP connection closes, or after 10 s without any authenticated datagram.
- A new session resets every sequence counter (`seq`, `state_seq`, `status_seq`). The device MUST send a complete `CONTROL_STATE` (all v1 bits) as soon as the session starts.

## 9. Pairing (TCP), FR-UX-002, NFR-SEC-001

Pairing turns a 6-digit code shown in Blender's N-panel into a 256-bit **pairing key** `PK` that both ends store:
- the device in the Keychain;
- the host in Blender's user config directory, keyed by `device_id`.

### 9.1 Choice of mechanism: SRP-6a

A 6-digit code has about 20 bits of entropy. Deriving keys from the code directly (for example, HKDF over the code and nonces) lets anyone who records the exchange brute-force the code offline. An authenticated key exchange where one side reveals a code-dependent confirmation also lets an active man in the middle recover the code offline. Only a PAKE limits every attacker to **one online guess per attempt**.

v1 uses **SRP-6a** as specified in RFC 5054, with the RFC 5054 3072-bit group:
- Apple's CryptoKit (iOS 27 SDK) has no PAKE. A permissively licensed SRP implementation exists for Swift (`swift-srp`, Apache-2.0, stated RFC 5054 compliant) and for Rust (RustCrypto `srp`, MIT/Apache-2.0).
- Implementations MUST follow the formulas below exactly and MUST pass the RFC 5054 Appendix B test vectors and `testdata/vcp/pairing-*`. Library defaults are not trusted: RustCrypto `srp` 0.6.0 computes `u` over unpadded A and B, and uses non-RFC proofs.

### 9.2 Parameters

| Symbol | Value |
|---|---|
| `N`, `g` | RFC 5054 Appendix A, 3072-bit group, `g = 5` |
| `H` | SHA-256 |
| `PAD(x)` | `x` as a big-endian byte string left-padded with zeros to 384 bytes (the length of `N`) |
| `I` | ASCII `vcam` |
| `P` | the 6 ASCII digits of the code, for example `042917` |
| `s` | 16 random bytes chosen by the host per pairing attempt |
| `a`, `b` | ≥ 256-bit random private values from a CSPRNG, used once |

```
x = H(s ‖ H(I ‖ ":" ‖ P))            v = g^x mod N          k = H(N ‖ PAD(g))
A = g^a mod N                        B = (k·v + g^b) mod N  u = H(PAD(A) ‖ PAD(B))
device: S = (B − k·g^x)^(a + u·x) mod N
host:   S = (A · v^u)^b mod N
K = H(PAD(S))
```

Both ends MUST abort (sending `ERROR` 6) if `A mod N = 0`, `B mod N = 0`, or `u = 0`.

### 9.3 Messages

`HELLO` (0x40), device → host, 37 + name bytes:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `mode` | u8 | 0 = pair with code, 1 = start a session with an existing pairing |
| 1 | `proto_min` | u8 | lowest VCP version supported (1) |
| 2 | `proto_max` | u8 | highest VCP version supported (1) |
| 3 | reserved | u8 | 0 |
| 4 | `device_id` | bytes[16] | random, generated once per app install and stored |
| 20 | `nonce_d` | bytes[16] | fresh random per `HELLO` |
| 36 | `device_name` | str8 | for the host UI, ≤ 64 bytes |

`PAIR_CHALLENGE` (0x41), host → device: `host_id` bytes[16] (random, generated once per host install), `s` bytes[16], `PAD(B)` bytes[384]. 416 bytes.

`PAIR_PROOF` (0x42), device → host: `PAD(A)` bytes[384], `M1` bytes[32]. 416 bytes.

`PAIR_ACCEPT` (0x43), host → device: `M2` bytes[32].

```
T_pair = SHA-256(HELLO payload ‖ PAIR_CHALLENGE payload ‖ PAD(A))
M1 = HMAC-SHA256(K, "VCP1 pair M1" ‖ T_pair)
M2 = HMAC-SHA256(K, "VCP1 pair M2" ‖ T_pair ‖ M1)
PK = HKDF-SHA256(IKM = K, salt = T_pair, info = "VCP1 pairing key", L = 32)
```

Flow: `HELLO(mode 0)` → `PAIR_CHALLENGE` → `PAIR_PROOF` → the host verifies `M1` in constant time → `PAIR_ACCEPT` → the device verifies `M2` → both store `PK` with the peer's id. The device then sends `HELLO(mode 1)` on the same connection to start a session (§10).

Example `HELLO` (mode 0, `device_id = 00112233…eeff`, `nonce_d = a5×16`, name `iPhone`). TCP, `session_id` 0, no trailer:

```
header   56 43 50 31 01 40 00 00 00 00 2b 00
payload  00 01 01 00 00 11 22 33 44 55 66 77 88 99 aa bb
         cc dd ee ff a5 a5 a5 a5 a5 a5 a5 a5 a5 a5 a5 a5
         a5 a5 a5 a5 06 69 50 68 6f 6e 65
```

Full pairing transcripts, with fixed `a`, `b`, `s`, and code, are golden vectors in `testdata/vcp/` (task 1.1.2). They're too long to repeat here.

### 9.4 Code policy (host)

- The code is 6 digits drawn uniformly from a CSPRNG (000000–999999). It's shown only while pairing is enabled in the N-panel.
- It's single-use: it's replaced after one successful pairing, after **3** failed `PAIR_PROOF`s, or after 5 minutes. A failed proof gets `ERROR` 2 and the connection is closed. Only one pairing attempt may run at a time; another gets `ERROR` 4.
- So an active attacker succeeds against a given code with probability at most 3 × 10⁻⁶. A passive observer learns nothing usable (SRP).

## 10. Session setup (TCP)

### 10.1 Messages

After `HELLO(mode 1)`:

`SESSION_CHALLENGE` (0x44), host → device, 40 bytes:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `host_id` | bytes[16] | lets the device pick the stored `PK` |
| 16 | `nonce_h` | bytes[16] | fresh random |
| 32 | `session_id` | u32 | random, non-zero, not equal to the previous session's |
| 36 | `udp_port` | u16 | the host's UDP port for this session |
| 38 | reserved | u16 | 0 |

`SESSION_PROOF` (0x45), device → host: `proof_d` bytes[32].
`SESSION_ACCEPT` (0x46), host → device: `proof_h` bytes[32].

If the host has no `PK` for `device_id`, it replies `ERROR` 3 (not paired) instead of `SESSION_CHALLENGE`. The device then offers to pair again.

### 10.2 Proofs

```
T_sess  = SHA-256(HELLO payload ‖ SESSION_CHALLENGE payload)
proof_d = HMAC-SHA256(PK, "VCP1 session D" ‖ T_sess)
proof_h = HMAC-SHA256(PK, "VCP1 session H" ‖ T_sess ‖ proof_d)
```

The host verifies `proof_d` in constant time before sending `SESSION_ACCEPT`. The device verifies `proof_h` before sending any UDP. A failed proof gets `ERROR` 2 and the connection is closed.

### 10.3 Session keys

```
k_d2h ‖ k_h2d = HKDF-SHA256(IKM = PK, salt = T_sess, info = "VCP1 session keys" ‖ session_id (u32 LE), L = 64)
```

The session is active on both ends once `SESSION_ACCEPT` has been verified. UDP traffic (§6) starts then.

## 11. `ERROR` (0x4F)

Payload: `code` u16, reserved u16 (0), `message` str8 (≤ 127 bytes, for logs only). The sender closes the connection after sending it.

| Code | Meaning |
|---|---|
| 1 | unsupported protocol version (no overlap between `proto_min` and `proto_max`) |
| 2 | proof failed |
| 3 | device not paired |
| 4 | busy (another pairing in progress) |
| 5 | pairing disabled, or code expired |
| 6 | malformed message or illegal SRP value |

Example session keys used in the §6 examples (test values only, never used for real): `session_id = 0x1234ABCD`, `k_d2h = 00 01 02 … 1f`, `k_h2d = 20 21 22 … 3f`.

## 12. Security notes

- Authenticated: every UDP datagram of a session, and both ends of pairing and session setup. **Not encrypted:** pose, control, and status data are readable on the LAN. Stream encryption is NFR-SEC-002 (T3).
- Replay: the keys are fresh per session (the random `session_id` and nonces go into the HKDF), so datagrams from an old session fail the tag check. Within a session, the monotonic `seq`/`state_seq`/`status_seq` rules and `CLOCK` `t1` matching reject replays. The 64-bit tag gives 2⁻⁶⁴ forgery probability per attempt.
- Unpairing: deleting `PK` on either end forces re-pairing (`ERROR` 3).
- No analytics and no other listeners (NFR-SEC-003): the host listens only while a session is enabled.

## 13. Open items

| ID | Item | Resolve in |
|---|---|---|
| O-1 | Which system clock `ARFrame.timestamp` uses. The device's `CLOCK` timestamps must come from the same one. The SDK header doesn't say. | 1.4.2 (device check) |
| O-2 | ARKit camera-local axes for the landscape orientation the app uses (§7) | 1.4.2 (device check) |
| O-3 | Interop between `swift-srp` and the Rust SRP code against these exact formulas: RFC 5054 test vectors plus `testdata/vcp/pairing.json`. **Rust side verified 2026-09-24** (`vcam-protocol`: RFC 5054 App. B through the same generic code path, and a full byte-exact `pairing.json` transcript). Swift side still open. | 1.4.x |
| O-4 | `VIDEO_FRAGMENT` layout, `ACK_KEYFRAME_REQ`, and T2/T3 `CONTROL_STATE` fields | Phase 2/3 |

## 14. Change log

| Date | Change |
|---|---|
| 2026-09-24 | Draft 1: header, `POSE`, `CONTROL_STATE` (T1 subset), `CLOCK`, `STATUS`, SRP-6a pairing, session setup, HMAC trailer. |
