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
| Blender extension (`BlenderAddOn/`) | Partial | Background UDP thread + main-thread apply works. FreeD/JSON parsing in Python must be replaced by the Rust module. Manifest pins 5.1. |
| Rust native module | Not started | No `native/` workspace yet. Rust 1.97.1 is installed; maturin 1.15.0 is in `.venv.nosync/`. |
| Viewfinder stream (Blender → iPhone) | Not started | — |
| C++ `legacy/DesktopReceiver/` (incl. CMIO extension) | Retire | Moved to `legacy/` in task 0.1.2 (ARC-006). Port the parsers, their tests, and the test-pattern generator to Rust, then delete the directory. |
| Repo / CI | Partial | One git repo at the root (task 0.1.1). `VCamIOS` history imported under `VCamIOS/` (commits `ae4d81c`, `984145a`, `5ba2672`). No CI. |

**Maturity:** early prototype. All of Phase 0 is open.

**Environment on the owner's Mac (2026-09-24):** Blender 5.2.2 LTS at `/Applications/Blender.app`; cargo/rustc 1.97.1; `.venv.nosync/` with pytest + maturin; Xcode 27.0 (via `DEVELOPER_DIR`) with the iOS 27.0 simulator.

## Last verified test runs (2026-09-24)

| Suite | Result | Note |
|---|---|---|
| Legacy C++ (`legacy/DesktopReceiver`) | 9/9 pass (fresh temp build dir) | Re-run after the move to `legacy/`. To be retired. The stale in-repo `build/` was deleted. |
| `BlenderAddOn/tests` (pytest, `.venv.nosync`) | 12/12 pass | Tests the non-standard FreeD layout; the code will be replaced. |
| VCamIOS `FreeDPacketEncoderTests` (iPhone 17 Pro sim, iOS 27.0) | 5/5 pass | After the checksum overflow fix (root commit `5ba2672`, was `ed349be` in the old `VCamIOS` repo). Will be replaced with VCP tests. |

---

## By SRS section

### §3 Architecture

| ID | Status | Evidence / gap |
|---|---|---|
| ARC-001 | Partial | `BlenderAddOn/blender_manifest.toml` exists (extension format); no wheels or native module. |
| ARC-002 | Not started | |
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
| FR-BL-001 | Partial | Manifest has `blender_version_min = "5.1.0"` and the `network` permission; no wheels/platforms. |
| FR-BL-002 | Partial | Latest-sample semantics and main-thread apply are done in Python (`core/udp_client.py`, `operators/tracking_receiver.py`). Sockets must move into the Rust module. |
| FR-BL-003 | Partial | Drives a chosen camera directly; no `VCam_Origin` rig; Euler rotation (`core/transform.py`). |
| FR-BL-004 | Partial | N-panel with connection settings and status (`ui/panels.py`); no pairing or stats. |
| FR-BL-005 | Partial | Lens/focus mapped from FreeD zoom/focus encoders; to be replaced by `CONTROL_STATE`. |
| FR-BL-006/007 | Not started | |
| FR-REN-* | Not started | |
| FR-TAKE-* | Not started | |
| UI text | Replace | `operators/tracking_receiver.py:23` mentions "Live Link". |

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
| XP-001..006 | Not started | |

### §8–§10

| ID | Status | Evidence / gap |
|---|---|---|
| NET-001 | Not started | |
| NET-002 | Partial | UDP, newest sample wins (Python client). |
| NET-003/004 | Not started | |
| NET-VID-* | Not started | |
| LNS-* | Not started | |
| NFR-LAT-*, NFR-PERF-* | Not started | No measurements. |
| NFR-REL-*, NFR-SEC-* | Not started | Any host can send poses; no pairing. |
| NFR-QA-001 | Partial | One git repo: root `.git` with `VCamIOS` history, `.gitignore` at `.gitignore:1-33`. `xcodebuild test` works. `cargo test` (0.1.3) and headless Blender tests (0.1.4) don't exist yet. |
| NFR-QA-002..004 | Not started | |

---

## Next milestone

**Phase 0 exit:** single repo; `DesktopReceiver/` moved to `legacy/`; Rust workspace with a PyO3 module importing inside Blender 5.2 on all three OSes via CI; spikes S-1 (render/readback), S-2 (encoders), and S-3 (macOS loading) answered.
