# Mission: Sightline Phase 2 (T2 Virtual viewfinder), everything that doesn't need the owner's hardware

Paste this into `/missions` to start the Mission.

## Context
Sightline is an iPhone virtual camera for Blender. The iPhone's ARKit pose drives a Blender camera, and Blender streams that camera's view back to the iPhone as the viewfinder. Read these before planning:
- `AGENTS.md`: project rules, privacy rules, local checks and QA tools. Every worker follows it.
- `IMPLEMENTATION_PROGRESS.md`: status by requirement ID.
- `docs/IMPLEMENTATION_PLAN.md`, Phase 2 and "Immediate next steps".
- `docs/SRS.md` v3.0: open only the sections for the requirement IDs a feature cites.
- `docs/protocol/vcp.md` for any wire-format work.
- The last few entries of `docs/LOOP_LOG.md` for recent context. An earlier loop finished Phase 1 and Phase 2 up to task 2.3e2.

Phase 1 is done apart from owner-only device checks. Phase 2 tasks 2.1, 2.2 and 2.3a–2.3e2 are done.

## Goal
Finish every Phase 2 task that can be built and checked on this Mac without a physical iPhone. Work in plan order. Leave a clear list of the exit-gate items that only the owner can do.

## Scope, one milestone per workstream, in this order

### Milestone 1: task 2.3f, viewfinder HUD
Requirements: FR-VF-004, plus the rest of FR-UX-004.
- The HUD shows tracking state, connection quality, stream fps and bitrate, and the adaptive level (quality and size), all taken from data that already exists.
- Lens fields (focal length, focus distance, f-stop) are added in Milestone 2. M2P latency is added in Milestone 4. Recording state and timer belong to T3, so show them as not available.
- FR-UX-004: when iOS reports `.serious` thermal state, lower the stream's resolution or fps automatically. Tell the host through an idempotent message and show this in the HUD and in the Blender N-panel.

### Milestone 2: task 2.4, lens controls
Requirements: FR-CTL-001..003, FR-CTL-009, FR-BL-005, LNS-001..003.
1. Specify the T2 `CONTROL_STATE` lens fields in `vcp.md`. This closes the T2 part of open item O-4. Include focal length, focus distance or tap point, f-stop, DoF on/off and A/B rack. Every field is absolute state, never a delta.
2. Add golden vectors with `tools/gen_testdata.py`.
3. Implement the Rust codec in `vcam-protocol`, then `vcam-net`, then `vcam_native`.
4. Make the fake iPhone able to send each lens control.
5. In the add-on, apply the controls to the target camera's `lens` and `dof.*` values. Add sensor presets (Super 35, Full Frame, ARRI Alexa 35 Open Gate, custom) that set `sensor_width` and `sensor_fit`. Implement tap-to-focus as a ray cast from the camera on Blender's main thread. The stream aspect ratio follows the scene's render aspect (LNS-003).
6. STATUS reports the applied lens back to the device so it can display the actual values.
7. On iOS, add the Swift codec, checked against the same vectors. Add the UI: a focal-length slider, pinch and prime presets; tap-to-focus on the viewfinder; a focus wheel with A/B marks and a timed rack; aperture and DoF controls. Show FOV and equivalent focal length. Fill in the HUD lens fields.

### Milestone 3: task 2.5, hardware inputs
Requirement: FR-CTL-008.
- Camera Control button and volume buttons for record and focus, plus groundwork for `GameController` joystick input.
- The simulator can't press these buttons. Put the input handling behind testable seams, unit-test the mapping, and mark the device check as owner-only.

### Milestone 4: task 2.6, M2P harness
Requirements: NFR-LAT-003, NFR-LAT-004.
- On the device, measure M2P as (frame displayed) − (capture time of the frame's `pose_seq`).
- Put the real value in `VIDEO_REPORT.m2p_p95_ms` so the host's adaptive quality uses it.
- Log every leg as p50/p95/p99: pose leg, render/readback, encode, network, decode and display.
- Add an on-screen latency overlay and write `reports/latency-<date>.json`.
- Produce numbers from the simulator paired with the QA host and label them as simulator numbers. Wi-Fi numbers from a real iPhone are owner-only.

### Milestone 5: task 2.7, soak
Requirement: NFR-REL-003.
- Build a fake-iPhone soak with induced 2 % loss and 10 ms jitter. Add the impairment inside the fake iPhone so it runs without sudo, and add a Linux CI job that uses `tc netem`.
- The soak checks for leaks (RSS and handle counts over time), crashes and bounded latency.
- Run a 10-minute local soak as evidence. Record the 2-hour run as the CI job's job.
- The 60-minute device thermal run (NFR-PERF-001) is owner-only.

### Optional, only after Milestone 2 passes: README media task M.4
Make `viewfinder.gif` from the simulator with a real stream, following the "README media" rules in the plan.

## Out of scope: note these as "not verified, needs owner" and don't attempt them
- Anything that needs a physical iPhone, ARKit, real Wi-Fi or a thermal run. This includes 1.5.1c, O-1, the device part of NET-004 and on-device M2P numbers.
- Apple signing, notarization, TestFlight or credentials.
- Licence decisions, and adding a dependency the plan doesn't name. Pin any dependency you do add and note it in the log.
- Phase 3 work: takes, transport controls, H.264, stream encryption.
- Installing global tools. Python packages go only into `.venv.nosync/`.

## How to work
- Before any work, and again after any change to `native/` or `BlenderAddOn/`, run `tools/mission/setup.sh`.
- Protocol and coordinate changes start with `vcp.md` and golden vectors in `testdata/`. Rust, Swift and Python all test against those vectors.
- Rust: never use `unwrap` or `expect` on network data. Use `unsafe` only in FFI or encoder modules, with a `// SAFETY:` comment. Release the GIL for blocking work.
- Blender: never touch `bpy` or `gpu` off the main thread.
- Don't guess APIs. Before using a PyO3, `bpy`/`gpu`, Network framework, VideoToolbox, AVFoundation capture-event or GameController call that this repo doesn't already use, confirm it exists. Check the crate source, run a one-line check in headless Blender, or read the SDK headers.
- Keep each diff small and scoped to its feature. Don't refactor, rename or reformat code the feature doesn't need.
- Don't edit `AGENTS.md`, `docs/AGENT_LOOP_PROMPT*.md`, or requirement text in `docs/SRS.md`. Only dated notes under SRS §13 are allowed. If you find something that contradicts the SRS or the plan, add a dated §13 note and flag it. Don't change requirements quietly.

## Validation, for every feature and at every milestone end
- Use the `sightline-validate` skill to choose the suites. Run them with `tools/mission/check.sh`. Also run every suite that reads `testdata/`.
- For anything a user can see, exercise it like a user:
  - Blender side: the `sightline-qa-blender` skill (headless QA host with the fake iPhone; read `.mission/qa/state.json`, the panel text and the streamed frame).
  - iPhone side: the `sightline-qa-ios` skill (the real app in the iPhone 17 simulator with scripted poses, paired with the QA host; XCUITest and screenshots).
  - Lens controls must be shown end to end: an iOS control changes the Blender camera, and the change is visible in the next streamed frame.
- Prove that new tests catch bugs by breaking the code on purpose (mutation checks), as earlier loop iterations did. Record how many mutations were caught.
- Report only results from commands you actually ran. Copy the pass/fail line from the output.
- Don't loosen any CI gate: coverage, clippy ceilings, ruff, mypy, swift-format, TODO format.

## Git and records
- Work on a local branch `mission/phase2`. Don't push, open PRs or use the loop's GitHub flow.
- Make one commit per feature, with the subject `<task ID> <requirement IDs>: <summary>` (for example `2.3f FR-VF-004: viewfinder HUD`).
- The hooks installed by setup must pass and must never be bypassed. Follow the Privacy section of `AGENTS.md`: check `git config user.email` and read `git diff --cached` before every commit.
- After each feature, update `IMPLEMENTATION_PROGRESS.md` for every requirement whose status changed, citing evidence as file and line. Append a short entry to `docs/LOOP_LOG.md`: the date, "Mission", the task ID, files changed, commands run with pass/fail lines, what was not verified, and what is blocked.

## Done when
Milestones 1–5 are complete and validated. The final report lists each Phase 2 exit-gate item as met, met in the simulator only, or needs owner. The gate items are:
- 960×540 @ 30 fps at M2P p95 ≤ 120 ms on 5 GHz Wi-Fi on 3 OSes;
- lens and tap-to-focus work;
- the Blender UI stays responsive;
- the thermal run passes.
