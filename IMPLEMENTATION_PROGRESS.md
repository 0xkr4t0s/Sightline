# Implementation Progress

| Field | Value |
|---|---|
| Assessed | 2026-09-24 |
| Against | `docs/SRS.md` v3.0 (requirement IDs below refer to it) |
| Plan | `docs/IMPLEMENTATION_PLAN.md` v3.0 |

Status labels: **Done** · **Partial** (useful code exists but doesn't meet the requirement yet) · **Replace** (works, but the v3 architecture replaces it) · **Retire** (no longer in scope) · **Not started**.

## Summary

| Area | Status | Reality |
|---|---|---|
| iOS tracking (`VCamIOS/`) | Partial | Headless ARKit session sending FreeD over UDP. Good base for FR-TRK-001/005. The packet format and Euler conversion must be replaced with VCP + quaternions. |
| Blender extension (`BlenderAddOn/`) | Partial | Background UDP thread + main-thread apply works. FreeD/JSON parsing in Python must be replaced by the Rust module. Manifest targets 5.2 and bundles the `vcam_native` wheel (macOS arm64 only so far). |
| Rust native module | Partial | `native/` workspace with 5 crates. `vcam-py` builds the PyO3 module `vcam_native` (only `version()` so far), which imports inside Blender 5.2.2 on macOS (task 0.1.4). |
| Viewfinder stream (Blender → iPhone) | Not started | — |
| C++ `legacy/DesktopReceiver/` (incl. CMIO extension) | Retire | Moved to `legacy/` in task 0.1.2 (ARC-006). Port the parsers, their tests, and the test-pattern generator to Rust, then delete the directory. |
| Repo / CI | Partial | One git repo, private remote `origin`. CI run `35958600428` (GitHub, 2026-09-24): 10 of 13 jobs green (wheels ×3, split extension, Blender smoke ×3, rust-fmt, pytest, iOS). `cargo clippy` failed on all 3 OSes because of a new Rust 1.98 lint; fixed locally in loop iteration 15, and it needs a push to confirm. |

**Maturity:** early prototype. Phase 0 tasks 0.1.1–0.1.6 are done. The extension with the Rust module installs and imports on all 3 OSes in CI. CI is not fully green yet (clippy fix awaiting push). Spikes S-1, S-2, S-3 have macOS records; Windows/Linux parts are owner-blocked. Phase 1 started (1.1.1 done).

**Environment on the owner's Mac (2026-09-24):** Blender 5.2.2 LTS at `/Applications/Blender.app`; cargo/rustc 1.97.1; `.venv.nosync/` with pytest + maturin; Xcode 27.0 (via `DEVELOPER_DIR`) with the iOS 27.0 simulator.

## Last verified test runs (2026-09-24)

| Suite | Result | Note |
|---|---|---|
| Legacy C++ (`legacy/DesktopReceiver`) | 9/9 pass (fresh temp build dir) | Re-run after the move to `legacy/`. To be retired. The stale in-repo `build/` was deleted. |
| `BlenderAddOn/tests` (pytest, `.venv.nosync`) | 12/12 pass | Tests the non-standard FreeD layout; the code will be replaced. |
| `native/` cargo fmt/clippy/test | Pass, 5/5 crates | Includes `vcam-py` with pyo3 0.29.2. |
| Headless Blender `tests/blender/smoke_native.py` (macOS arm64) | Pass | Built extension zip, installed into a temporary user dir, enabled; printed `VCAM_NATIVE_OK 0.1.0`. |
| S-1 `tests/bench_render.py` (macOS arm64) | Pass, 9/9 cells in each of 3 runs | Runs: headless as fast as possible (S-1a); headless at 30 fps and in the GUI with timers (S-1b). Numbers in SRS §13.1, JSON in `reports/s1-render-2026-09-24-macos-arm64*.json`. |
| S-2a `vcam-video` example `s2_jpeg` (macOS arm64) | Pass, 6 frames × 3 qualities × 2 encoders | Every JPEG decoded at the right size; PSNR 37.9–47.6 dB. Numbers in SRS §13.2 and `reports/s2-jpeg-2026-09-24-macos-arm64.txt`. |
| S-2b `vcam-video` example `s2_videotoolbox` (macOS arm64) | Pass, 3 res × 2 configs (RGBA input unsupported, reported) | 160/160 frames, 0 dropped; ffmpeg decoded all 3 streams without errors (Main, no B-frames). Numbers in SRS §13.2 and `reports/s2-videotoolbox-2026-09-24-macos-arm64.txt`. |
| S-2c `vcam-video` example `s2_openh264` (macOS arm64) | Pass, 3 res × 2 builds × 2 thread counts | 160 frames each; ffmpeg decoded all 6 streams without errors (Constrained Baseline, no B-frames). Numbers in SRS §13.2 and `reports/s2-openh264-2026-09-24-macos-arm64.txt`. |
| VCamIOS `FreeDPacketEncoderTests` (iPhone 17 Pro sim, iOS 27.0) | 5/5 pass | After the checksum overflow fix (root commit `5ba2672`, was `ed349be` in the old `VCamIOS` repo). Will be replaced with VCP tests. |

---

## By SRS section

### §3 Architecture

| ID | Status | Evidence / gap |
|---|---|---|
| ARC-001 | Done | Extension + PyO3 crate `native/vcam-py` (`src/lib.rs`, maturin config in `pyproject.toml`), bundled as per-platform wheels. CI run `35958600428` built cp313 wheels for manylinux_2_28 x86-64, win_amd64, and macOS arm64, assembled them with `extension build --split-platforms`, and each platform zip imported `vcam_native` in Blender 5.2.2 (`blender-smoke` ×3). |
| ARC-002 | Partial | Crates split as required (`native/Cargo.toml:3-9`). `vcam-protocol` is `#![forbid(unsafe_code)]` (`native/vcam-protocol/src/lib.rs:5`), with no I/O. It now has the UDP framing/messages (task 1.1.3a). No net or production encoder code yet. |
| ARC-003 | Not started | No canonical pose; FreeD frame structs used throughout. |
| ARC-004 | Not started | iOS doesn't send a capture time or sequence number; Blender stamps receive time. |
| ARC-005 | Partial | Swift 5 mode with default `MainActor` isolation; every AR frame hops to the main actor to send (`VCamIOS/VCamIOS/TrackingSessionController.swift`). |
| ARC-006 | Partial | Moved to `legacy/DesktopReceiver/`, with a retirement note at `legacy/DesktopReceiver/README.md:1-6`. Porting to Rust and deleting the directory are still open. |
| ARC-007 | Not started | Optional. |

### §4 iOS app

| ID | Status | Evidence / gap |
|---|---|---|
| FR-TRK-001 | Partial | Pose per `ARFrame` with `worldAlignment = .gravity`; no seq, and the timestamp isn't transmitted. |
| FR-TRK-002 | Partial | State shown in the UI (`trackingStateDescription`), not sent. |
| FR-TRK-003 | Not started | |
| FR-TRK-004 | Not started | |
| FR-TRK-005 | Done | `handleScenePhase` stops tracking on inactive/background. |
| FR-TRK-006/007 | Not started | |
| FR-TRK-008 | Done | Headless `ARSession`; no camera preview. |
| FR-VF-* | Not started | |
| FR-CTL-* | Not started | |
| FR-UX-001/002 | Not started | iOS: manual host/port entry only (`TrackingSettings.swift`). The pairing crypto FR-UX-002 relies on exists in Rust (`vcam-protocol/src/pairing.rs`, task 1.1.3b); no UI or network wiring yet. |
| FR-UX-003/004 | Not started | Portrait `Form` UI (`ContentView.swift`). |
| Pose maths | Replace | `TrackingPose.swift` uses an aerospace Euler extraction on ARKit's Y-up frame. The replacement exists: `VCamIOS/VCamIOS/VCP/VCPCoordinates.swift` (DM-002 quaternion conversion, task 1.1.4a). Wiring it into the tracking path is task 1.4.2. |
| Project settings | Partial | Deployment target iOS 26.4; `SWIFT_VERSION = 5.0`; the camera usage string contains zero-width spaces (U+200B). |

### §5 Blender extension

| ID | Status | Evidence / gap |
|---|---|---|
| FR-BL-001 | Done | `blender_version_min = "5.2.0"`, `network` permission, `wheels`/`platforms`. CI writes all three platforms into the manifest (`tools/set_manifest_wheels.py`) and produced `windows-x64`, `linux-x64`, and `macos-arm64` zips that install and import (run `35958600428`). The committed manifest lists macOS only, for local builds. `windows-arm64` (SHOULD) not built. |
| FR-BL-002 | Partial | Latest-sample semantics and main-thread apply are done in Python (`core/udp_client.py`, `operators/tracking_receiver.py`). Sockets must move into the Rust module. |
| FR-BL-003 | Partial | Drives a chosen camera directly; no `VCam_Origin` rig; Euler rotation (`core/transform.py`). |
| FR-BL-004 | Partial | N-panel with connection settings and status (`ui/panels.py`); no pairing or stats. |
| FR-BL-005 | Partial | Lens/focus mapped from FreeD zoom/focus encoders; to be replaced by `CONTROL_STATE`. |
| FR-BL-006/007 | Not started | |
| FR-REN-* | Not started | S-1 (SRS §13.1) shows headless `GPUOffScreen` + `draw_view3d` + `read()` works, and zero-copy access through `vcam_native._frame_probe` works (`native/vcam-py/src/lib.rs:18-32`). Production code comes in Phase 2. **Flag:** EEVEE draw (76 ms at 540p) conflicts with FR-REN-004/NFR-PERF-002. |
| FR-TAKE-* | Not started | |
| UI text | Done | "Live Link" removed. `operators/tracking_receiver.py:23` now reads "Begin receiving FreeD camera tracking data over UDP" (task 0.1.6). The FreeD path itself goes away in 1.3.1. |

### §6 Protocol

| ID | Status | Evidence / gap |
|---|---|---|
| DM-001..003 | Partial | Specified (`vcp.md` §6.1, §7). Rust pose type (`vcam-protocol`); Swift pose type and ARKit→canonical conversion (`VCamIOS/VCamIOS/VCP/VCPMessages.swift`, `VCPCoordinates.swift`, task 1.1.4a), no Euler angles. Not yet used by the live tracking path (1.4.2). Open items O-1/O-2 (device checks). |
| DM-004 | Partial | `testdata/coords/arkit_to_canonical.json` (9 cases) is consumed by Swift `VCPGoldenTests.testARKitToCanonicalMatchesDM004Vectors` (position, quaternion, `matrix_world` columns, view direction; task 1.1.4a). The Rust side has no ARKit conversion by design (DM-002); the Blender apply step (1.3.2) will use the canonical columns. |
| PR-004 | Done | Spec with byte layouts and example hex (`docs/protocol/vcp.md`) plus golden vectors in `testdata/vcp/`: `messages.json` + 10 `.bin`, `receive.json` (26 receive-rule cases), `freshness.json`, `pairing.json`, `session.json`, `srp-rfc5054-appendix-b.json`. Generated by `tools/gen_testdata.py`, which self-checks against RFC 5054 App. B, RFC 5869 A.1, and every `vcp.md` example. |
| PR-001..003, PR-006 | Partial | Rust (`native/vcam-protocol`): UDP framing, HMAC trailer, messages, TCP control frames, SRP-6a pairing, session keys (tasks 1.1.3a/b). Swift (`VCamIOS/VCamIOS/VCP/VCPEndpoint.swift`, `VCPMessages.swift`, task 1.1.4a): UDP framing, CryptoKit HMAC-SHA256/64 with constant-time compare, §4.3 receive rules, `POSE`/`CONTROL_STATE`/`CLOCK`/`STATUS`. Both byte-exact against `messages.json` (8 UDP) and all 26 `receive.json` verdicts. Still to do: Swift TCP/pairing (1.1.4b), sockets (1.2.x/1.4.x). |
| PR-005 | Partial | `Endpoint::open` applies vcp.md §4.3 steps 1–8 in order with typed `DropReason`s. Decoding is bounds-checked (`src/wire.rs`), with no `unwrap` (clippy-enforced). It matches all 26 `receive.json` verdicts. Fuzz targets `native/fuzz/fuzz_targets/{udp_open,control_decode,pairing_inputs}.rs` (task 1.1.3c) assert round-trip and no-forgery properties. So far they've only had a **coverage-blind** 60 s run on stable (274.5M / 279.9M / 45k execs, 0 crashes). A coverage-guided `cargo fuzz` run (nightly) is pending CI or the owner's OK for a local nightly toolchain. |
| PR-FD-001 | Replace | Non-standard FreeD in `BlenderAddOn/core/freed_parser.py`, `VCamIOS/VCamIOS/FreeDPacketEncoder.swift`, `legacy/DesktopReceiver/src/protocol/FreeDParser.cpp`. |
| PR-FD-002, PR-OTIO-001 | Not started | Optional, T4. |

### §7 Cross-platform

| ID | Status | Evidence / gap |
|---|---|---|
| XP-001 | Done | CI run `35958600428`: `wheels` (manylinux 2_28, Windows, macOS arm64) and `extension` (`--split-platforms`) green. |
| XP-002 | Partial | CI `blender-smoke` green on Linux, Windows, macOS: `VCAM_NATIVE_OK 0.1.0` in each (run `35958600428`). That's the import smoke test; the real integration test with the fake iPhone is task 1.3.5. |
| XP-003 | Not started | S-2 found that the recommended encoders link statically (turbojpeg) or are OS frameworks; no production dependency yet. |
| XP-004 | Not started | S-3a (SRS §13.3): the linker-ad-hoc-signed `.so` loads when installed from a quarantined zip through Blender. A quarantined `.so` can hit a Gatekeeper prompt and denial, so Developer ID signing + notarization is still required (owner credentials). |
| XP-005/006 | Not started | |

### §8–§10

| ID | Status | Evidence / gap |
|---|---|---|
| NET-001 | Not started | |
| NET-002 | Partial | UDP, newest sample wins (Python client). Rust `SeqFilter` (newest-seq-wins, replay drop) passes `testdata/vcp/freshness.json`; not yet wired to sockets (1.2.1). |
| NET-003 | Partial | Offset/delay math `ClockSample::from_timestamps` (i128, overflow-safe) matches the vector. No estimator or 1 Hz exchange yet (1.2.4). |
| NET-004 | Not started | |
| NET-VID-* | Not started | S-2a/b/c (SRS §13.2), macOS: Stage A JPEG 540p q80 is about 1 ms at 9–13 Mbit/s @ 30 fps. Stage B VideoToolbox H.264 720p is 3.6/5.6 ms (med/p95). The OpenH264 fallback at 720p is about 3/5.5 ms plus 2–3 ms conversion. The software-fallback licensing is an open owner decision. Production encoder code comes in Phases 2–3. |
| LNS-* | Not started | |
| NFR-LAT-*, NFR-PERF-* | Not started | No latency measurements. Render/readback costs are measured by S-1 (SRS §13.1). |
| NFR-REL-* | Not started | |
| NFR-SEC-001 | Partial | Protocol side done in Rust: SRP-6a pairing (RFC 5054 App. B verified through the same code path; constant-time `pow_bounded_exp` for secret exponents), per-session HKDF keys, constant-time proof checks, HMAC on every UDP datagram. Not yet enforced on a live socket, and there's no key storage yet (1.2.2, 1.4.3). |
| NFR-SEC-002/003 | Not started | |
| NFR-QA-001 | Partial | One git repo. `xcodebuild test`, `cargo test` (in `native/`), and a headless Blender smoke test (`tests/blender/smoke_native.py`) all run. There's no single `blender --background … tests` runner for add-on logic yet. |
| NFR-QA-002 | Partial | `ci.yml` runs fmt, clippy (`-D warnings`), and test on 3 OSes, plus Python tests, headless Blender on 3 OSes, iOS unit tests, and (new) a `fuzz` job: nightly + `cargo-fuzz 0.13.2`, 60 s per target, seeded from `testdata/`, artifacts uploaded on failure. The first GitHub run failed only on clippy (fixed locally); the fuzz job hasn't run yet (awaiting push). |
| NFR-QA-003 | Partial | `testdata/` holds VCP message, receive-rule, pairing/session, and coordinate vectors (task 1.1.2). Consumed by Rust (`vcam-protocol/tests/`) and Swift (`VCamIOSTests/VCPGoldenTests.swift`, bundled via a `testdata` folder reference). Python consumer comes in 1.3.x; there are no fragment-reassembly vectors yet (Phase 2). CI checks the vectors are up to date. |
| NFR-QA-004 | Partial | Enforced by workspace lints: `unsafe_code` deny plus `clippy::undocumented_unsafe_blocks` deny (`native/Cargo.toml:22-32`). Checked with a throwaway probe: clippy rejected an uncommented `unsafe` block. |

---

## Next milestone

**Phase 0 exit:** single repo; `DesktopReceiver/` moved to `legacy/`; Rust workspace with a PyO3 module importing inside Blender 5.2 on all three OSes via CI; spikes S-1 (render/readback), S-2 (encoders), and S-3 (macOS loading) answered.
