---
name: sightline-qa-ios
description: Exercise the Sightline iOS app like a user in the iPhone 17 simulator. Run the real app in its simulator QA mode (scripted poses instead of ARKit), paired with the headless Blender QA host, then drive it with XCUITest and check screenshots, accessibility values, app logs and the Blender side's state. Use to validate or reproduce anything on the iPhone screen (status strip, controls, Settings, pairing, viewfinder, framing overlays, stall badge). Not for Blender-only behaviour (use sightline-qa-blender) or plain unit tests (tools/mission/check.sh ios).
---

# Sightline QA: iOS app in the simulator

ARKit doesn't run in the simulator. In simulator Debug builds, the launch arguments below swap
the ARKit pose source for a scripted 60 Hz one. Everything else is the real app: pairing,
sessions, reconnect, video decode, the Metal viewfinder and the overlays. The QA code is
compiled out of device and Release builds (`#if targetEnvironment(simulator) && DEBUG` in
`SightlineIOS/SightlineIOS/SimulatorQA.swift`).

## Prepare

1. A Blender host. See the sightline-qa-blender skill:
   `tools/mission/setup.sh` (once, and again after `BlenderAddOn/`/`native/` changes), then
   `tools/mission/qa_blender.sh start`.
2. `tools/mission/qa_ios.sh build` after any change under `SightlineIOS/`, then `qa_ios.sh boot`.

## Drive

Scripted run, with screenshots:

```bash
tools/mission/qa_ios.sh launch --motion orbit   # host + code from .mission/qa/host.json; auto-starts
tools/mission/qa_ios.sh screenshot              # .mission/qa/ios-<timestamp>.png, upright
tools/mission/qa_ios.sh logs 50                 # app log (os.Logger, subsystem kr8t0s.Sightline)
tools/mission/qa_blender.sh state               # the Blender side: applied_seq rising, camera moving
tools/mission/qa_ios.sh terminate
```

Taps and assertions (XCUITest):

```bash
tools/mission/qa_ios.sh uitest                  # SightlineIOSUITests, with the harness host/code passed in
tools/mission/qa_ios.sh uitest -only-testing:SightlineIOSUITests/SightlineUITests/testStreamsFromBlenderHost
```

- **Screenshots** the tests attach are copied to `.mission/qa/uitest-attachments/<test>/<name>.png`.
  Open them with the Read tool.
- **The result bundle** is at `.mission/xcresult/uitest`, with the xcodebuild output in
  `.mission/logs/qa-ios-uitest.log`.
- **New flows:** write a new test in `SightlineIOS/SightlineIOSUITests/SightlineUITests.swift`,
  modelled on the existing two. Find elements by accessibility identifier:
  - **Status strip:** `status.session`, `status.rate`, `status.connection`, `status.thermal`, `status.error`.
  - **Controls:** `control.startStop`, `control.origin`, `control.settings`.
  - **Viewfinder:** `viewfinder`. Its value is the frame size and the active guides, e.g.
    `960x540; mask 2.39:1, thirds, horizon`, or `No video`.
  - **Stall badge:** `video.stalled`.
  - **Settings:** `settings.*`, e.g. `settings.host`, `settings.port`, `settings.pairingCode`,
    `settings.pair`, `settings.session`, `settings.packetsSent`, `settings.setOrigin`,
    `settings.motionScale`, `settings.lockHeight`, `settings.framing.thirds`,
    `settings.framing.aspect`, `settings.controlStatus`, `settings.done`.

  Add an identifier to any new control you build.
- **Launch arguments**, through `qa_ios.sh launch` options or `-- ARGS`:

| Argument | Effect |
|---|---|
| `-SightlineQAHost 127.0.0.1:47000` | Use this manual address (Bonjour isn't needed). |
| `-SightlineQACode NNNNNN` | Pair if there's no stored pairing for that address. |
| `-SightlineQAMotion orbit\|pan\|still` | Scripted poses. Without it the app uses ARKit and shows "Unsupported". |
| `-SightlineQAAutoStart YES` | Start tracking on launch. |
| `-SightlineQAResetPairings YES` | Forget stored pairings. |
| `-SightlineQALimited FROM-TO` | Report limited tracking for those frames (tests the hold-last-good-pose path). |

- **Pairing code:** it's single-use and lasts 5 minutes. After it's used, `host.json` shows
  `pairing_code: null`, and the app keeps its pairing in the simulator's Keychain. For a fresh
  pairing, run `qa_blender.sh cmd '{"cmd":"pair"}'` and launch with `--reset-pairings`.
  `setup.sh` resets the Blender side's pairings, so re-pair after running it.
- **Settings stored in UserDefaults** (e.g. framing choices):
  `qa_ios.sh defaults read|write|delete`.

## Check (evidence to collect)

- The screenshots show the Blender render in the viewfinder, with the expected overlays and
  status text.
- The viewfinder's accessibility value names the frame size.
- There's no `video.stalled` badge while frames arrive.
- `qa_blender.sh state`: `session.device_name` is the simulator app, `applied_seq` rises,
  `camera.matrix_world` follows the motion, and `controls` reflect what was tapped (Origin bumps
  `origin_epoch`).
- `.mission/logs/qa-ios.log` shows session, pairing, tracking and video events, and no errors.

## Limits (say "not verified" rather than guessing)

- Scripted motion isn't ARKit. Tracking quality, LiDAR, camera permission, thermal behaviour,
  real Wi-Fi, Bonjour on a LAN and device performance are owner-only.
- The simulator's JPEG decode and Metal timings aren't device numbers.
- UI-test hierarchy dumps and local logs can contain the Mac's host name. Redact before pasting
  them anywhere (AGENTS.md Privacy).
