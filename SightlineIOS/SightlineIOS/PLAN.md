# VCamIOS v0.1 Tracking Sender

> **Status: implemented (April 2026) and superseded.** Current requirements are in `docs/SRS.md` (v3); iOS work is in `docs/IMPLEMENTATION_PLAN.md` §1.4.
> The FreeD output below is being replaced by the project's own protocol (VCP), and the FreeD layout it assumed was non-standard (SRS §6.3).

## Summary
Implement the first real iOS source node inside `VCamIOS` as a SwiftUI utility app that runs an `ARWorldTrackingConfiguration` session, converts device pose into FreeD D1 tracking packets, and sends those packets by UDP to the desktop receiver on port `7000` by default.

This v0.1 should be intentionally narrow:
- no camera preview UI
- no video transport
- no Live Link
- no LUT/exposure/viewfinder tools
- no timecode/genlock
- no direct Blender-first routing by default

The success criterion is a working end-to-end chain:
`VCamIOS ARKit pose -> FreeD UDP -> DesktopReceiver -> Blender add-on camera motion`

## Key Changes
### App architecture
- Keep the app as SwiftUI, but move logic out of `ContentView` into a small observable controller layer.
- Add a `TrackingSessionController` (or equivalent `ObservableObject`) that owns:
  - `ARSession`
  - permission/session state
  - host/port settings
  - current pose readout
  - start/stop tracking lifecycle
  - UDP sender instance
- Run ARKit without a rendered AR scene. Use a headless `ARSession` because v0.1 is a tracking utility, not a preview app.
- Stop tracking when the app goes inactive/backgrounded and surface that state in the UI.

### Tracking and packet pipeline
- Add a small pose model such as `TrackingPose` with:
  - timestamp
  - translation `x/y/z`
  - rotation `pitch/yaw/roll`
- Use `ARWorldTrackingConfiguration` with the default world-aligned session.
- On each AR frame update:
  - extract the `ARCamera.transform`
  - derive translation in meters
  - derive Euler angles in degrees
  - convert into the same FreeD D1 wire format expected by the existing Python/C++ parsers
- Add a `FreeDPacketEncoder` that:
  - writes the `0xD1` marker
  - encodes signed 24-bit pitch/yaw/roll and position fields
  - applies the same scale factors already used by the repo decoders
  - applies the `524288` lens offset for zoom/focus fields
  - computes the checksum exactly as the existing parsers expect
- Default zoom/focus to zeroed logical values for now, encoded compatibly with the current receiver expectations.
- Add a lightweight UDP sender that transmits one packet per AR frame to the configured host/port.

### UI and configuration
- Replace the placeholder `ContentView` with a compact operator utility screen showing:
  - destination host
  - destination port, default `7000`
  - start/stop button
  - AR session state
  - packets-sent count
  - latest XYZ and pitch/yaw/roll readout
  - last error / unsupported-device state
- Keep the UI simple and functional, not cinematic.
- Persist host/port using `UserDefaults` so the app remembers the desktop receiver destination.
- Add camera usage description via the generated Info.plist build settings so ARKit can run.
- Keep the app universal for the existing target family (`iPhone` and `iPad`) unless the current project settings are intentionally changed later.

### Public interfaces and additions
- New app-side types/interfaces to introduce:
  - `TrackingSessionController`: session lifecycle + app state
  - `TrackingPose`: normalized tracking data model
  - `FreeDPacketEncoder`: FreeD D1 binary encoder
  - `UDPSender`: UDP transport helper
  - small settings model for host/port persistence
- Important behavior contract:
  - default destination is `DesktopReceiver` on port `7000`
  - packets are valid FreeD D1 and should decode with the repo’s existing parsers without receiver changes
  - app emits tracking only when the session is actively running

## Test Plan
### Automated tests
- Add an XCTest target to `VCamIOS.xcodeproj`.
- Add unit tests for:
  - FreeD packet length is exactly `29` bytes
  - first byte is `0xD1`
  - checksum matches the existing repo checksum formula
  - zero pose encodes and decodes to expected neutral values
  - negative and positive rotations/positions encode correctly at the byte level
  - zoom/focus fields include the correct offset behavior
- If practical, add a tiny shared decode helper in tests only, or validate against known byte fixtures derived from the existing repo math.

### Manual validation
- Launch `DesktopReceiver` with default FreeD input port `7000`.
- Launch Blender add-on listening on the existing relay path.
- Start `VCamIOS` tracking and confirm moving/rotating the device moves the Blender camera.
- Verify start/stop behavior sends packets only while active.
- Verify app surfaces useful states for:
  - camera permission denied
  - ARKit unavailable/unsupported device
  - invalid destination input
  - session interruption or relocalization failure

### Acceptance criteria
- `VCamIOS` builds and runs from the generated Xcode project.
- The desktop receiver accepts packets with no protocol changes.
- Blender motion is visibly driven by live iOS movement through the existing relay chain.
- The app remains usable without any preview surface.

## Assumptions
- The project created by Xcode is the one to extend in `VCamIOS/`.
- v0.1 targets tracking only, not video or viewfinder features.
- The existing repo FreeD math and checksum behavior are the source of truth for compatibility.
- Destination defaults to the desktop receiver (`host` user-configured, `port 7000`).
- Lens metadata is deferred; zoom/focus stay placeholder-compatible for now.
- Because the project currently lacks a test target, part of the implementation work will include adding one to the Xcode project rather than deferring tests.
