# Implementation Plan

| Field | Value |
|---|---|
| Version | 3.0 |
| Date | 2026-09-24 |
| Implements | `docs/SRS.md` v3.0 |
| Current status | `IMPLEMENTATION_PROGRESS.md` |

Phase 0 sets up the new architecture (Rust inside the Blender extension) and answers the risky questions. Each later phase delivers one SRS tier. Each phase has an exit gate. Work that doesn't move a gate forward waits.

## Target repository layout

```
VCamBlender/
├── AGENTS.md
├── IMPLEMENTATION_PROGRESS.md
├── docs/                    SRS, plan, protocol spec (docs/protocol/vcp.md), loop prompt/log
├── testdata/                golden vectors shared by Rust, Swift and Python
│   ├── vcp/  coords/  video/
├── native/                  Rust workspace
│   ├── Cargo.toml
│   ├── vcam-protocol/       pure: messages, codec, conversions (no I/O)
│   ├── vcam-net/            sockets, mDNS, pairing, clock sync, fragment reassembly
│   ├── vcam-video/          JPEG + H.264 encoders behind one trait
│   ├── vcam-py/             PyO3 bindings → Python module `vcam_native`
│   ├── vcam-fake-iphone/    test binary that behaves like the iOS app
│   └── fuzz/
├── BlenderAddOn/            Blender extension (Python), wheels/ filled by CI
├── VCamIOS/                 Xcode project (Swift)
├── legacy/                  (temporary) DesktopReceiver/ until ported, then deleted
└── .github/workflows/
```

---

## Phase 0 — New foundation and spikes

**Goal:** the repo matches the new architecture, CI builds Rust + Blender + iOS on three OSes, and the rendering, encoding, and macOS-loading questions have answers.

### 0.1 Repository

| # | Task | SRS |
|---|---|---|
| 0.1.1 | Make the project root a git repo. Import `VCamIOS/.git` history (back it up first). Add `.gitignore` for `target/`, `build/`, `DerivedData/`, `xcuserdata/`, `.DS_Store`, `.omx/`, `wheels/*.whl`. | NFR-QA-001 |
| 0.1.2 | Move `DesktopReceiver/` to `legacy/DesktopReceiver/` with a README saying it's being retired (ARC-006). Delete the stale `DesktopReceiver/build/`. | ARC-006 |
| 0.1.3 | Create the Rust workspace skeleton (`native/`) with the crates above, `rust-toolchain.toml` (stable), `clippy`/`rustfmt` config, and one passing test per crate. | ARC-002 |
| 0.1.4 | `vcam-py`: a minimal PyO3 module (`vcam_native.version()`), built with maturin for Python 3.13. Blender extension manifest updated (`blender_version_min = "5.2.0"`, `wheels = [...]`, `platforms`). Prove `import vcam_native` works inside Blender 5.2 on macOS. | ARC-001, FR-BL-001 |
| 0.1.5 | CI (GitHub Actions, matrix windows/ubuntu/macos): cargo fmt/clippy/test → maturin wheels → `blender --command extension build --split-platforms` → headless Blender smoke test (installs Blender per OS). Also a macOS job for `xcodebuild test`. | XP-001/002, NFR-QA-002 |
| 0.1.6 | Remove the "Live Link" wording from `BlenderAddOn/operators/tracking_receiver.py:23`. | — |

### 0.2 Spikes (time-boxed; results go into SRS §13)

| Spike | Work | Output |
|---|---|---|
| **S-1 Render + readback** | `tests/bench_render.py`: build a `GPUOffScreen`, run `draw_view3d` from a camera's matrices, read back the colour texture, and time each step at 540p/720p/1080p × Solid/Material/EEVEE. Try handing the buffer to `vcam_native` without a copy. Test with no visible 3D view. Run it headless where possible, and in the UI with a timer. | Default stream res/fps; the zero-copy method; any need for a visible viewport |
| **S-2 Encoders** | In `vcam-video`: JPEG (`turbojpeg` or a pure-Rust encoder) timing at 540p/720p; H.264 prototypes via VideoToolbox (macOS, `objc2-video-toolbox`), MF (Windows, `windows` crate), OpenH264 fallback. Measure encode latency, and look at licensing. | Encoder matrix, fallback choice |
| **S-3 macOS loading** | Download the built extension zip (quarantined), install it in Blender, and check that the native `.so` loads. Try with and without signing and notarization. | Signing/notarization recipe |

**Exit gate P0:** CI is green on 3 OSes. A Blender 5.2 extension with the Rust module installs and imports on all three. The S-1, S-2, and S-3 decision records are merged.

---

## Phase 1 — T1 Tracking

**Goal:** from install to a moving Blender camera in under 5 minutes, on Windows, Linux, and macOS, over the native protocol, with discovery and pairing.

### 1.1 Protocol (Rust + Swift)

| # | Task | SRS |
|---|---|---|
| 1.1.1 | Write `docs/protocol/vcp.md`: header, `POSE`, `CONTROL_STATE` (T1 subset: scale, locks, origin reset), `CLOCK`, `STATUS`, plus the pairing handshake over TCP and the HMAC trailer. | PR-001..004, PR-006 |
| 1.1.2 | `testdata/vcp/*.bin` + `*.json` golden vectors; `testdata/coords/*.json` ARKit→canonical vectors. | NFR-QA-003, DM-004 |
| 1.1.3 | `vcam-protocol`: types, encode/decode, HMAC, conversions. Tests use the golden vectors. Add fuzz targets. | DM-001..003, PR-005 |
| 1.1.4 | Swift `VCP` module in VCamIOS: encoder/decoder plus the ARKit→canonical conversion. XCTests use the same golden vectors (add `testdata/` as a folder reference to the test bundle). | DM-002, DM-004 |

### 1.2 Rust networking (`vcam-net`, exposed through `vcam-py`)

| # | Task | SRS |
|---|---|---|
| 1.2.1 | UDP receiver thread with latest-sample slot (atomic swap), per-source stats (rate, loss from seq, age). | NET-002, FR-BL-004 |
| 1.2.2 | TCP control server: pairing (6-digit code → session key via a PAKE or HKDF over the code and nonces; document the choice), session setup, and `STATUS` push. | FR-UX-002, NFR-SEC-001 |
| 1.2.3 | mDNS advertising (pure Rust) of `_vcam._udp` / `_vcam-ctl._tcp` with a TXT record. | NET-001 |
| 1.2.4 | `CLOCK` offset/jitter estimation. | NET-003 |
| 1.2.5 | Python API: `Session.start(port)`, `.latest_pose()`, `.stats()`, `.pairing_code()`, `.stop()`. Release the GIL; convert panics to exceptions; clean shutdown on unregister. | C-2, NFR-REL-001/002 |
| 1.2.6 | Optional One-Euro smoothing in Rust. | FR-BL-006 |
| 1.2.7 | `vcam-fake-iphone` binary: pairs, then streams scripted motion (pan, tilt, dolly, crane) from `testdata/`. | §11 |

### 1.3 Blender extension

| # | Task | SRS |
|---|---|---|
| 1.3.1 | Replace `core/udp_client.py` + `core/freed_parser.py` with `vcam_native`. Delete the FreeD path (keep its tests only as history in git). | PR-FD-001, FR-BL-002 |
| 1.3.2 | Rig: create or find `VCam_Origin` + the camera. Apply the canonical pose (quaternion) as the camera's local transform. Motion scale and axis locks on the origin/apply step. | FR-BL-003, FR-CTL-004 |
| 1.3.3 | N-panel: session toggle, pairing code, device, stats, camera picker, origin reset, scale/locks. | FR-BL-004 |
| 1.3.4 | Robustness: file reload (`load_post` handler), undo, camera deleted. | FR-BL-007 |
| 1.3.5 | Headless integration test with the fake iPhone: assert on `matrix_world` for each scripted keypose. Runs in CI on 3 OSes. | XP-002 |

### 1.4 iOS app

| # | Task | SRS |
|---|---|---|
| 1.4.1 | Swift 6 language mode. Replace `ObservableObject` with `@Observable`. Move the ARKit delegate + send path onto a dedicated actor/queue, with UI updates at ≤ 15 Hz. Remove the zero-width spaces in `NSCameraUsageDescription`. | ARC-005 |
| 1.4.2 | Replace `FreeDPacketEncoder`/`TrackingPose` Euler code with VCP `POSE` (seq, capture time, quaternion, state). | FR-TRK-001/002, PR-FD-001 |
| 1.4.3 | Discovery (`NetworkBrowser`), pairing UI, Keychain storage, `NSLocalNetworkUsageDescription`, `NSBonjourServices`. | FR-UX-001/002, C-4 |
| 1.4.4 | Origin reset, scale/locks UI (sent as `CONTROL_STATE`). LiDAR/plane detection when available. | FR-TRK-003/004, FR-CTL-004 |
| 1.4.5 | Landscape status screen (no video yet): tracking state, rate, connection, thermal. | FR-UX-003/004 |

### 1.5 Measurement

| # | Task | SRS |
|---|---|---|
| 1.5.1 | Pose-leg latency: the iPhone capture time is mapped through `CLOCK` offset to Blender's clock at apply time. Log histograms and write a report artefact. | NFR-LAT-001/002 |

**Exit gate T1:**
- The fake-iPhone headless test passes on Windows, Linux, and macOS CI.
- On a real iPhone, discovery → pairing → moving camera works in under 5 minutes on each OS (manual checklist).
- The pose-leg p95 meets NFR-LAT-001.
- The fuzzers have run clean.

---

## Phase 2 — T2 Virtual viewfinder

**Goal:** the operator sees Blender's camera view on the iPhone and controls the lens from it.

| Workstream | Tasks | SRS |
|---|---|---|
| **2.1 Offscreen render** | Per the S-1 result: a timer-driven renderer draws the VCam camera to a `GPUOffScreen` at the chosen res/fps/shading, reads back, and hands the buffer to Rust. Main-thread budget with frame skipping. Colour management matches the viewport. | FR-REN-001..005, NFR-PERF-002 |
| **2.2 Stage A video** | `vcam-video` JPEG encode on a worker thread. `vcam-net` fragmentation into `VIDEO_FRAGMENT` with `frame_id`, `render_time_ns`, `pose_seq`. Adaptive quality. Golden vectors for fragment reassembly. | NET-VID-001/004/005 |
| **2.3 iOS viewfinder** | Reassembly (drop stale), JPEG decode, Metal presentation of the newest frame; stall indicator; framing overlays; HUD. | FR-VF-001..005 |
| **2.4 Lens controls** | Focal length (slider, pinch, primes), tap-to-focus (Blender ray cast), focus wheel + A/B rack, aperture. Sensor presets in Blender. Idempotent `CONTROL_STATE`. | FR-CTL-001..003/009, FR-BL-005, LNS-001..003 |
| **2.5 Hardware inputs** | Camera Control button and volume buttons; game-controller joystick groundwork. | FR-CTL-008 |
| **2.6 M2P harness** | Measure on the iPhone using `pose_seq` → capture time. Break down all legs; add an on-screen overlay and a report artefact. | NFR-LAT-003/004 |
| **2.7 Soak + thermal** | Fake-iPhone soak with `tc netem` on Linux CI; a 60-minute device thermal run. | NFR-REL-003, NFR-PERF-001 |

**Exit gate T2:** 960×540 @ 30 fps viewfinder at M2P p95 ≤ 120 ms on 5 GHz Wi-Fi on all three OSes; lens and tap-to-focus controls work; Blender UI stays responsive; thermal run passes.

---

## Phase 3 — T3 Production

| Workstream | Tasks | SRS |
|---|---|---|
| **3.1 Takes** | Raw take buffer in Rust; bake to an action at scene fps by capture time; optional timeline playback on record; take list (Blender + iPhone); raw JSONL sidecar; re-bake with smoothing. | FR-TAKE-001..005 |
| **3.2 Transport controls** | Record/stop, play/pause/scrub, camera selection from iPhone. | FR-CTL-006 |
| **3.3 Locomotion + bookmarks** | Joysticks and game controller drive `VCam_Origin`; named bookmarks. | FR-CTL-005/007 |
| **3.4 Stage B video** | H.264 per the S-2 decision: VideoToolbox / MF / VA-API behind a trait, software fallback; keyframe request on loss; VideoToolbox decode on iOS. | NET-VID-002/003 |
| **3.5 Viewfinder extras** | False colour, zebras, optional `.cube` LUT on display; burnt-in Blender overlays option. | FR-VF-006/007, FR-REN-006 |
| **3.6 Stream encryption** | Per-fragment AEAD. | NFR-SEC-002 |
| **3.7 Distribution** | Signed/notarized macOS wheels, extension repository JSON for auto-update, TestFlight → App Store. | XP-004..006 |

**Exit gate T3:** a 2-minute handheld take records while the animated scene plays, bakes to a clean action, and matches the viewfinder; 720p H.264 M2P p95 ≤ 80 ms; public beta builds for all 3 desktop OSes plus TestFlight.

---

## Phase 4 — T4 Extras (pick by demand)

- Optional FreeD export (standard layout, reference-decoder test) and OpenTrackIO export (`camdkit` validation). PR-FD-002, PR-OTIO-001
- AR passthrough: composite Blender's render over the iPhone camera feed (needs an alpha or depth stream). SRS §2.4 T4
- iPad director monitor (a second receiver of the same stream)
- OSC triggers; multiple iPhones driving multiple cameras
- Shared Rust `vcam-protocol` on iOS through UniFFI (ARC-007, once S-5 settles the licence)

---

## README media (runs alongside the phases)

`README.md` shows placeholder SVGs in `docs/media/`. Each task below replaces one placeholder with the real asset and updates the `<img src>` next to its `TODO(M.x)` comment. When the last reference to a placeholder SVG is gone, delete it. A media task starts only once the feature it shows works. It never counts towards an exit gate and never delays gate work.

**Rules for every asset:**
- Store it in `docs/media/`. GIFs are at most 960 px wide, 12–15 fps and 3 MB (8 MB for `hero.gif`), and loop seamlessly. PNGs are 2× captures, optimised, at most 1 MB. Keep each clip at 10 s or less.
- Make GIFs with `ffmpeg` in two passes (`palettegen`, then `paletteuse` with dither `sierra2_4a`). `ffmpeg` is already installed; don't install other tools. Put the capture scripts in `tools/media/`, so every asset can be made again.
- Use the demo scene `tools/media/demo_scene.py` (from M.0): a lit, textured set with a clear subject and the factory theme. No personal file paths, machine names or network details in a frame. Set the host name to `Sightline Demo`.
- Commit only the final assets. Raw captures stay out of git.

| # | Asset | What it shows | How it's made | Needs | After |
|---|---|---|---|---|---|
| M.0 | `tools/media/demo_scene.py` | A scripted demo `.blend`: a small set, a subject and a Sightline rig | Headless Blender script | Loop | 1.3.2 ✅ |
| M.1 | `tracking.gif` | The Blender viewport with the Sightline camera and its view following the scripted motion | Fake iPhone streams `testdata/motion/scripted.bin` into a GUI Blender run. A timer script saves viewport frames (`bpy.ops.screen.screenshot_area` or an offscreen draw), then `ffmpeg` joins them | Loop | M.0 |
| M.2 | `pairing.png`, `blender-panel.png` | The N-panel showing the pairing code, then streaming (device, rate, latency, rig) | The same GUI run as M.1, with area screenshots at the pairing and streaming stages | Loop | M.0 |
| M.3 | `ios-app.png` | The landscape status screen with the control rail and Settings host list | `xcrun simctl io booted screenshot` on the iPhone 17 Pro simulator, driven by a UI test that opens each screen | Loop | 1.4.5 ✅ |
| M.4 | `viewfinder.gif` | Blender's render on the phone, following the camera | Simulator first (fake pose + real stream); a device recording replaces it later | Loop (simulator), owner (device) | 2.3 |
| M.5 | `hero.gif` | Split screen: a hand moving the iPhone, the Blender window following, and the phone's viewfinder | Owner films the phone and records the screen at the same time. The loop syncs, crops and joins the clips with `ffmpeg` (`hstack`) using `tools/media/make_hero.sh` | **Owner** (filming) | T1 device check for a tracking-only version; redo after 2.3 |
| M.6 | `lens-controls.gif` | Pinch zoom, tap-to-focus and a focus pull | Device screen recording (Control Centre) | **Owner** | 2.4 |
| M.7 | `takes.gif` | Record a take, then scrub the baked action in the Dope Sheet | GUI Blender with the fake iPhone, captured as in M.1 | Loop | 3.1 |
| M.8 | `logo.svg` | Project logo for the README header and the extension | Owner chooses; the loop can offer SVG drafts | **Owner** (decision) | — |

In the log, owner-only steps are `BLOCKED (needs owner)`. For M.5 and M.6, the loop writes a shot list in the PR (clip length, framing, what to do on screen), so the owner only has to film.

---

## Immediate next steps

1. **0.1.1** Single git repo (back up `VCamIOS/.git` first) and a baseline commit.
2. **0.1.2** Move `DesktopReceiver/` to `legacy/`.
3. **0.1.3 → 0.1.4** Rust workspace and a PyO3 module importing inside Blender 5.2 (installed at `/Applications/Blender.app`).
4. **S-1** Render/readback benchmark. It decides how Phase 2 is built.
5. **0.1.5** CI on three OSes.
6. **1.1.1 → 1.1.3** VCP spec, golden vectors, Rust codec.

---

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Offscreen readback too slow for a usable stream | Medium | T2 quality | Spike S-1 first; lower default res; async PBO-style readback if the `gpu` module allows; frame skipping |
| Wi-Fi jitter/loss makes the viewfinder choppy | Medium | UX | Newest-frame-wins; adaptive quality; recommend 5/6 GHz or wired desktop; H.264 intra refresh |
| Native module blocked by Gatekeeper/SmartScreen | Medium | Install UX | Spike S-3; sign wheels; document first-run steps |
| H.264 software-encoder licensing | Medium | T3 distribution | Prefer OS hardware encoders; legal check before shipping OpenH264 |
| Blender Python API changes in 5.x → 6.0 | Medium | Rework | Pin 5.2 LTS; keep `bpy`/`gpu` usage in a thin layer; CI against the next Blender beta |
| GPL boundary mistakes with the iOS app | Low | Legal | No GPL code in iOS; share only test vectors, or MIT/Apache crates (S-5) |
| ~~iCloud Drive sync corrupts `target/` or `.git`~~ | Closed 2026-09-24 | — | `~/iCloud Drive (Archive)` is a local, non-synced folder (macOS's archive copy), so the repo isn't in iCloud. No remote backup exists yet; the owner should add a private remote. |
