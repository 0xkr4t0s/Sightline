# Software Requirements Specification — VCam for Blender

| Field | Value |
|---|---|
| Document version | 3.0 |
| Date | 2026-09-24 |
| Supersedes | v2.0 (same day, withdrawn: it wrongly assumed a system virtual webcam and iPhone→desktop video) and `Software Requirements Specification (SRS) .pdf` (v1, April 2026) |
| Status | Draft for owner review |
| Companion documents | `docs/IMPLEMENTATION_PLAN.md`, `IMPLEMENTATION_PROGRESS.md` |

---

## 0. How to read this document

Each requirement has:

- a **stable ID** (`FR-VF-003`, `NFR-LAT-002`, …) so code, tests, and the progress tracker can reference it;
- a **priority**: `MUST` (required for its tier), `SHOULD` (expected, can slip a tier), or `MAY` (optional);
- a **release tier**: `T1`–`T4` (defined in §2.4);
- a way to **verify** it (§11).

Items marked **[SPIKE]** depend on behaviour that hasn't been proven yet. They must be validated before the dependent work is scheduled.

---

## 1. Introduction

### 1.1 Purpose

**VCam for Blender** turns an iPhone or iPad into a handheld **virtual camera** for Blender:

1. The operator holds the iPhone like a camera. ARKit tracks its 6DOF pose.
2. The pose drives a camera in the Blender scene in real time.
3. Blender renders the view from that camera and **streams it back to the iPhone**, which shows it full screen as the **virtual viewfinder**.
4. The operator frames, focuses, zooms, and records takes from the iPhone. Takes become keyframed camera animation in Blender.

The iPhone's own camera image is used only for tracking. It is not the product's video.

### 1.2 Scope

In scope:

- **iOS/iPadOS app** (`VCamIOS/`, Swift): tracking, viewfinder display, operator controls.
- **Blender extension** (`BlenderAddOn/`, Python + a bundled **Rust** native module): receives tracking, drives the camera, renders and encodes the viewfinder stream, records takes. It runs wherever Blender runs: **Windows, Linux, macOS**.
- The network protocol between them.

Out of scope (see §12): a system-wide virtual webcam for Zoom/OBS and so on; iPhone→desktop video; genlock/cinema-camera sync hardware; Unreal and other engines (optional export only, T4).

### 1.3 Definitions

| Term | Meaning |
|---|---|
| Pose | Position (metres) + orientation (unit quaternion) at a timestamp |
| Canonical pose | The shared pose representation (§6.1) |
| Viewfinder stream | Video rendered by Blender from the tracked camera and sent to the iPhone |
| Motion-to-photon (M2P) | Time from the iPhone moving to the iPhone showing a frame rendered from that new pose |
| Native module | The Rust library compiled as a Python extension module and bundled in the Blender extension |
| Take | One recording of camera motion (and lens changes) saved to a Blender action |
| T1–T4 | Release tiers (§2.4) |

### 1.4 References

- Apple: ARKit, Network framework (`NetworkConnection`, `NetworkBrowser`), VideoToolbox, Metal, AVFoundation (`AVSampleBufferDisplayLayer`)
- Blender 5.2 LTS Python API: `gpu` module (`GPUOffScreen`, `draw_view3d`), `bpy.app.timers`, the Extensions platform (bundled wheels, `platforms`, `permissions`)
- Rust: PyO3 + maturin (Python extension modules), `mdns-sd`-class DNS-SD crates, H.264 encoder options (§8.3)
- ITU-T H.264; RFC 6184 (RTP payload for H.264) as a design reference
- FreeD D1 and SMPTE RIS-OSVP OpenTrackIO (optional T4 export only)

---

## 2. Overall description

### 2.1 Product perspective

```
┌──────────────────────────────┐                       ┌──────────────────────────────────────────┐
│ VCamIOS (iPhone / iPad)      │  pose + controls  UDP │ Blender (Windows / Linux / macOS)        │
│                              │ ────────────────────▶ │  ┌──────────────────────────────────┐    │
│  ARKit 6DOF tracking         │                       │  │ Rust native module (in extension)│    │
│  Operator controls           │  viewfinder video     │  │  net threads · protocol · codec  │    │
│  Viewfinder display (Metal)  │ ◀──────────────────── │  └──────────────▲───────────────────┘    │
│  HUD: guides, lens, status   │  (H.264 / JPEG, UDP)  │                 │ frames / poses         │
│                              │                       │  Python add-on: apply pose to camera,    │
│                              │ ◀── control/status ─▶ │  offscreen-render camera view, takes, UI │
└──────────────────────────────┘      (TCP)            └──────────────────────────────────────────┘
```

No separate desktop application exists. The Rust module runs inside Blender's process and does the work that shouldn't happen in Python or on Blender's main thread: networking, packet parsing, clock sync, and video encoding.

### 2.2 Users

| User | Needs |
|---|---|
| Previs / layout artist | Walk the set with a camera in hand and see Blender's view live; record takes quickly. |
| Animator / indie filmmaker | Natural handheld camera motion without keyframing by hand; lens and focus control. |
| Director / DP | Frame shots in a CG set on a familiar device with framing guides. |

### 2.3 Operating environment (September 2026)

| Component | Minimum | Current target | Notes |
|---|---|---|---|
| iOS / iPadOS | 26.0 | 27.x | ARKit world tracking device. LiDAR recommended. |
| Blender | 5.2 LTS | 5.2.x | Python 3.13. Installed as an Extension. |
| Desktop OS | Whatever Blender 5.2 supports | Windows 11 x64, Linux x64 (glibc), macOS arm64 | The native module ships per-platform wheels. Windows arm64 is SHOULD. |
| Xcode / Swift | Xcode 26 / Swift 6 | Xcode 27 | Swift 6 language mode. |
| Rust | Stable (edition 2024) | — | PyO3 + maturin; `abi3` or `cp313` wheels. |
| Network | Same LAN / Wi-Fi subnet | 5 GHz / 6 GHz Wi-Fi, or wired Ethernet for the desktop | |

### 2.4 Release tiers

| Tier | Name | Outcome |
|---|---|---|
| **T1** | Tracking | iPhone pose drives a Blender camera on Windows, Linux, and macOS through the Rust module, with discovery and pairing, origin/scale controls, and correct coordinate conversion. The iPhone shows status, not video. |
| **T2** | Virtual viewfinder | Blender streams the tracked camera's view to the iPhone. The viewfinder has framing guides and lens controls (focal length, tap-to-focus, aperture). Motion-to-photon is measured and within budget. |
| **T3** | Production | Take recording to keyframes with timeline playback, smoothing, locomotion (joystick/scale), camera bookmarks, hardware-accelerated encoding on all three OSes, and a take browser on the iPhone. |
| **T4** | Extras | Optional FreeD/OpenTrackIO export for other tools, AR passthrough composite, iPad director monitor, OSC/remote triggers, multiple iPhones. |

### 2.5 Key design constraints

- **C-1 Licensing.** A Blender extension is GPL-3.0-or-later. The bundled Rust module is distributed with it and SHALL use a GPL-compatible licence (GPL-3.0-or-later, or MIT/Apache-2.0). The iOS app is a separate program that talks over the network and MAY stay proprietary. It SHALL NOT include GPL code.
- **C-2 Blender threading.** `bpy`, `gpu`, and scene data may only be touched on Blender's main thread. The Rust module SHALL run all networking and encoding on its own threads, release the GIL while working, and exchange data with Python only through bounded, non-blocking queues.
- **C-3 One install.** Users SHALL install one Blender extension (with native wheels for their platform) and one iOS app. There is no separate desktop program, driver, or system extension.
- **C-4 Local-network permission.** iOS requires `NSLocalNetworkUsageDescription` + `NSBonjourServices`. On macOS, the local-network prompt is attributed to Blender. On Windows, the first listening socket triggers a firewall prompt. The UX SHALL explain each of these.
- **C-5 Frame readback is the bottleneck.** Getting rendered pixels from Blender's GPU context to the CPU for encoding costs time on the main thread. **[SPIKE S-1]** decides the achievable resolution and frame rate (§8.2).

---

## 3. System architecture requirements

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| ARC-001 | MUST | T1 | The desktop side SHALL be one Blender extension: a Python package (UI, operators, `bpy` glue) plus a Rust crate compiled with PyO3/maturin to a native module, bundled as per-platform wheels declared in `blender_manifest.toml`. |
| ARC-002 | MUST | T1 | The Rust workspace SHALL separate `vcam-protocol` (pure, no I/O: message types, encode/decode, coordinate conversions), `vcam-net` (sockets, discovery, pairing, clock sync), `vcam-video` (encoders), and `vcam-py` (the PyO3 bindings). `vcam-protocol` SHALL have no platform-specific code. |
| ARC-003 | MUST | T1 | All pose data SHALL pass through the canonical pose type (§6.1). Blender axis conventions SHALL live only in one Python/Rust conversion function. |
| ARC-004 | MUST | T1 | Every pose SHALL carry the iPhone's capture timestamp and a sequence number end to end. Every viewfinder frame SHALL carry the sequence number of the pose it was rendered from (enables exact M2P measurement, NFR-LAT-003). |
| ARC-005 | MUST | T1 | The iOS app SHALL use Swift 6 strict concurrency. ARKit callbacks, network I/O, and video decode SHALL run off the main actor. |
| ARC-006 | MUST | T1 | The existing C++ `DesktopReceiver/` and its CMIO camera extension SHALL be retired. Any logic worth keeping (parsers, tests, the test-pattern generator) SHALL be ported to Rust first. |
| ARC-007 | MAY | T3 | `vcam-protocol` MAY also be compiled for iOS (UniFFI/XCFramework) so both ends share one implementation. This requires `vcam-protocol` to be MIT/Apache-2.0 (C-1). Until then, Swift and Rust implementations SHALL share golden test vectors (NFR-QA-003). |

---

## 4. iOS application (`VCamIOS`)

### 4.1 Tracking

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-TRK-001 | MUST | T1 | Run `ARWorldTrackingConfiguration` with `worldAlignment = .gravity`, and emit one pose per `ARFrame` (typically 60 Hz), stamped with `ARFrame.timestamp` and a sequence number. |
| FR-TRK-002 | MUST | T1 | Send tracking state (normal, limited with reason, unavailable) with every pose, and show it in the UI. Blender SHALL hold the last good pose while tracking is limited, if the user chooses that. |
| FR-TRK-003 | MUST | T1 | **Set origin**: re-zero position and yaw on demand, without restarting the session. |
| FR-TRK-004 | SHOULD | T1 | Enable LiDAR scene reconstruction and plane detection when supported, for stability. |
| FR-TRK-005 | MUST | T1 | Stop sending when the app leaves the foreground, and show that it has stopped. |
| FR-TRK-006 | SHOULD | T2 | Image-marker relocalisation to snap the origin to a printed marker. |
| FR-TRK-007 | MAY | T3 | Save and restore an `ARWorldMap` per location for repeatable origins. |
| FR-TRK-008 | SHOULD | T1 | Don't render the ARKit camera feed. The session runs headless. (Showing it is the T4 AR passthrough feature, §2.4.) |

### 4.2 Virtual viewfinder display

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-VF-001 | MUST | T2 | Receive the viewfinder stream (§8.3), decode it with hardware (VideoToolbox for H.264; ImageIO/VideoToolbox for JPEG), and present it full screen in a Metal view with aspect-correct letterboxing. |
| FR-VF-002 | MUST | T2 | Present the newest decoded frame at once. Never queue frames for smooth playback: latency beats smoothness. |
| FR-VF-003 | MUST | T2 | Framing overlays drawn on the iPhone (not burnt in by Blender): aspect masks (2.39, 2.00, 1.85, 1.78, 1.33, custom), rule-of-thirds, centre cross, action/title safe, and a horizon level from the pose roll. |
| FR-VF-004 | MUST | T2 | HUD: focal length, focus distance, f-stop, recording state and timer, stream fps/bitrate, M2P latency, tracking state, and connection quality. |
| FR-VF-005 | MUST | T2 | Frame-loss and stale-video indicator: if no new frame arrives for more than 250 ms, show a clear "video stalled" overlay. Tracking continues regardless. |
| FR-VF-006 | SHOULD | T3 | Exposure aids on the received image: false colour and zebras (useful for judging the CG lighting). |
| FR-VF-007 | MAY | T3 | Apply a `.cube` 3D LUT to the displayed stream (for example, a show look). |

### 4.3 Operator controls (iPhone → Blender)

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-CTL-001 | MUST | T2 | **Focal length**: slider, pinch, and preset primes (for example, 18/24/35/50/85/135 mm). Blender applies them to the camera's `lens`. |
| FR-CTL-002 | MUST | T2 | **Tap-to-focus**: the iPhone sends normalised screen coordinates, Blender ray-casts from the camera, and sets `dof.focus_distance` (or a focus object). Include a manual focus wheel and A/B focus marks with a timed rack. |
| FR-CTL-003 | SHOULD | T2 | **Aperture** (`dof.aperture_fstop`) and DoF on/off. |
| FR-CTL-004 | MUST | T1 | **Motion scale** (for example, 1:1, 1:2, 1:10, custom) and **axis locks** (lock height, lock roll, pan-only). |
| FR-CTL-005 | SHOULD | T3 | **Locomotion**: on-screen joysticks move the rig's origin (truck/dolly/crane/yaw), so the operator can cover large sets while standing still. |
| FR-CTL-006 | MUST | T3 | **Record / stop take**, **play / pause / scrub** the Blender timeline, and **choose camera** (from the scene's camera objects). |
| FR-CTL-007 | SHOULD | T3 | **Bookmarks**: save and recall rig origins by name. |
| FR-CTL-008 | SHOULD | T2 | Hardware inputs: the Camera Control button (record/focus) and volume buttons (record) where available, and game controllers (`GameController` framework) for joystick locomotion. |
| FR-CTL-009 | MUST | T2 | Every control change SHALL be sent as an idempotent state message (not a relative delta), so a lost packet can't leave the two ends out of sync. |

### 4.4 Discovery, pairing, and session UX

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-UX-001 | MUST | T1 | Discover Blender sessions over Bonjour (`NetworkBrowser`) and list them by machine and `.blend` file name. Manual host entry SHALL remain. |
| FR-UX-002 | MUST | T1 | Pair on first connect with a 6-digit code shown in Blender's N-panel (or a QR code). Remember paired hosts. |
| FR-UX-003 | MUST | T1 | Landscape-first, one-handed layout. Controls SHALL auto-hide and never cover the centre of the frame. |
| FR-UX-004 | MUST | T1 | Show thermal state, and reduce stream resolution or fps automatically on `.serious` thermal state. |

---

## 5. Blender extension

### 5.1 Tracking and camera

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-BL-001 | MUST | T1 | Package as a Blender 5.2 extension (`blender_version_min = "5.2.0"`) with per-platform wheels (`windows-x64`, `linux-x64`, `macos-arm64`; `windows-arm64` SHOULD) and the `network` permission. |
| FR-BL-002 | MUST | T1 | The native module owns the sockets and threads. Python pulls the **latest** pose on the main thread (from a `bpy.app.timers` callback or modal operator at ≥ 60 Hz). No `bpy` calls happen off the main thread. |
| FR-BL-003 | MUST | T1 | Apply pose to a **rig**: `VCam_Origin` (empty: position, yaw, scale for locomotion and motion scale) → the tracked camera (local transform = incoming pose). Users place the rig in their scene. Incoming data is never edited. |
| FR-BL-004 | MUST | T1 | N-panel: session on/off, pairing code, connected device, pose rate, loss, latency, tracking state, camera selection, and origin/scale/lock settings. |
| FR-BL-005 | MUST | T2 | Apply operator controls (FR-CTL-*) to the active VCam camera's data (`lens`, `dof.*`, `sensor_width`), with changes visible in the next streamed frame. |
| FR-BL-006 | SHOULD | T1 | Optional smoothing (One-Euro filter or critically damped spring) applied in the native module, with a per-session toggle. Raw data is always kept for recording. |
| FR-BL-007 | MUST | T1 | Behave correctly across `.blend` reloads, undo, and the camera being deleted or renamed: detect it, show a warning, and never crash. |

### 5.2 Viewfinder rendering

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-REN-001 | MUST | T2 | Render the VCam camera's view **offscreen** (`gpu.types.GPUOffScreen` + `draw_view3d` with the camera's view and projection matrices), independent of what the user's own 3D viewports show. |
| FR-REN-002 | MUST | T2 | Selectable shading for the stream: Solid, Material Preview, Rendered (EEVEE). Selectable stream resolution (for example, 640×360, 960×540, 1280×720, 1920×1080) and fps cap (24/30/60). |
| FR-REN-003 | MUST | T2 | Read back pixels and hand them to the native module with at most one copy on the Python side. Encoding SHALL happen off the main thread in Rust. **[SPIKE S-1]** |
| FR-REN-004 | MUST | T2 | Stream rendering SHALL NOT make Blender's UI unusable: cap the main-thread cost per frame (configurable budget, default 12 ms), and skip frames rather than block. |
| FR-REN-005 | SHOULD | T2 | Colour management: the stream SHALL match what Blender's viewport shows (view transform and look applied), tagged sRGB/Rec.709. |
| FR-REN-006 | SHOULD | T3 | Overlays burnt in by choice: camera passepartout/safe areas from Blender, and an option to hide gizmos and helpers. |
| FR-REN-007 | MAY | T4 | Stream while Blender plays the timeline, so the operator can "film" animated scenes (T3 covers recording; this covers smooth playback rendering under load). |

### 5.3 Takes

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| FR-TAKE-001 | MUST | T3 | Record a take: while recording, keep every raw pose and control state with capture time. On stop, bake to a new action on the camera (and camera data for lens/focus) at scene fps, resampled by capture time, not arrival time. |
| FR-TAKE-002 | MUST | T3 | Optionally start timeline playback at record start, so camera motion lines up with existing animation. |
| FR-TAKE-003 | MUST | T3 | Take list in the N-panel and on the iPhone: name, duration, and keep / discard / rename, plus assign to the camera or a new camera. |
| FR-TAKE-004 | SHOULD | T3 | Save raw take data (JSON Lines) next to the `.blend` for re-baking with different smoothing. |
| FR-TAKE-005 | SHOULD | T3 | Post-take smoothing and keyframe reduction (optional) that preserve the raw take. |

---

## 6. Data model and protocol

### 6.1 Canonical pose and coordinates

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| DM-001 | MUST | T1 | Canonical pose = `{ seq: u32, capture_time_ns: u64 (iPhone monotonic), position_m: [f32;3], orientation: quat [f32;4], tracking_state: u8, flags: u8 }`. |
| DM-002 | MUST | T1 | Canonical axes = Blender's: **right-handed, Z-up, metres**, with the camera looking down its local −Z and local +Y up. The ARKit (Y-up) → canonical conversion SHALL happen once, on the iPhone. Blender then applies canonical poses directly. |
| DM-003 | MUST | T1 | No Euler angles anywhere in the pipeline, except the display of pan/tilt/roll in UIs and optional FreeD export (T4). |
| DM-004 | MUST | T1 | Conversions SHALL be covered by golden vectors in `testdata/coords/` (identity; ±90° pan, tilt, roll; combined; translated) used by both the Swift and Rust test suites. |

### 6.2 Native protocol ("VCP")

Both ends belong to this project, so VCP replaces FreeD as the primary protocol. FreeD has no timestamp, sequence number, quaternion, lens data, or control messages.

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| PR-001 | MUST | T1 | Binary, little-endian, versioned. Every datagram starts with `magic "VCP1"`, `version: u8`, `type: u8`, `session_id: u32`, and `len: u16`. Unknown types and versions SHALL be ignored without error. |
| PR-002 | MUST | T1 | Message types (minimum): `POSE` (DM-001 + optional intrinsics), `CONTROL_STATE` (lens, focus, aperture, scale, locks, record, transport; full state per FR-CTL-009), `HEARTBEAT`/`CLOCK` (NTP-style four-timestamp offset exchange), `VIDEO_FRAGMENT` (§8.3), `STATUS` (Blender → iPhone: camera name, fps, take state, errors), `ACK_KEYFRAME_REQ` (iPhone asks for a video keyframe). |
| PR-003 | MUST | T1 | Channels: **UDP** for `POSE`, `CONTROL_STATE`, `CLOCK`, and `VIDEO_FRAGMENT`. **TCP** for pairing, session setup, take-list operations, and file-like transfers. |
| PR-004 | MUST | T1 | The protocol SHALL be specified in `docs/protocol/vcp.md` with byte layouts and example hex, and covered by golden vectors in `testdata/vcp/`. |
| PR-005 | MUST | T1 | Parsers SHALL reject oversized or truncated messages and never panic (Rust: no `unwrap` on network data; fuzzed with `cargo fuzz`). |
| PR-006 | MUST | T1 | Every UDP message after pairing SHALL carry a truncated HMAC (for example, HMAC-SHA256/64) under the session key. Unauthenticated messages SHALL be dropped. |

### 6.3 Legacy FreeD code

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| PR-FD-001 | MUST | T1 | The current FreeD path (iPhone → Blender) SHALL be replaced by VCP. The existing codecs use a non-standard layout (pan/tilt swapped, X/Z swapped, invented lens offset) and SHALL NOT be ported as-is. |
| PR-FD-002 | MAY | T4 | Optional FreeD export from the Blender extension, for other tools, SHALL use the standard D1 layout: pan@2, tilt@5, roll@8, X@11, Y@14, Z@17 (s24 BE; degrees × 32768, mm × 64), zoom@20, focus@23 (raw u24, no offset), checksum `(0x40 − Σ bytes[0..27]) mod 256`. It SHALL be verified against an independent reference decoder. |
| PR-OTIO-001 | MAY | T4 | Optional OpenTrackIO export (validated against the SMPTE `camdkit` schema). |

---

## 7. Cross-platform build and distribution

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| XP-001 | MUST | T1 | CI SHALL build the native wheels for `windows-x64`, `linux-x64` (manylinux), and `macos-arm64`, and assemble the extension zip with `blender --command extension build --split-platforms` (or the equivalent). |
| XP-002 | MUST | T1 | CI SHALL run the extension's integration test headless on all three OSes: `blender --background --factory-startup --python tests/…`. |
| XP-003 | MUST | T1 | The native module SHALL have no runtime dependencies beyond the OS and Blender's Python (static linking, or vendored inside the wheel). |
| XP-004 | MUST | T1 | macOS wheels SHALL be code-signed (and the extension notarization-compatible) so Gatekeeper doesn't block the `.so`/`.dylib` loading inside Blender. **[SPIKE S-3]** |
| XP-005 | SHOULD | T1 | Publish to a Blender extensions repository (self-hosted JSON index, or extensions.blender.org if the licence and policy fit), so Blender can auto-update. |
| XP-006 | MUST | T1 | The iOS app SHALL be distributed through TestFlight and the App Store (proprietary or permissive licence, no GPL code; C-1). |

---

## 8. Networking and video

### 8.1 Transport and discovery

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NET-001 | MUST | T1 | While a session is active, the native module SHALL advertise `_vcam._udp` / `_vcam-ctl._tcp` over DNS-SD with a TXT record (protocol version, `.blend` name, ports), on all three OSes (a pure-Rust mDNS implementation, so there's no dependency on Bonjour for Windows or Avahi). |
| NET-002 | MUST | T1 | Pose traffic: one datagram per pose, never retransmitted. The receiver always uses the newest (highest seq) sample. |
| NET-003 | MUST | T1 | Clock sync over `CLOCK` messages at 1 Hz, reporting offset and jitter, so Blender can map iPhone capture times onto its own clock. |
| NET-004 | MUST | T1 | Survive Wi-Fi roaming, sleep, the app backgrounding, and Blender reloading its file. Reconnect within 3 s of the network returning, with no re-pairing. |

### 8.2 Frame capture in Blender **[SPIKE S-1]**

The spike SHALL measure, on each OS with a mid-range GPU, the main-thread cost of `draw_view3d` + readback (`texture_color.read()` or an equivalent) at 540p, 720p, and 1080p in Solid, Material Preview, and EEVEE. It SHALL also establish:

- whether a `gpu.types.Buffer` can be handed to Rust through the buffer protocol without a copy;
- whether `draw_view3d` needs a visible 3D-view region, and how to render when none is open;
- the achievable fps for each combination.

The results set the default stream resolution and fps, and are recorded in §13.

### 8.3 Viewfinder video stream

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NET-VID-001 | MUST | T2 | **Stage A (simplest, first):** per-frame JPEG (quality adjustable), fragmented into `VIDEO_FRAGMENT` datagrams. The iPhone drops any frame that is still incomplete when a newer one starts. Target: 960×540 @ 30 fps within ~15–25 Mbit/s on 5 GHz Wi-Fi. |
| NET-VID-002 | MUST | T3 | **Stage B:** H.264 (Baseline/Main, no B-frames, periodic intra refresh or short GOP, low-latency rate control), sent with the same fragmentation plus a keyframe request (`ACK_KEYFRAME_REQ`) on loss. Target: 1280×720 @ 30–60 fps at 4–10 Mbit/s. |
| NET-VID-003 | MUST | T3 | Encoder backends per OS, behind one Rust trait: VideoToolbox (macOS), Media Foundation H.264 MFT (Windows), and VA-API (Linux, when available). A software fallback (for example, OpenH264) SHALL be selectable when no hardware encoder is available. Check H.264 patent licensing before distributing a software encoder binary. **[SPIKE S-2]** |
| NET-VID-004 | MUST | T2 | Every frame SHALL carry `frame_id`, `render_time_ns` (Blender clock), and `pose_seq` (ARC-004). |
| NET-VID-005 | SHOULD | T2 | Adaptive quality: lower JPEG quality or H.264 bitrate, then resolution, on sustained fragment loss or rising M2P. Report changes in both UIs. |
| NET-VID-006 | MAY | T4 | Wired option: iPhone over USB-C Ethernet adapter on the same LAN (no code change; document it as the lowest-latency setup). |

---

## 9. Lens model

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| LNS-001 | MUST | T2 | The lens is **virtual** and owned by Blender's camera data. The iPhone controls it (FR-CTL-001..003) and displays it. The iPhone's physical lens is not used. |
| LNS-002 | MUST | T2 | Sensor size presets on the Blender side (for example, Super 35, Full Frame, ARRI Alexa 35 Open Gate, and custom) set `sensor_width` and `sensor_fit`. The iPhone shows the matching FOV and equivalent focal length. |
| LNS-003 | SHOULD | T2 | The stream aspect ratio follows the scene's render resolution aspect, so framing matches final renders. |

---

## 10. Non-functional requirements

### 10.1 Latency and performance

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NFR-LAT-001 | MUST | T1 | **Pose leg**: `ARFrame` callback → pose applied to the Blender camera, p95 ≤ 20 ms on 5 GHz Wi-Fi (≤ 8 ms wired desktop, iPhone on Wi-Fi). Main-thread apply cost ≤ 1 ms. |
| NFR-LAT-002 | MUST | T1 | **Send leg on iPhone**: `ARFrame` → datagram handed to the OS, p95 ≤ 2 ms, with no allocation per pose. |
| NFR-LAT-003 | MUST | T2 | **Motion-to-photon**, measured on the iPhone as (frame displayed) − (capture time of `pose_seq`): p95 ≤ 120 ms at 960×540 JPEG on Stage A; p95 ≤ 80 ms at 720p H.264 on Stage B (T3); goal ≤ 60 ms. |
| NFR-LAT-004 | MUST | T2 | A latency harness SHALL log the pose leg, render/readback, encode, network, decode, and display as p50/p95/p99, and write a report artefact (`reports/latency-<date>.json`). |
| NFR-PERF-001 | MUST | T2 | The iPhone SHALL sustain 60 Hz tracking + 30 fps stream decode for 60 minutes without reaching `.serious` thermal state on iPhone 15 Pro at room temperature. |
| NFR-PERF-002 | MUST | T2 | With streaming at default settings on the reference machine, Blender's UI SHALL stay responsive (the main thread never blocks > 50 ms because of VCam). |

### 10.2 Reliability

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NFR-REL-001 | MUST | T1 | Malformed input never crashes Blender or the app. The native module SHALL catch panics at the FFI boundary and turn them into Python exceptions and status messages. |
| NFR-REL-002 | MUST | T1 | Disabling the extension or closing Blender SHALL stop all threads and close all sockets within 1 s. Re-enabling it SHALL work without restarting Blender. |
| NFR-REL-003 | SHOULD | T2 | A 2-hour soak with 2 % induced loss and 10 ms jitter: no leaks, no crashes, bounded latency. |

### 10.3 Security and privacy

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NFR-SEC-001 | MUST | T1 | Only paired devices can drive the camera or receive the stream (PR-006). Pairing keys are stored in the Keychain (iOS) and the Blender user config directory (desktop). |
| NFR-SEC-002 | SHOULD | T3 | Encrypt the video stream (for example, ChaCha20-Poly1305 per fragment) for use on shared networks. |
| NFR-SEC-003 | MUST | T1 | Listen only while a session is active. No analytics. Camera permission is requested for ARKit only, with a clear usage string. |

### 10.4 Quality and maintainability

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NFR-QA-001 | MUST | T1 | One git repository, one command per component: `cargo test`, `xcodebuild test`, and `blender --background … tests`. |
| NFR-QA-002 | MUST | T1 | CI on each change: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, `cargo fuzz` (time-boxed), Python tests, headless Blender tests on 3 OSes, and iOS unit tests. |
| NFR-QA-003 | MUST | T1 | `testdata/` holds golden vectors (VCP messages, coordinate conversions, fragment reassembly) consumed by the Rust, Swift, and Python tests. |
| NFR-QA-004 | MUST | T1 | Rust code has no `unsafe` outside the FFI/encoder-backend modules, and every `unsafe` block has a `// SAFETY:` comment. |

### 10.5 Usability

| ID | Priority | Tier | Requirement |
|---|---|---|---|
| NFR-UX-001 | MUST | T1 | From installing the extension and the app to a moving Blender camera in under 5 minutes, without typing an IP address. |
| NFR-UX-002 | MUST | T2 | Viewfinder controls usable one-handed in landscape. High-contrast HUD. Liquid Glass-era iOS 26 styling that never tints the image area. |

---

## 11. Verification

| Area | Method |
|---|---|
| Protocol and conversions | Golden vectors in Rust, Swift, and Python; `cargo fuzz` on every parser |
| Blender integration | Headless Blender tests on 3 OSes: a fake iPhone (Rust test binary) sends poses and controls; the test asserts on `matrix_world`, `lens`, and `dof`, and on received video frames (decoded and checked for size and non-blankness) |
| Rendering | Spike S-1 benchmark script kept as `tests/bench_render.py`; results committed per release |
| Latency | In-app harness (NFR-LAT-004); an on-device M2P overlay |
| Soak | Automated fake-iPhone soak with impairment (`tc netem` on Linux CI) |
| Device | Manual checklist per release: pairing, tracking, viewfinder, controls, takes, thermal |

---

## 12. Out of scope (with rationale)

| Item | Why |
|---|---|
| System-wide virtual webcam (CMIO extension, MF virtual camera, v4l2loopback) | Not needed: the only consumer is Blender, and the video goes to the iPhone. |
| iPhone → desktop video, Apple Log, LUT capture, iPhone recording | The iPhone camera is a tracking sensor only. |
| Genlock, external timecode, Blackmagic ProDock, PTP, SMPTE ST 2110 | Needed for syncing with physical cinema cameras and LED walls, which this product doesn't do. May be revisited for T4 AR passthrough. |
| NDI, WebRTC | The stream is point-to-point on a LAN. A custom UDP stream is simpler and lower latency. WebRTC may come back if remote (WAN) use is ever needed. |
| Unreal, disguise, and other engines | Optional export only (PR-FD-002, PR-OTIO-001). |
| Standalone C++ desktop receiver | Replaced by the Rust module inside the extension (ARC-006). |

---

## 13. Open questions and spikes

| ID | Question | Blocking |
|---|---|---|
| S-1 | Blender offscreen render + readback cost per resolution, shading mode, and OS; zero-copy hand-off to Rust; rendering without a visible 3D view | FR-REN-001..004, NFR-LAT-003 |
| S-2 | Encoder choice per OS: hardware availability and latency; OpenH264 vs. a platform encoder; H.264 licensing for the software fallback | NET-VID-002/003 |
| S-3 | Loading a signed native module from a Blender extension on macOS (Gatekeeper/quarantine behaviour for downloaded extensions), and Windows SmartScreen | XP-004 |
| S-4 | Wi-Fi jitter for 60 Hz pose up + 30 fps video down on typical home and studio routers | NFR-LAT-001/003 |
| S-5 | Licence choice: GPL-3.0-or-later for the whole extension, vs. MIT/Apache for `vcam-protocol` (which enables ARC-007 sharing with iOS) | ARC-007, C-1 |

### 13.1 S-1 results — 2026-09-24 (macOS headless; partial)

Setup: Blender 5.2.2 LTS, `--background` with `gpu.init()` (Metal), Apple M4 Pro. Default scene plus 25 subdivided Suzannes (393,612 evaluated triangles). Overlays off, `do_color_management=True`. The camera pans 0.2° per frame so EEVEE can't reuse accumulated samples. 60 timed frames after 5 warm-up frames. Script: `tests/bench_render.py`. Raw data: `reports/s1-render-2026-09-24-macos-arm64.json`.

Main-thread cost in ms, median/p95. `draw` = `draw_view3d`; `read` = `texture_color.read()`, which blocks until the GPU finishes. `deferred read` = `read()` called 40 ms after the draw (20 frames).

| Shading | Res | draw | read | draw + read | deferred read |
|---|---|---|---|---|---|
| Solid | 960×540 | 1.3/3.5 | 4.0/6.6 | 5.5/9.9 | 1.3/1.7 |
| Solid | 1280×720 | 1.8/4.5 | 10.6/41.6 | 13.3/44.3 | 1.4/2.0 |
| Solid | 1920×1080 | 1.3/1.4 | 13.3/18.5 | 14.6/19.8 | 2.1/3.0 |
| Material | 960×540 | 6.9/12.6 | 41.8/53.1 | 48.7/65.7 | 3.1/3.7 |
| Material | 1280×720 | 9.6/14.1 | 62.9/74.6 | 72.8/83.5 | 18.6/38.7 |
| Material | 1920×1080 | 12.3/17.0 | 119.2/129.3 | 131.4/142.1 | 55.2/58.3 |
| EEVEE | 960×540 | 76.2/119.1 | 2.9/6.4 | 79.1/122.0 | 4.3/7.4 |
| EEVEE | 1280×720 | 103.5/154.8 | 4.6/8.5 | 108.9/163.3 | 5.3/9.6 |
| EEVEE | 1920×1080 | 181.2/234.7 | 9.7/14.3 | 192.4/248.4 | 10.9/16.3 |

An earlier run of the same script gave Solid 540p draw + read 8.6/17.9 ms (p95 included a warm-up outlier) and otherwise the same picture. The first frame of each mode includes shader compilation: 722 ms Solid, 279 ms Material, 167 ms EEVEE.

Findings:

- **No visible 3D view needed.** `draw_view3d` works in `--background` after `gpu.init()`. It uses a `SpaceView3D` and its `WINDOW` region taken from the current screen's data; nothing is shown. Not yet tested: a screen with no `VIEW_3D` area at all.
- **Zero-copy works; one copy is cheap.** `texture_color.read()` returns a `gpu.types.Buffer` that exposes the buffer protocol as C-contiguous `uint8` (H, W, 4), rows bottom-up. `vcam_native._frame_probe` (PyO3 `PyBuffer<u8>::as_slice`) reads all 2.07 MB at 540p in place in 0.06 ms. A full memcpy costs 0.06 ms at 540p and 0.24 ms at 1080p. Recommended hand-off for FR-REN-003: Rust copies once into its own buffer (`PyBuffer::copy_to_slice`) while holding the GIL, then releases the GIL and encodes on a worker thread. Holding Blender's buffer across threads would need `unsafe` and gains < 0.3 ms.
- **`read()` is mostly GPU wait, and deferring it hides that wait.** Drawing on one timer tick and reading on the next cuts Solid to ≤ 3 ms total and Material 540p to about 10 ms (draw 6.9 + read 3.1). The `gpu` module has no fence or async-read API (`GPUTexture` exposes only `read`), so deferral is the only way to overlap. It adds one tick of latency.
- **EEVEE's cost is in `draw_view3d` itself** (76 ms median at 540p), so it can't be deferred or time-sliced.

Proposed defaults (to confirm after the UI run and the other OSes): 960×540, Solid, 30 fps, deferred read (main thread about 3 ms per frame). Material Preview at 540p looks feasible at about 20 fps with deferral (GPU about 40–45 ms per frame).

**Conflict flagged (not resolved here):** FR-REN-002 makes EEVEE a selectable stream mode, but on this machine a single EEVEE `draw_view3d` blocks the main thread for 76 ms median at 540p. That breaks FR-REN-004's 12 ms default budget and NFR-PERF-002's 50 ms limit, and frame skipping can't help because one frame already exceeds both. Material 720p/1080p also breaks the 12 ms budget. The owner must decide: exempt EEVEE (and heavy Material) from these limits with a UI warning, require lighter EEVEE settings (untested), or drop EEVEE streaming from T2.

Still open for S-1: the same benchmark inside the Blender UI with a timer (a visible viewport also competes for the GPU), and Windows and Linux on mid-range GPUs.

---

## Appendix A — What changed

### A.1 From v1 (PDF) to v3

| v1 | v3 |
|---|---|
| iOS cinematography viewfinder of the *iPhone's* camera (Log, LUTs, waveform) | The viewfinder shows **Blender's** render, streamed to the iPhone |
| Cross-platform C++ desktop "virtual camera driver" (CMIO, V4L2, DirectShow/MF) | No OS virtual camera. A Rust module inside the Blender extension provides the cross-platform part. |
| FreeD / Live Link as primary protocols | A native versioned protocol (VCP). FreeD/OpenTrackIO become optional exports. |
| Genlock, timecode, PTP, ST 2110, NDI, WebRTC, Wi-Fi Aware | Out of scope (§12) |
| FreeD table with pan/tilt and X/Z swapped, invented lens offset | Documented correctly for optional export (PR-FD-002). Legacy code is replaced, not ported. |
| "< 5 ms tracking-to-engine" with no definition | Per-leg budgets plus measured motion-to-photon (§10.1) |

### A.2 From v2 to v3 (same day)

v2 assumed the product needed a system virtual webcam and iPhone→desktop video. The owner clarified that the only consumer is Blender and that video flows **Blender → iPhone**. The CMIO extension, the Windows/Linux webcam backends, iPhone video capture and colour work, genlock, and timecode were removed. Rust inside the Blender extension replaced the separate C++ receiver.
