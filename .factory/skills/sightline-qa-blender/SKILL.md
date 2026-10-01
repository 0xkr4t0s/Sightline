---
name: sightline-qa-blender
description: Exercise the Sightline Blender extension like a user, without hardware. Start a long-running headless Blender host, pair and stream from the fake iPhone, change settings, and check camera motion, panel text, logs and the streamed frame. Use to validate or reproduce anything user-visible on the Blender side (session, pairing, tracking, rig controls, N-panel, rendering, video stream). Not for iOS screens (use sightline-qa-ios) or unit tests (tools/mission/check.sh).
---

# Sightline QA: Blender host

The harness runs the real extension, installed in an isolated Blender user directory, inside
headless Blender. It polls the session the way Blender's timer does in the GUI. Everything is
exposed as files so you can drive the host and inspect it between steps.

## Prepare

1. `tools/mission/setup.sh` once per checkout, and again after any change under `BlenderAddOn/`
   or `native/`. The harness runs the *installed* copy, so a stale install tests old code.
2. `tools/mission/qa_blender.sh status` must say no host is running before `start`. Stop any
   leftover host first.

## Drive

```bash
tools/mission/qa_blender.sh start                    # 127.0.0.1:47000, streaming on; prints host.json
tools/mission/qa_blender.sh drive --linger 10        # fake iPhone: pairs if needed, sends scripted motion, receives video
tools/mission/qa_blender.sh state                    # snapshot: session, camera, rig, controls, latency, video, panel labels
tools/mission/qa_blender.sh cmd '{"cmd":"set","prop":"stream_resolution","value":"720p"}'
tools/mission/qa_blender.sh cmd '{"cmd":"render_png","path":".mission/qa/render.png"}'
tools/mission/qa_blender.sh logs host 80
tools/mission/qa_blender.sh stop                     # always stop when done; it frees the port
```

- `start` options: `--port`, `--bind` (keep loopback), `--blend FILE`, `--no-video`, `--no-pairing`.
- `drive` passes extra flags through to `vcam-fake-iphone` (the last value of a repeated flag
  wins). The flags are documented at the top of `native/vcam-fake-iphone/src/main.rs`:
  `--scale S`, `--locks FLAGS`, `--set-origin-at FRAME`, `--limited FROM-TO`, `--m2p MS`,
  `--thermal N`, `--thermal-at FRAME[:N]`, `--rate HZ`, `--linger S` and `--name NAME`, plus the
  lens flags `--lens MM`, `--focus M`, `--fstop F`, `--dof 0|1`, `--tap U,V[@FRAME]` and
  `--rack A,B,TARGET,MS[@FRAME]` (TARGET A or B; tap/rack default to frame 60, after a baseline
  sequence 0 in the first state).
- To inspect a device that is still connected, run `drive` with a long `--linger` in the
  background, then poll `state` while it runs.
- Commands: `ping`, `state`, `pair`, `cancel_pair`, `set` (any `vcam_props` scene property, or
  `target_camera`), `set_render` (scene `resolution_x`/`resolution_y`/`pixel_aspect_x`/
  `pixel_aspect_y`; the stream frame follows the render aspect inside the size box, and
  `state.json` `render.aspect` shows it), `set_origin`, `clear_origin`, `render_png` (the stream's
  fitted size), `latency_report` (the Save Latency Report operator for the current or last device
  session, default `.mission/qa/latency-host.json`: pose, apply, render/readback, encode, send and
  the device's M2P, format 2), `save_blend`, `open_blend`, `stop`.
  `eval` runs Python with `bpy` on the main thread. It's an escape hatch: prefer the named
  commands and the user-facing operators so you test what users can do. The full reference is
  at the top of `tools/mission/qa_host.py`.
- A pairing code works once and lasts 5 minutes. After it's used, `host.json` shows
  `pairing_code: null`. Send `{"cmd":"pair"}` for a new one. The fake iPhone reuses
  `.mission/qa/fake-iphone.key` until `setup.sh` resets the Blender user directory.

## Check (evidence to collect)

- `state.json`:
  - `session.device_name`, `session.tracking_state`, `session.applied_seq` (it should rise).
  - `camera.matrix_world` (it should change with the motion and follow `origin`).
  - `controls`.
  - `video.sent`, and `video.last_sent` (size, quality).
  - `panel.labels`: the N-panel's text, drawn by the real panel code, and `panel.operators` with
    their enabled state.
  - `errors` must be empty.
- `.mission/qa/fake-iphone-frame.jpg`: the newest frame the "phone" received. Open it with the
  Read tool and confirm it shows the scene from the driven camera. `render_png` gives the
  host-side image for comparison.
- `FAKE_IPHONE_DONE` line from `drive`: `video_frames`, `video_lost`, `applied_pose_seq`, `control_ack`,
  and the applied lens from STATUS: `applied_lens=1 lens_mm= focus_m= fstop= dof= sensor_width_mm=
  sensor_fit= aspect= hfov_deg= equiv_mm=` (`hfov_deg`/`equiv_mm` are `unavailable` unless the
  camera's sensor fit is horizontal; `applied_lens=0` when STATUS had no lens block).
- `state.json` `controls` also has the newest native lens keys (`lens_mm`, `focus_distance_m`,
  `fstop`, `dof_on`, `tap_*`, `rack_*`), and `camera` has `sensor_fit`, `dof_use`,
  `focus_distance` and `fstop`.
- Logs are in `.mission/logs/`:
  - `qa-host.log`: the add-on logger, redacted.
  - `qa-blender-stdout.log`: Blender's own output, not redacted.
  - `qa-fake-iphone.log`.

Without `--blend`, `start` builds the QA scene (`--scene qa`, the default). It is set up so that
every scripted motion keeps content in view:
- `VCam_Origin` sits 1.2 m above a grey checkered floor, facing +Y. That is where the device's
  rest pose looks.
- 1.5 m ahead stands a totem of 7 stacked cubes: white, red, yellow, blue, green, orange and
  purple from the bottom.
- Around it is a ring of 12 coloured pillars 5 m out, lettered A (straight ahead, red) to L,
  anticlockwise, so B is to the left.
- The camera has a 24 mm lens and the sky is blue-grey.

What each motion shows:
- The fake iPhone's pan turns to C, D and E. Its tilt shows the floor and pillar bases, the dolly
  brings D closer, and the crane looks down on D.
- The iOS app's `orbit` keeps the totem centred while the pillars behind it change. Its `pan`
  sweeps between B/C and L/K with the totem at the edge.

Colours show in Solid and Material Preview. A plain sky-blue frame, or one that stays the same
while poses arrive, points to a problem.

Use `--scene factory` for Blender's grey factory cube, which scripted motion mostly leaves out of
view.

## Limits (say "not verified" rather than guessing)

- There is no Blender GUI, so check the panel through `panel.labels`, not screenshots.
  Behaviour that only exists in the GUI (timers, redraws, window events) isn't covered.
- `setup.sh` builds a debug `vcam_native`, so encoding is slower than a release build. Don't
  report frame rates or latency from this harness as product numbers.
- Real iPhone, ARKit, Wi-Fi, Bonjour on a LAN and signing are owner-only.
- Logs and state can contain device names and loopback addresses. Redact before pasting them
  anywhere public (AGENTS.md Privacy).
