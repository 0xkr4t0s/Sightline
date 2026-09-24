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
| Repo / CI | Partial | One git repo at the root (task 0.1.1). `VCamIOS` history imported under `VCamIOS/` (commits `ae4d81c`, `984145a`, `5ba2672`). CI workflow `.github/workflows/ci.yml` is written and lint-clean but has never run on GitHub (no remote yet). |

**Maturity:** early prototype. Phase 0 tasks 0.1.1–0.1.6 are done locally; CI hasn't run on GitHub; spikes S-2 and S-3 are open, S-1 is done for macOS.

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
| VCamIOS `FreeDPacketEncoderTests` (iPhone 17 Pro sim, iOS 27.0) | 5/5 pass | After the checksum overflow fix (root commit `5ba2672`, was `ed349be` in the old `VCamIOS` repo). Will be replaced with VCP tests. |

---

## By SRS section

### §3 Architecture

| ID | Status | Evidence / gap |
|---|---|---|
| ARC-001 | Partial | Extension + PyO3 crate `native/vcam-py` (`src/lib.rs:7-18`, maturin config in `pyproject.toml`) bundled as a wheel (`BlenderAddOn/blender_manifest.toml:15-18`). macOS arm64 wheel only; per-platform wheels come with CI in 0.1.5. |
| ARC-002 | Partial | Crates split as required (`native/Cargo.toml:3-9`). `vcam-protocol` is `#![forbid(unsafe_code)]` (`native/vcam-protocol/src/lib.rs:4`). Skeleton only; no protocol, net, or encoder code yet. |
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
| FR-UX-001/002 | Not started | Manual host/port entry only (`TrackingSettings.swift`). |
| FR-UX-003/004 | Not started | Portrait `Form` UI (`ContentView.swift`). |
| Pose maths | Replace | `TrackingPose.swift` uses an aerospace Euler extraction on ARKit's Y-up frame. Replace with DM-002 quaternion conversion. |
| Project settings | Partial | Deployment target iOS 26.4; `SWIFT_VERSION = 5.0`; the camera usage string contains zero-width spaces (U+200B). |

### §5 Blender extension

| ID | Status | Evidence / gap |
|---|---|---|
| FR-BL-001 | Partial | `blender_version_min = "5.2.0"`, `network` permission, `wheels` and `platforms` (`BlenderAddOn/blender_manifest.toml:9,15-18`); builds and installs on macOS arm64. Still missing `windows-x64` and `linux-x64` wheels (0.1.5). |
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
| DM-001..004 | Not started | |
| PR-001..006 | Not started | |
| PR-FD-001 | Replace | Non-standard FreeD in `BlenderAddOn/core/freed_parser.py`, `VCamIOS/VCamIOS/FreeDPacketEncoder.swift`, `legacy/DesktopReceiver/src/protocol/FreeDParser.cpp`. |
| PR-FD-002, PR-OTIO-001 | Not started | Optional, T4. |

### §7 Cross-platform

| ID | Status | Evidence / gap |
|---|---|---|
| XP-001 | Partial | `.github/workflows/ci.yml` jobs `wheels` (manylinux 2_28, Windows, macOS arm64) and `extension` (`--split-platforms`, manifest listing written by `tools/set_manifest_wheels.py`). Rehearsed locally on macOS with stand-in wheels. Not yet run on GitHub. |
| XP-002 | Partial | `ci.yml` job `blender-smoke` installs the platform zip and runs `tests/blender/smoke_native.py` on 3 OSes. Only the macOS path has run (locally). Not yet run on GitHub. |
| XP-003..006 | Not started | |

### §8–§10

| ID | Status | Evidence / gap |
|---|---|---|
| NET-001 | Not started | |
| NET-002 | Partial | UDP, newest sample wins (Python client). |
| NET-003/004 | Not started | |
| NET-VID-* | Not started | S-2a/b (SRS §13.2): Stage A JPEG 540p q80 encodes in about 1 ms at 9–13 Mbit/s @ 30 fps. Stage B VideoToolbox H.264 720p low-latency is 3.6 ms median / 5.6 ms p95 submit-to-output (macOS). Production encoder code comes in Phases 2–3. |
| LNS-* | Not started | |
| NFR-LAT-*, NFR-PERF-* | Not started | No latency measurements. Render/readback costs are measured by S-1 (SRS §13.1). |
| NFR-REL-*, NFR-SEC-* | Not started | Any host can send poses; no pairing. |
| NFR-QA-001 | Partial | One git repo. `xcodebuild test`, `cargo test` (in `native/`), and a headless Blender smoke test (`tests/blender/smoke_native.py`) all run. There's no single `blender --background … tests` runner for add-on logic yet. |
| NFR-QA-002 | Partial | `ci.yml` covers fmt, clippy (`-D warnings`), and test on 3 OSes; Python tests; headless Blender on 3 OSes; iOS unit tests. Missing: `cargo fuzz` (no targets until 1.1.3). Not yet run on GitHub. |
| NFR-QA-003 | Not started | |
| NFR-QA-004 | Partial | Enforced by workspace lints: `unsafe_code` deny plus `clippy::undocumented_unsafe_blocks` deny (`native/Cargo.toml:22-32`). Checked with a throwaway probe: clippy rejected an uncommented `unsafe` block. |

---

## Next milestone

**Phase 0 exit:** single repo; `DesktopReceiver/` moved to `legacy/`; Rust workspace with a PyO3 module importing inside Blender 5.2 on all three OSes via CI; spikes S-1 (render/readback), S-2 (encoders), and S-3 (macOS loading) answered.
