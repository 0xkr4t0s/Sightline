# Agent Loop Log

Append-only. One entry per iteration (see `docs/AGENT_LOOP_PROMPT.md` §5).

## Blocked items

| Task | Status | Reason |
|---|---|---|
| S-1 on Windows and Linux (mid-range GPU) | BLOCKED (needs owner) | SRS §8.2 wants every OS. CI runners have no GPU, so this needs the owner's Windows/Linux machines: run `tests/bench_render.py` headless (recipe in its docstring) and commit the JSON to `reports/`. |
| S-1 EEVEE vs. FR-REN-004/NFR-PERF-002 | Resolved 2026-09-24 | EEVEE exempt with a warning; SRS updated. |
| 0.1.5 CI green on GitHub (P0 exit gate) | Resolved 2026-09-25 | PR #2 run `36096344645`: 15 of 15 jobs green; PR #2 merged as `bdc338e`. |
| S-2d Media Foundation H.264 and S-2e JPEG on Windows/Linux x86-64 | BLOCKED (needs owner) | Needs Windows/Linux machines or a CI remote. Run `cargo run --release -p vcam-video --example s2_jpeg -- <frames>` there (x86-64 needs `nasm`). |
| S-2 H.264 software-fallback licensing | Resolved 2026-09-24 | Option A: hardware H.264, JPEG fallback; NET-VID-003 updated. |
| S-3b Developer ID signing + notarization of the macOS wheel | BLOCKED (needs owner) | Needs an Apple Developer account and credentials. Re-run `tests/s3_macos_loading.sh --gui` with a signed and notarized `.so`. |
| S-3c Windows SmartScreen / Mark-of-the-Web | BLOCKED (needs owner) | Needs a Windows machine. |
| Local coverage-guided fuzzing (1.1.3c) | Needs owner OK | Installing a nightly toolchain is outside the loop's allowed installs. CI's `fuzz` job covers it once pushed. |
| 1.1.4b / 1.4.2b / 1.4.3b Swift pairing, iOS session endpoint, host selection + pairing UI + Keychain | Unblocked 2026-09-25 | Owner approved `swift-srp` 2.4.0 (plan, "Immediate next steps"). Discovery (1.4.3a) is done. 1.1.4b done in iteration 50, 1.4.2b in iteration 51. |
| 1.5.1c Pose leg over Wi-Fi/wired with a real iPhone (NFR-LAT-001, T1 gate) | BLOCKED (needs owner) | Needs a real iPhone paired through 1.4.2b/1.4.3b, and O-1. Then: Blender N-panel → Save Latency Report after a take, and commit the JSON to `reports/`. |
| O-1 device clock alignment | BLOCKED (needs owner) | Compare ARFrame.timestamp with CLOCK_UPTIME_RAW on a physical iPhone, including sleep/wake, before accepting pose-leg latency reports. Device CLOCK replies use this candidate clock (1.4.2c1); simulator timing does not establish ARKit clock alignment. |
| NET-004 device reconnect on a real network (1.4.2c2) | BLOCKED (needs owner) | Wi-Fi roaming, sleep/wake and backgrounding on a physical iPhone paired with Blender: after each one, the run should resume without re-pairing within 3 s of the network (or foreground) returning. Settings → Tracking shows "Last reconnect" for the measurement. |

---

## 2026-09-24 — Iteration 1 — halted in Orient (no task done)

- **Selected task:** 0.1.1 (NFR-QA-001), the first item in "Immediate next steps". **Not started.**
- **Why:** Orient §1 says to stop and report if there are uncommitted changes I didn't make. The project root isn't a git repo, but the nested `VCamIOS/` repo (branch `main`, one commit `50e6e4e Initial Commit`) has uncommitted work:
  - Modified: `VCamIOS.xcodeproj/project.pbxproj` (2026-04-08), `VCamIOS/ContentView.swift`, `VCamIOS/VCamIOSApp.swift` (2026-04-07)
  - Staged new file, then modified again today (2026-09-24 10:29): `VCamIOS/PLAN.md`. The unstaged edit adds a "Status: implemented … superseded" note at the top.
  - Untracked: `VCamIOS/FreeDPacketEncoder.swift`, `TrackingPose.swift`, `TrackingSessionController.swift`, `TrackingSettings.swift`, `UDPSender.swift`, `VCamIOSTests/` (2026-04-07/08)
  - `git diff --stat` (unstaged): 4 files, 207 insertions, 11 deletions
- These files are the tracking prototype that `IMPLEMENTATION_PROGRESS.md` assesses. Task 0.1.1 would put them into the new root repo's baseline commit. The owner has to agree to that first.
- **Files changed:** `docs/LOOP_LOG.md` (created), `docs/LOOP_STOP` (created). No source changes.
- **Commands run:** `git status --short`, `git log --oneline -5`, `git diff --stat`, `git diff --cached` in `VCamIOS/`, and `git rev-parse` at the root (not a repo). No test suites run, because nothing changed.
- **Owner action:** choose one of these, then delete `docs/LOOP_STOP`:
  1. Commit the work inside `VCamIOS/` yourself (for example `git add -A && git commit -m "Tracking prototype (FreeD) + v3 supersede note"`), or
  2. Add a line to this log saying the loop may include the uncommitted `VCamIOS/` work in the 0.1.1 baseline commit as-is.
- **Next task:** 0.1.1. Back up `VCamIOS/.git` to `~/VCamIOS-git-backup-2026-09-24.tar.gz`, make the root a repo that imports the VCamIOS history, add `.gitignore`, and make the baseline commit.

## 2026-09-24 — Owner setup (not a loop iteration)

- **Iteration 1 blocker resolved:** the prototype was committed inside `VCamIOS/` as `04ac942 v0.1 tracking sender prototype (FreeD over UDP, headless ARKit)`. `VCamIOS/` now has a clean tree with 2 commits. `docs/LOOP_STOP` was removed.
- **Toolchain prepared** (see `docs/AGENT_LOOP_PROMPT.md` §4):
  - `.venv.nosync/` (Python 3.14): pytest 9.1.1, maturin 1.15.0.
  - `.cargo/config.toml`: `target-dir = "native/target.nosync"`, which keeps build output out of iCloud.
  - Xcode 27.0 at `/Applications/Xcode-27.0.0.app`, used through `DEVELOPER_DIR`. iOS 27.0 simulator runtime installed.
- **Root `.gitignore` created.** Task 0.1.1 should review it and keep it, not replace it.
- **`BlenderAddOn/__init__.py`:** submodule imports moved into `register()`/`unregister()` so pytest can import the package without `bpy`. Verified: `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests` passes 12; headless Blender 5.2.2 register/unregister prints `REGISTER_OK`.
- **VCamIOS test fixes** (committed in `VCamIOS/` as the second prototype commit):
  - added a shared scheme with the test action;
  - fixed an overflow trap in `FreeDPacketEncoder.checksum` (`0x40 - sum` → `0x40 &- sum`) that crashed every test and would have crashed the app on a device.
  - Verified: `xcodebuild test ... name=iPhone 17 Pro`: 5 tests, 0 failures, TEST SUCCEEDED.
- **Next task:** 0.1.1.

## 2026-09-24 — Iteration 2 — 0.1.1 (NFR-QA-001) — done

- **Backup:** `~/VCamIOS-git-backup-2026-09-24.tar.gz` (archive of `VCamIOS/.git`, 104 entries, 33,868 bytes).
- **History import:** cloned `VCamIOS` into a temp dir, ran `git filter-branch --index-filter` to put every path under `VCamIOS/`, then did `git init -b main` at the root, fetched the rewritten `main`, and ran `git reset`. After that, `VCamIOS/` showed no changes against the imported tree, and `VCamIOS/.git` was deleted (it's in the backup).
  - Commit hashes map from old to new: `50e6e4e` → `ae4d81c`, `04ac942` → `984145a`, `ed349be` → `5ba2672`.
- **`.gitignore`:** kept the owner's file. Added a generic `build/` line, the only plan item it was missing. `VCamIOS/VCamIOS.xcodeproj/xcuserdata/` was removed from the index because `xcuserdata/` is ignored now; it's still on disk.
- **Baseline commit:** everything else, 77 paths. Excluded by `.gitignore`: `DesktopReceiver/build/`, `.venv.nosync/`, `.omx/`, `.DS_Store`, `.claude/settings.local.json`.
- **Files changed:** `.gitignore`, `IMPLEMENTATION_PROGRESS.md` (Repo/CI summary row, NFR-QA-001 now Partial, commit hash), `docs/LOOP_LOG.md`. New: `.git/`. Removed: `VCamIOS/.git/`.
- **Commands run:**
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`
  - `xcodebuild test … name=iPhone 17 Pro`: `Executed 5 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`. The first attempt was aborted with no output; the re-run passed.
  - Rust and Blender suites: not applicable yet (no `native/`, no add-on code change).
- **Flag:** `.git/` now lives in iCloud Drive (risk register: "iCloud Drive sync corrupts … `.git`"). Moving the repo is owner-only; consider marking it `.nosync` or moving it.
- **Blocked:** none.
- **Next task:** 0.1.2. Move `DesktopReceiver/` to `legacy/DesktopReceiver/` with a retirement README, and delete the stale `DesktopReceiver/build/`.

## 2026-09-24 — Owner note: iCloud flag resolved

- `~/iCloud Drive (Archive)` is a plain local folder (the archive copy macOS makes when iCloud Drive sync is turned off). It isn't under `~/Library/Mobile Documents` and isn't synced. The repo stays where it is.
- Closed the iCloud risk in `docs/IMPLEMENTATION_PLAN.md` and removed "moving the repo out of iCloud" from the loop's forbidden list. Don't flag this again.
- **Next task:** 0.1.2.

## 2026-09-24 — Iteration 3 — 0.1.2 (ARC-006) — done

- **Work:**
  - Ran `git mv DesktopReceiver legacy/DesktopReceiver`, which records the move as renames so history follows.
  - Deleted the stale `DesktopReceiver/build/` (44 MB, untracked; configured from `~/Downloads`).
  - Added `legacy/DesktopReceiver/README.md`: retirement notice, what to port to Rust first (per ARC-006), and a warning that its FreeD layout is non-standard.
  - Removed the now-dead `DesktopReceiver/build/` line from `.gitignore`.
- **Files changed:** `DesktopReceiver/**` → `legacy/DesktopReceiver/**`, `legacy/DesktopReceiver/README.md` (new), `.gitignore`, `IMPLEMENTATION_PROGRESS.md` (ARC-006 now Partial; summary, test-run, and PR-FD-001 paths), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cmake -S legacy/DesktopReceiver -B <tmp>`, `cmake --build`, `ctest --test-dir <tmp>`: `100% tests passed out of 9`. The build dir was outside the repo and removed afterwards.
  - No other suite touches these paths. No Python, iOS, or `testdata/` changes, so those suites weren't re-run.
- **Flag for owner:** `AGENTS.md:18` still says `` `DesktopReceiver/` ``, and `VCamIOS/VCamIOS/PLAN.md` refers to it too. The loop may not edit `AGENTS.md`. `PLAN.md` is a historical, superseded doc, so I left it as is.
- **Blocked:** none.
- **Next task:** 0.1.3. Create the Rust workspace skeleton (`native/`) with the crates, `rust-toolchain.toml`, clippy/rustfmt config, and one passing test per crate.

## 2026-09-24 — Iteration 4 — 0.1.3 (ARC-002) — done (fuzz/ deferred)

- **Work:** Rust workspace `native/` (resolver 3, edition 2024, `rust-version = "1.97"`, `publish = false`) with the members `vcam-protocol`, `vcam-net`, `vcam-video`, `vcam-py`, `vcam-fake-iphone` (binary). Dependency graph: `vcam-net` → `vcam-protocol`; `vcam-py` → protocol, net, video; `vcam-fake-iphone` → protocol, net; `vcam-video` uses protocol only as a dev-dependency. Each crate has one test that checks this wiring and the shared version (5 tests total).
  - `rust-toolchain.toml`: stable, with rustfmt and clippy. `rustfmt.toml`: edition 2024, Unix newlines.
  - Lints (`native/Cargo.toml:22-32`):
    - `unsafe_code` deny, `unsafe_op_in_unsafe_fn` deny;
    - clippy `undocumented_unsafe_blocks`, `unwrap_used`, `expect_used` deny;
    - `clippy.toml` allows unwrap and expect in tests;
    - `vcam-protocol` additionally has `#![forbid(unsafe_code)]` (ARC-002: no platform code).
  - `Cargo.lock` committed, since the workspace contains a binary.
- **No external dependencies added.** PyO3 arrives in 0.1.4.
- **Deferred: `native/fuzz/`.** Moved to task 1.1.3, which adds the fuzz targets. A cargo-fuzz crate needs nightly plus `libfuzzer-sys` and something to fuzz, and `vcam-protocol` has no decoder yet. 1.1.3 must create `native/fuzz/` (excluded from the workspace).
- **Files changed:** `native/{Cargo.toml,Cargo.lock,rust-toolchain.toml,rustfmt.toml,clippy.toml}`, `native/vcam-*/{Cargo.toml,src/*.rs}` (new), `IMPLEMENTATION_PROGRESS.md` (Rust summary; ARC-002 and NFR-QA-004 now Partial; NFR-QA-001 evidence), `docs/LOOP_LOG.md`.
- **Commands run (in `native/`):**
  - `cargo fmt --check`: pass after running `cargo fmt` (the first check found 2 formatting diffs).
  - `cargo clippy --all-targets -- -D warnings`: `Finished`, 0 warnings.
  - `cargo test`: 5 × `test result: ok. 1 passed; 0 failed`.
  - Lint probe (temporary, reverted): adding `.unwrap()` and an uncommented `unsafe {}` to `vcam-net` made clippy fail with `error: used unwrap() on an Option value` and `error: unsafe block missing a safety comment`. After the revert, clippy finished clean.
  - Build output went to `native/target.nosync/` (ignored).
  - Python, iOS, and Blender suites not affected.
- **Blocked:** none.
- **Next task:** 0.1.4. Add a minimal PyO3 `vcam_native.version()` in `vcam-py`, build it with maturin for Blender's Python 3.13, update the manifest (5.2.0, wheels, platforms), and prove `import vcam_native` works in headless Blender 5.2.

## 2026-09-24 — Iteration 5 — 0.1.4 (ARC-001, FR-BL-001) — done (macOS)

- **Dependency added:** `pyo3 = "=0.29.2"` in `native/vcam-py` (named in the plan). Default features only. The `extension-module` feature is deprecated in 0.29 (`guide/src/faq.md:29-32` in the crate source) because maturin ≥ 1.9.4 sets `PYO3_BUILD_EXTENSION_MODULE`. The venv has maturin 1.15.0.
- **Work:**
  - `native/vcam-py`: `[lib] name = "vcam_native"`, `crate-type = ["cdylib", "rlib"]`. Declarative `#[pymodule] mod vcam_native` with `version()`, using the syntax from `guide/src/module.md`.
  - `native/vcam-py/pyproject.toml`: maturin backend, `module-name = "vcam_native"`, `requires-python >= 3.13`.
  - `BlenderAddOn/blender_manifest.toml`:
    - `blender_version_min = "5.2.0"`, `platforms = ["macos-arm64"]`, `wheels = ["./wheels/vcam_native-0.1.0-cp313-cp313-macosx_11_0_arm64.whl"]`. Key names and the wheel→platform mapping were checked in Blender's `bl_pkg/cli/blender_ext.py:1900-1930,2166-2169`.
    - The **tagline** was 72 characters. Blender rejects taglines over 64 (`FATAL_ERROR … "tagline" … no longer than 64 characters`), so this manifest had never been buildable. I replaced it with a 59-character v3 tagline.
  - `tests/blender/smoke_native.py`: enables `bl_ext.user_default.vcam_blender`, imports `vcam_native`, and asserts `version()`. It's outside `BlenderAddOn/`, so it isn't packaged. The docstring has the run recipe.
- **Wheel:** `BlenderAddOn/wheels/*.whl` is gitignored, so the manifest names a file that has to be built first: `.venv.nosync/bin/maturin build --release -m native/vcam-py/Cargo.toml -i /Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 -o BlenderAddOn/wheels`. CI (0.1.5) must do the same per OS, then add `windows-x64` and `linux-x64` to `platforms`/`wheels`.
- **Files changed:** `native/vcam-py/{Cargo.toml,src/lib.rs,pyproject.toml}`, `native/Cargo.lock`, `BlenderAddOn/blender_manifest.toml`, `tests/blender/smoke_native.py` (new), `IMPLEMENTATION_PROGRESS.md` (ARC-001, FR-BL-001, NFR-QA-001, summary, test runs), `docs/LOOP_LOG.md`.
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes. `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings. `cargo test` shows 5 × `test result: ok. 1 passed; 0 failed`. The first clippy run failed because the inline `mod` needed its own `use pyo3::prelude::*`; that's fixed.
  - `maturin build --release … -i …/python3.13`: `Built wheel for CPython 3.13 to BlenderAddOn/wheels/vcam_native-0.1.0-cp313-cp313-macosx_11_0_arm64.whl`.
  - With `BLENDER_USER_RESOURCES=$(mktemp -d)`:
    - `blender --command extension build --source-dir BlenderAddOn` printed `created: …/vcam_blender-0.1.0.zip, 201971`, and the zip contains the wheel.
    - `extension install-file -r user_default -e` printed `STATUS Installed "vcam_blender"`.
    - `blender --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_native.py` printed `VCAM_NATIVE_OK 0.1.0 from …/extensions/.local/lib/python3.13/site-packages/vcam_native/__init__.py` and exited 0.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
- **Not proven here:** the Windows and Linux imports, which need CI (0.1.5). The quarantined-download case belongs to spike S-3.
- **Blocked:** none.
- **Next task:** S-1 (render and readback benchmark, `tests/bench_render.py`), 4th in "Immediate next steps". Its UI-with-timer part needs a human in front of Blender, so do the headless part only and mark the UI part `BLOCKED (needs owner)`.

## 2026-09-24 — Iteration 6 — S-1 (FR-REN-001..004, NFR-LAT-003) — sub-step S-1a done (macOS headless)

- **Split:**
  - **S-1a**, done: headless macOS benchmark plus the zero-copy test.
  - **S-1b**, next: the same script run inside the Blender UI with a timer on macOS. That launches a Blender window for about 1–2 minutes but needs no human. The script also needs a `bpy.app.timers` mode.
  - **S-1c**: Windows and Linux, blocked on the owner (see the table above).
- **Work:**
  - `tests/bench_render.py`: the plan's path, and SRS §11 says to keep it. Headless it calls `gpu.init()`. It builds a 393,612-triangle scene, turns overlays off, and pans the camera 0.2° per frame. It covers 3 modes × 3 resolutions × 60 frames and records draw, read, draw+read, deferred read (20 frames, 40 ms idle), the zero-copy probe, and a memcpy reference. Each cell asserts a non-blank image. Output is JSON plus PNGs.
  - `vcam_native._frame_probe(buf)` (`native/vcam-py/src/lib.rs:18-32`): reads every byte of a buffer-protocol `uint8` frame in place using safe `PyBuffer::as_slice` (no `unsafe`). It's marked private and gets replaced in task 2.1.
  - Results: `reports/s1-render-2026-09-24-macos-arm64.json`, and a dated SRS §13.1 note with the table, findings, proposed defaults, and one flagged conflict.
- **APIs confirmed before use** (in headless Blender 5.2.2 or in the crate source):
  - `gpu.init()` ("Initializes the GPU module for background use");
  - `GPUOffScreen(width, height, *, format)` and `draw_view3d(scene, view_layer, view3d, region, view_matrix, projection_matrix, *, do_color_management, draw_background)`;
  - `GPUTexture.read()` returns `Buffer`; `memoryview(buf)` gives format `B`, shape (540, 960, 4), C-contiguous;
  - `GPUTexture` and `GPUOffScreen` have no async or fence methods;
  - the only engine value is `BLENDER_EEVEE`;
  - `pyo3::buffer::PyBuffer::as_slice` and `ReadOnlyCell::get` exist (pyo3-0.29.2 `src/buffer.rs:247,751`).
- **Bugs found and fixed while benchmarking:**
  - `camera.matrix_world` was stale for the first cell until `view_layer.update()` ran, so the first run's Solid 540p used a different view.
  - `draw_view3d` draws the space's overlays (grid, selection outline), so the script now turns them off.
  - I found both by looking at the saved PNGs.
- **Key numbers** (median ms; SRS §13.1 has the full table):
  - Solid 540p: draw+read 5.5, deferred read 1.3.
  - Material 540p: 48.7, deferred read 3.1.
  - EEVEE 540p: 79.1, of which 76.2 is inside `draw_view3d`.
  - Zero-copy probe or a full memcpy: ≤ 0.24 ms even at 1080p.
- **Conflict flagged in SRS §13.1:** FR-REN-002 includes EEVEE, but EEVEE breaks FR-REN-004's 12 ms budget and NFR-PERF-002's 50 ms limit. The owner decides; I didn't change any requirement.
- **Minor:** Blender prints `Error: Not freed memory blocks: 28, total unfreed memory 1.75 MB` at exit after the benchmark. Exit code is 0. Probably the `gpu.types.Buffer`s or `gpu.init()`; look at it when building the Phase 2 renderer.
- **Files changed:** `tests/bench_render.py` (new), `native/vcam-py/src/lib.rs`, `reports/s1-render-2026-09-24-macos-arm64.json` (new), `docs/SRS.md` (§13.1 only), `IMPLEMENTATION_PROGRESS.md` (FR-REN, NFR-PERF, test runs), `docs/LOOP_LOG.md`.
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings; `cargo test` shows 5 × `ok. 1 passed`.
  - `maturin build --release … -i …/python3.13`: `Built wheel for CPython 3.13`.
  - Headless benchmark, run 3 times as I fixed the bugs above (final run recorded): `blender --background --factory-startup --python-exit-code 1 --python tests/bench_render.py -- --json … --save-dir …`, with the extension installed in a temporary `BLENDER_USER_RESOURCES`. Exit 0, 9/9 cells, `vcam_native` loaded.
  - `tests/blender/smoke_native.py`: `VCAM_NATIVE_OK 0.1.0`, exit 0.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
- **Next task:** S-1b. Add a `bpy.app.timers` UI mode to `tests/bench_render.py`, run it in GUI Blender on macOS with auto-quit, and append the UI numbers to SRS §13.1.

## 2026-09-24 — Iteration 7 — S-1b (FR-REN-001..004, NFR-PERF-002) — done (macOS UI)

- **Work on `tests/bench_render.py`:**
  - Refactored so each cell is a generator that yields a pause length. Headless drives it synchronously (`sleep`); the UI drives it from `bpy.app.timers` and calls `wm.quit_blender()` when done. On an exception it prints the traceback and exits with `os._exit(1)`, because `--python-exit-code` doesn't cover timers.
  - Context-bound objects (scene, view layer, depsgraph) are captured before the timer starts, since timer callbacks have no window context.
  - Added `--interval` (default 0 headless, 1/30 UI).
  - The camera **object** now moves every frame, so visible viewports redraw as they would with live tracking.
  - The offscreen takes its settings from a `VIEW_3D` space on a screen no window shows (Animation), so the user's viewport is untouched.
  - Added a pipelined measurement (double-buffered read-previous/draw-next, split into read and draw) and the tick gap.
- **Results:** SRS §13.1 "S-1b" (table, findings, updated proposal). Raw data: `reports/s1-render-2026-09-24-macos-arm64-ui.json` and `reports/s1-render-2026-09-24-macos-arm64-headless-30fps.json`. The S-1a JSON is unchanged.
  - UI run 2, median ms: Solid 540p pipelined 1.8 (sync 8.8); Solid 1080p pipelined 29.6, of which the read is 28.2; Material 540p 29.4; EEVEE 540p 55.8.
  - Finding: `read()` still blocks whenever the stream plus the visible viewport's redraws saturate the GPU. So frame skipping must adapt to measured `read()` time, since there's no fence API.
  - UI run 1 wasn't kept (the JSON was overwritten by run 2). Its Solid 540p pipelined figure, 20.9/31.5 ms, is quoted in §13.1 as a variance data point.
  - EEVEE conflict: still open, still owner-only (Blocked items table).
- **Owner impact:** each UI run opened a Blender window on the desktop for about 85 s. The script quit it itself; no human was involved.
- **Files changed:** `tests/bench_render.py`, `reports/s1-render-2026-09-24-macos-arm64-ui.json` (new), `reports/s1-render-2026-09-24-macos-arm64-headless-30fps.json` (new), `docs/SRS.md` (§13.1 only), `IMPLEMENTATION_PROGRESS.md` (S-1 test-run row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - Headless quick check, `--frames 10`: exit 0, 9 `S1_RESULT`.
  - GUI run 1 (`timeout 590 blender --factory-startup --python tests/bench_render.py -- --json … --save-dir …`, extension in a temporary `BLENDER_USER_RESOURCES`): exit 0, `S1_DONE`, 9 cells.
  - Headless with `--interval 0.0333333`: exit 0, 9 cells.
  - GUI run 2, after adding the pipelined read/draw split: exit 0, `S1_DONE`, 9 cells.
  - Checked the UI PNGs for Solid and EEVEE at 540p by eye: correct framing, no overlays.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.02s`.
  - No Rust or native change this iteration, so cargo and the smoke test weren't re-run.
- **Blocked:** S-1c (Windows and Linux) and the EEVEE decision. Both are already in the Blocked items table.
- **Next task:** 0.1.5 (CI workflow files: GitHub Actions matrix for fmt, clippy, test, maturin wheels, extension build, headless Blender smoke, plus a macOS `xcodebuild test` job). The files can be written and checked locally but can't be run remotely.

## 2026-09-24 — Iteration 8 — 0.1.5 (XP-001/002, NFR-QA-002) — done locally; never run on GitHub

- **Work:**
  - `.github/workflows/ci.yml` jobs:
    - `rust-fmt` (ubuntu);
    - `rust` (clippy `-D warnings` and `cargo test` on ubuntu, windows, macos, with setup-python 3.13 for pyo3's build script and rust-cache on `native -> target.nosync`);
    - `wheels` (maturin-action pinned to maturin v1.15.0; manylinux `2_28` on Linux; cp313);
    - `extension` (download all wheels, run `tools/set_manifest_wheels.py`, install Blender 5.2.2 on Linux, `extension build --split-platforms`);
    - `blender-smoke` (per OS: install Blender 5.2.2, `extension install-file -e` the matching `*-<platform>.zip`, run `tests/blender/smoke_native.py` with `--python-exit-code 1`);
    - `python` (pytest 9.1.1);
    - `ios` (`xcodebuild test` on `macos-26`, iPhone 17 Pro).
  - `tools/set_manifest_wheels.py`: rewrites the manifest's `platforms`/`wheels` to the wheels present and re-validates with `tomllib`. It exists because Blender's build fails if any listed wheel is missing: `FATAL_ERROR: Error adding to archive, file not found: "wheels/…win_amd64.whl"`, tested with and without `--split-platforms`. So the committed manifest stays macOS-only for local builds, and CI expands it.
- **Checked before use:**
  - Blender URLs `https://download.blender.org/release/Blender5.2/blender-5.2.2-{linux-x64.tar.xz,windows-x64.zip,macos-arm64.dmg}` all return HTTP 200.
  - Major tags exist via `git ls-remote`: `actions/checkout@v7`, `setup-python@v7`, `upload-artifact@v7`, `download-artifact@v8`, `PyO3/maturin-action@v1`, `Swatinem/rust-cache@v2`.
  - maturin-action inputs (`maturin-version`, `manylinux`, `args`) come from its `action.yml`.
  - Blender's tag→platform mapping (`manylinux_2_28_x86_64` → `linux-x64`) comes from `blender_ext.py:2143-2169`.
- **Tool added (venv only, not a project dependency):** `actionlint-py` 1.7.12.25 in `.venv.nosync`, to lint the workflow.
- **Commands run:**
  - `.venv.nosync/bin/actionlint .github/workflows/ci.yml`: exit 0, no findings.
  - Local rehearsal of `extension` + `blender-smoke` (macOS) in a temp copy, with stand-in Linux/Windows wheels copied from the macOS one:
    - `set_manifest_wheels.py` listed 3 platforms and 3 wheels;
    - `extension build --split-platforms` created `…-linux_x64.zip`, `…-macos_arm64.zip`, `…-windows_x64.zip`, each containing only its own wheel;
    - installing the macOS zip and running the smoke test printed `VCAM_NATIVE_OK 0.1.0`, `SMOKE_EXIT=0`;
    - `set_manifest_wheels.py` on an empty dir printed `no wheels in empty`, exit 1.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
  - Rust: unchanged this iteration, so not re-run.
- **Unverified until CI runs on GitHub. The owner creates the remote and pushes; the loop may not.** Most likely failure points:
  1. `-i python3.13` inside the manylinux_2_28 container.
  2. `-i <setup-python path>` on Windows.
  3. The apt package list Blender needs on `ubuntu-latest`.
  4. `macos-26` runner availability and its Xcode supporting the project's iOS 26.4 deployment target.
  5. The Linux cp313 wheel loading in Blender's bundled Python (glibc ≥ 2.28 assumed).
- **Not in CI yet:** `cargo fuzz` (NFR-QA-002), which needs targets from 1.1.3. The S-1 GPU benchmark stays off CI (no GPU on runners).
- **Blocked:** running CI remotely (`git push` / creating a remote is owner-only). Added to the table below as a note; not a stop condition.
- **Files changed:** `.github/workflows/ci.yml` (new), `tools/set_manifest_wheels.py` (new), `IMPLEMENTATION_PROGRESS.md` (Repo/CI; XP-001/002 and NFR-QA-002 now Partial), `docs/LOOP_LOG.md`.
- **Next task:** 0.1.6. Remove the "Live Link" wording from `BlenderAddOn/operators/tracking_receiver.py:23`. It's next in Phase 0 table order; the rest of the "Immediate next steps" list is Phase 1.

## 2026-09-24 — Iteration 9 — 0.1.6 (no SRS ID) — done

- **Work:** `BlenderAddOn/operators/tracking_receiver.py:23` `bl_description` changed from "Begin receiving FreeD/Live Link tracking data over UDP" to "Begin receiving FreeD camera tracking data over UDP". The Python client only parses FreeD D1 and the legacy FreeD JSON relay (`core/udp_client.py:96-121`), so "Live Link" was never accurate. A repo-wide search found no other "Live Link" in shipped code; `VCamIOS/VCamIOS/PLAN.md:12` ("no Live Link") is a superseded historical doc and was left alone.
- **Files changed:** `BlenderAddOn/operators/tracking_receiver.py`, `IMPLEMENTATION_PROGRESS.md` (UI text now Done; maturity line), `docs/LOOP_LOG.md`.
- **Commands run:**
  - Built the extension, installed it into a temporary `BLENDER_USER_RESOURCES`, and ran a throwaway check script that reads `bpy.ops.vcam.start_tracking.get_rna_type().description`: printed `DESC 'Begin receiving FreeD camera tracking data over UDP'`, exit 0.
  - `tests/blender/smoke_native.py`: `VCAM_NATIVE_OK 0.1.0`, exit 0.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
- **Phase 0 status:** tasks 0.1.1–0.1.6 are done locally. Exit gate not met: CI on GitHub (owner), Windows/Linux imports (need CI), and the S-2/S-3 decision records. S-2 and the local part of S-3 are agent-doable, so this is not a stop condition.
- **Blocked:** none new.
- **Next task:** S-2 (encoders), first sub-step: JPEG encode timing at 540p/720p in `vcam-video`. Pick `turbojpeg` or a pure-Rust encoder (the plan names both), pin the version, and log the licence.

## 2026-09-24 — Iteration 10 — S-2 (NET-VID-001/003) — sub-step S-2a done (JPEG, macOS arm64)

- **Split:**
  - **S-2a**, done: JPEG encoder timing at 540p/720p on macOS.
  - **S-2b**, next: H.264 via VideoToolbox on macOS (`objc2-video-toolbox`, named in the plan). Encode latency at 720p, low-latency settings, no B-frames.
  - **S-2c**: OpenH264 fallback timing plus the licensing write-up (Cisco binary vs. source build).
  - **S-2d**: Media Foundation on Windows. Blocked: needs a Windows machine (owner) or CI remote.
  - **S-2e**: JPEG on Windows and Linux x86-64. Blocked like S-2d.
- **Dependencies added, dev-only for the spike, pinned:** `turbojpeg = "=1.5.1"` (Unlicense OR MIT; vendors libjpeg-turbo 3.1.0 under IJG/BSD-3/zlib; default features `cmake`, `pkg-config`, `require-simd`; with `cmake` it builds the vendored copy and links statically, per `turbojpeg-sys-1.2.0/build.rs:60-89,147-190`), and `jpeg-encoder = "=0.7.1"` ((MIT OR Apache-2.0) AND IJG). Both are `[dev-dependencies]` of `vcam-video`, so neither is in the wheel yet.
- **Work:**
  - `native/vcam-video/examples/s2_jpeg.rs`: reads raw RGBA frames, times the flip plus both encoders at q70/80/90 with 4:2:0, decodes every result with libjpeg-turbo, and reports size, bitrate at 30 fps, and PSNR. It uses no `unwrap`/`expect`, so the workspace lints pass.
  - `tests/bench_render.py`: new opt-in `--dump-raw DIR` writes each cell's last frame as raw RGBA, giving S-2 real Blender content.
  - Results: SRS §13.2 (table, findings, recommendation), raw data in `reports/s2-jpeg-2026-09-24-macos-arm64.txt`.
- **APIs confirmed in the crate sources before use:** `turbojpeg::{Compressor::new, set_quality, set_subsamp, compress_to_vec, Image{pixels,width,pitch,height,format}, PixelFormat::RGBA, Subsamp::Sub2x2, decompress}`; `jpeg_encoder::{Encoder::new(w, u8), set_sampling_factor, SamplingFactor::R_4_2_0, encode(&[u8], u16, u16, ColorType::Rgba)}`.
- **Key numbers** (q80, median): 540p turbojpeg 1.0–1.05 ms vs. jpeg-encoder 2.8–3.0 ms; 720p 1.7–1.9 vs. 4.9–5.2 ms. Sizes are identical: 9.4–12.5 Mbit/s at 540p, 14–19 Mbit/s at 720p.
- **Recommendation:** turbojpeg (vendored, static). **CI impact when it becomes a real dependency (task 2.2):** install `nasm` on the x86-64 wheel builds (manylinux container and Windows). Without it, `require-simd` fails the build. IJG/BSD notices must ship.
- **Files changed:** `native/vcam-video/{Cargo.toml,examples/s2_jpeg.rs}`, `native/Cargo.lock`, `tests/bench_render.py`, `reports/s2-jpeg-2026-09-24-macos-arm64.txt` (new), `docs/SRS.md` (§13.2 only), `IMPLEMENTATION_PROGRESS.md` (NET-VID row, test-run row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - Frame dump: `blender --background --factory-startup --python-exit-code 1 --python tests/bench_render.py -- --frames 5 --warmup 2 --dump-raw /tmp/s2` exited 0 with 9 `S1_RESULT` and 9 `.rgba` files of the expected sizes.
  - In `native/`: `cargo fmt --check` passes (after `cargo fmt`); `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings; `cargo test` shows 5 × `test result: ok. 1 passed`.
  - `cargo build --release -p vcam-video --example s2_jpeg`, then `otool -L` on the binary showed no JPEG dylib.
  - `s2_jpeg` on 6 frames (Solid, Material, EEVEE × 540p/720p): exit 0, 36 rows, all decoded.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
- **Blocked:** S-2d and S-2e (Windows/Linux), added to the table.
- **Next task:** S-2b, the VideoToolbox H.264 encode-latency prototype on macOS in `vcam-video`, using `objc2-video-toolbox`. `unsafe` is allowed only in that encoder-backend module, with `// SAFETY:` comments.

## 2026-09-24 — Iteration 11 — S-2 (NET-VID-002/003) — sub-step S-2b done (VideoToolbox H.264, macOS)

- **Dependencies added, dev-only and macOS-only (`[target.'cfg(target_os = "macos")'.dev-dependencies]`), pinned:** `objc2-video-toolbox`, `objc2-core-media`, `objc2-core-video`, `objc2-core-foundation`, all `=0.3.2` (named in the plan; MIT, per the objc2 project). Default features only. Linux and Windows clippy builds get a stub `main`, so CI stays green there.
- **Work:** `native/vcam-video/examples/s2_videotoolbox.rs`, an encoder-backend prototype with `#![allow(unsafe_code)]` and a `// SAFETY:` comment on every unsafe block (NFR-QA-004; clippy `undocumented_unsafe_blocks` enforced these, and 3 blocks were fixed).
  - Session setup, a pool `CVPixelBuffer` fill (flip + swizzle), 30 fps real-time submission, and a C output callback. The callback records latency by frame index and converts AVCC → Annex-B with SPS/PPS.
  - Configs: low-latency vs. default rate control, and RGBA vs. BGRA input. Resolutions: 540p, 720p, 1080p.
- **APIs confirmed in crate sources before use:**
  - `VTCompressionSession::{create, prepare_to_encode_frames, pixel_buffer_pool, encode_frame, complete_frames, invalidate}`, `VTCompressionOutputCallback` signature, `VTSessionSetProperty(&CFType, &CFString, Option<&CFType>)`, the `kVTCompressionPropertyKey_*`/`kVTProfileLevel_H264_*`/`kVTVideoEncoderSpecification_*` statics;
  - `CVPixelBufferPool::create_pixel_buffer` (the free function is deprecated), `CVPixelBuffer{Lock,Unlock}BaseAddress`, `GetBaseAddress`, `GetBytesPerRow`;
  - `CMSampleBuffer::{data_buffer, format_description}`, `CMBlockBuffer::{data_length, copy_data_bytes}`, `CMVideoFormatDescriptionGetH264ParameterSetAtIndex`, `CMTime::new`;
  - `CFDictionary::from_slices`, `CFNumber::new_i32/i64`, `CFBoolean::new`.
- **Results (SRS §13.2 "S-2b"):**
  - Low-latency RC latency median/p95: 540p 2.5/3.4 ms, 720p 3.6/5.6 ms, 1080p 5.6/6.4 ms. Default RC at 1080p: 7.1/13.5 ms.
  - The encode call takes about 0.02 ms. Fill (flip + swizzle) takes 0.3/0.5/0.9 ms.
  - **RGBA input is rejected** by the pool (`-6680`), so the pipeline must swizzle to BGRA.
  - Bitrate accuracy is not measured: the synthetic translating input compresses trivially. Deferred to task 3.4, noted in the SRS.
- **Files changed:** `native/vcam-video/{Cargo.toml,examples/s2_videotoolbox.rs}`, `native/Cargo.lock`, `reports/s2-videotoolbox-2026-09-24-macos-arm64.txt` (new), `docs/SRS.md` (§13.2 only), `IMPLEMENTATION_PROGRESS.md` (test-run row, NET-VID row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings (after fixing 2 collapsible `if`s, 3 SAFETY comment placements, and 1 deprecated call); `cargo test` shows 5 × `test result: ok. 1 passed`.
  - `cargo run --release -p vcam-video --example s2_videotoolbox -- /tmp/s2`: exit 0, 6 `S2B_ROW`, 3 `S2B_UNSUPPORTED` (RGBA). The first run aborted on the RGBA config; I changed it to report instead of abort.
  - `ffprobe -count_frames` on the 3 streams: `h264|Main|has_b_frames=0|nb_read_frames=160`, 3 I + 157 P each. `ffmpeg -xerror -f null`: `DECODE_OK` × 3.
  - Checked decoded frame 40 (540p) by eye: upright, correct colours, 80 px wrap seam as expected.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
- **Blocked:** none new.
- **Next task:** S-2c. OpenH264 fallback encode timing (the `openh264` crate, source build vs. Cisco's binary) plus the H.264 licensing write-up, as options in the log per the S-5 rule (no licence decision by the loop).

## 2026-09-24 — Iteration 12 — S-2 (NET-VID-003) — sub-step S-2c done (OpenH264 fallback + licensing options)

- **Dependency added, dev-only, pinned:** `openh264 = "=0.9.8"` with features `source` (default) and `libloading` (BSD-2-Clause; OpenH264 2.6.0 upstream, BSD-2). This pulls in `openh264-sys2 0.9.8`, `libloading 0.8.9`, and `sha2 0.10.9` transitively. It's named by the plan (NET-VID-003 "for example, OpenH264"). Nothing is in the wheel.
- **Downloaded for measurement only:** Cisco's `libopenh264-2.6.0-mac-arm64.dylib` from `http://ciscobinary.openh264.org/` into `/tmp` (not in the repo, not installed). Its SHA-256 `052e98bf…24551` matches the crate's known-blob list, and `from_blob_path` checks it again.
- **Work:** `native/vcam-video/examples/s2_openh264.rs`. It uses the same frames, pacing, and motion as S-2b; builds source vs. Cisco; threads 1 vs. 4; 540p/720p/1080p. It dumps Annex-B for threads 1. It uses no `unsafe` and no `unwrap`.
- **APIs confirmed in crate sources:** `EncoderConfig::{new, usage_type, rate_control_mode, bitrate, max_frame_rate, intra_frame_period, skip_frames, num_threads}`, `Encoder::with_api_config`, `encode`, `EncodedBitStream::{frame_type, to_vec}`, `OpenH264API::{from_source, from_blob_path}`, `YUVBuffer::{new, read_rgb8}`, `RgbaSliceU8::new`.
  - Also found in `openh264-sys2-0.9.8/build.rs:144-185`: the NASM/assembly table is x86-only, so arm64 source builds are plain C, and x86-64 source builds want `nasm` for speed.
- **Results:** SRS §13.2 "S-2c".
  - 720p encode is about 3 ms median / 5.5 ms p95, and 1080p about 5.5 / 7.7 ms, plus 2–3 ms RGBA→YUV conversion.
  - Source and Cisco builds perform the same; 4 threads don't help (no multi-slice).
  - Bitrate isn't enforced unless frame skipping is on.
  - Run-to-run variance at 540p is about 2×.
- **H.264 software-fallback licensing — options for the owner (the loop decides nothing).** Sources: openh264.org FAQ and BINARY_LICENSE.txt v1.0, read this iteration.
  - **A. Hardware only, JPEG as the fallback.** Use VideoToolbox, Media Foundation, and VA-API (the OS or GPU vendor covers the codec licensing for their encoders, as is typical; not legally verified here). Where no hardware H.264 exists, fall back to Stage A JPEG, which is already a requirement (NET-VID-001). No H.264 patent exposure from our own binaries. **Conflicts with NET-VID-003's "a software fallback SHALL be selectable"**, so the requirement text would need an owner change.
  - **B. Cisco binary, downloaded on first use.** The extension downloads `libopenh264-<ver>-<platform>` from Cisco when the user enables the fallback, checks its SHA-256, and loads it with `libloading`. It needs a settings toggle, the text "OpenH264 Video Codec provided by Cisco Systems, Inc." next to it, and Cisco's licence text in the extension's licence section. Cisco covers the MPEG LA pool royalties. Limits: the grant covers only personal or non-remunerated use (paid productions aren't covered); it requires the `network` permission (already declared) and an internet connection the first time; and Cisco gives no guarantee against patents outside the MPEG LA pool.
  - **C. Compile the OpenH264 source into the wheel.** Simplest to build (the crate's `source` feature, plus `nasm` on x86-64). The BSD-2 copyright licence is fine with GPL, but **no H.264 patent licence** comes with it; the distributor carries that risk or must license from the pool (Via LA, formerly MPEG LA). Not recommended for distribution.
  - **D. Let users point to their own encoder** (for example a system `ffmpeg`/x264), with no H.264 binary shipped by us. It has the most setup friction, and x264 is GPL, so it's fine with the GPL extension but still has patent issues for the user.
  - Loop's observation, not a decision: A (with JPEG as the de-facto fallback) or B carry the least distribution risk. B's "personal use" clause may not fit professional users.
- **Files changed:** `native/vcam-video/{Cargo.toml,examples/s2_openh264.rs}`, `native/Cargo.lock`, `reports/s2-openh264-2026-09-24-macos-arm64.txt` (new), `docs/SRS.md` (§13.2 only), `IMPLEMENTATION_PROGRESS.md` (test-run row, NET-VID row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings; `cargo test` shows 5 × `test result: ok. 1 passed`.
  - `cargo run --release -p vcam-video --example s2_openh264 -- /tmp/s2 /tmp/libopenh264-2.6.0-mac-arm64.dylib`: exit 0, 12 `S2C_ROW`, 6 `S2C_STREAM`.
  - `DYLD_PRINT_LIBRARIES=1` re-run: dyld listed `/private/tmp/libopenh264-2.6.0-mac-arm64.dylib` before the Cisco rows, so the Cisco path really loads the Cisco binary.
  - ffprobe on 6 streams: `Constrained Baseline|has_b_frames=0|nb_read_frames=160`, 3 I + 157 P. `ffmpeg -xerror`: `DECODE_OK` × 6.
  - Checked decoded frame 40 (Cisco, 540p) by eye: correct.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`.
- **Blocked / decisions:** added "S-2 H.264 software-fallback licensing" to the table.
- **Phase 0 status:** S-2 is done on macOS; its remaining parts (S-2d/e) are owner-blocked. The one remaining agent-doable Phase 0 item is S-3 (macOS loading, quarantine/unsigned part; signing and notarization need credentials).
- **Next task:** S-3a. Build the extension zip, quarantine it (`xattr -w com.apple.quarantine …`), install it through Blender's `extension install-file`, and check whether the native `.so` loads, unsigned and ad-hoc signed. Developer ID signing and notarization are owner-only.

## 2026-09-24 — Iteration 13 — S-3 (XP-004) — sub-step S-3a done (unsigned/ad-hoc loading, macOS 27)

- **Work:**
  - `tests/s3_macos_loading.sh`: builds the extension zip, then for 5 scenarios (baseline; quarantined zip; quarantined `.so` linker-signed; quarantined `.so` unsigned; quarantined `.so` re-signed ad-hoc) installs into a fresh `BLENDER_USER_RESOURCES` via `extension install-file` and imports via `tests/blender/smoke_native.py`. It runs headless, and in a GUI Blender with `--gui`. It prints `S3_RESULT` lines with exit code, inherited/applied quarantine, and signature flags.
  - Results in SRS §13.3 and `reports/s3-macos-loading-2026-09-24.txt`.
- **Harness bug found and fixed:** the first `--gui` run returned exit 127 for every GUI case, because macOS has no GNU `timeout` (it only worked in the tool shell). I replaced it with a portable `with_timeout` (background plus SIGKILL watchdog) and re-ran. The report marks run 2's GUI column as invalid.
- **Findings:**
  - Installing a quarantined zip through Blender works without Developer ID signing: quarantine is not propagated to extracted files.
  - A quarantined `.so` goes through Gatekeeper: `library load disallowed by system policy` when denied, with non-deterministic outcomes across runs. **syspolicyd showed Gatekeeper dialogs on the desktop during these runs, including headless ones.** The owner may have seen, and possibly answered, some of them; the logs show two prompts later cleared.
  - Unsigned `.so` files never load.
- **Not changed:** requirements. XP-004 (signing) stands; the spike shows why it's still needed.
- **Files changed:** `tests/s3_macos_loading.sh` (new, executable), `reports/s3-macos-loading-2026-09-24.txt` (new), `docs/SRS.md` (§13.3 only), `IMPLEMENTATION_PROGRESS.md` (XP-003/004 rows), `docs/LOOP_LOG.md`. The wheel was rebuilt locally (gitignored).
- **Commands run:**
  - `codesign -dv` / `codesign -d --entitlements -` on Blender: hardened runtime, `disable-library-validation = true`.
  - `codesign -dv` on the `.so`: `flags=0x20002(adhoc,linker-signed)`. `spctl -a -vv -t install`: `rejected`.
  - `maturin build --release … -i …/python3.13`: `Built wheel for CPython 3.13`.
  - `tests/s3_macos_loading.sh`: run 1 (background), run 2 (`--gui`, GUI column invalid), run 3 (`--gui`, valid). Results table in SRS §13.3.
  - `log show --predicate 'process == "syspolicyd" …'` for runs 2–3: excerpts in the report.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.01s`. No Rust change this iteration.
- **Phase 0 status (stop check):** every remaining Phase 0 item is now owner-blocked:
  - CI on GitHub (remote);
  - Windows/Linux imports (CI);
  - S-1c, S-2d/e, S-3c (Windows/Linux machines);
  - S-3b (Apple credentials);
  - plus pending decisions on EEVEE and H.264 licensing.

  The S-1, S-2, and S-3 decision records exist in SRS §13 for macOS. **Stop condition met: "every remaining task in the phase is blocked on the owner."** Created `docs/LOOP_STOP`.
- **Next task (after the owner acts):** whichever blocker is cleared first. The CI remote unblocks most of Phase 0. If the owner decides to move on to Phase 1 before CI, the next task is 1.1.1 (`docs/protocol/vcp.md`).

## 2026-09-24 — Owner decisions (not a loop iteration)

- **Phase 1 may start now.** The Phase 0 items still open are all owner- or CI-blocked (Windows/Linux spikes S-1c/S-2d/S-2e/S-3c, signing S-3b, CI green). They stay in the Blocked items table, don't block Phase 1, and aren't a stop condition. Next task: **1.1.1** (`docs/protocol/vcp.md`), then continue in plan order.
- **EEVEE:** exempt with a warning. Solid is the default; EEVEE is an opt-in preview-quality mode exempt from FR-REN-004/NFR-PERF-002. SRS FR-REN-002/004 and NFR-PERF-002 updated.
- **H.264 fallback:** option A. Hardware encoders only, JPEG where none exists. No OpenH264 in shipped code. SRS NET-VID-003 and §13.2 updated.
- **GitHub:** the owner created a private remote (`origin`) and pushed `main`. The loop still doesn't push. It MAY read CI results read-only (`gh run list`, `gh run view --log-failed`) and fix failures locally; the owner pushes.

## 2026-09-24 — Iteration 14 — 1.1.1 (PR-001..004, PR-006) — done

- **Orient:** the owner's decisions are in (Phase 1 allowed; EEVEE exempt with a warning; H.264 fallback = JPEG; remote `origin` exists). CI run `35958600428` on the owner's push was `in_progress` when checked (`gh run list`). The next iteration should read its result before starting new work.
- **Work:** wrote `docs/protocol/vcp.md` (Draft 1) with these sections:
  - conventions (LE, `str8`, forward-compatible payload growth, device and host clocks);
  - transport and DNS-SD TXT;
  - the 12-byte header (PR-001) and 8-byte HMAC-SHA256/64 trailer with directional keys (PR-006);
  - ordered receive rules (PR-005 basis);
  - the type registry (UDP 0x01–0x06, TCP 0x40–0x4F);
  - byte layouts plus example hex for `POSE` (42 B), `CONTROL_STATE` (16 B, T1 subset: scale, locks, origin epoch; full idempotent state resent until `STATUS.control_ack`), `CLOCK` (28 B, NTP four-timestamp, host-initiated 1 Hz, also the heartbeat) and `STATUS` (≥ 16 B);
  - canonical axes and the ARKit→canonical conversion (DM-002);
  - liveness and reconnect (NET-004);
  - pairing, session setup, `ERROR` codes, security notes, open items, change log.
- **Design decision (within the plan's mandate, 1.2.2: "a PAKE or HKDF over the code and nonces; document the choice"): pairing uses SRP-6a (RFC 5054, 3072-bit group, g = 5, SHA-256).** Rationale, documented in `vcp.md` §9.1:
  - HKDF over a 20-bit code is brute-forceable offline from a recorded handshake.
  - ECDH plus a code-keyed confirmation lets an active MITM recover the code offline from whichever side confirms first; commitments don't fix this, because the MITM delays its own commitment.
  - A PAKE limits attackers to one online guess per attempt. Combined with the code policy (single-use, 3 failures, 5 min), an active attacker's success is ≤ 3 × 10⁻⁶ per code.
  - The iOS 27 CryptoKit (`CryptoKit.swiftinterface`) has **no** PAKE (no SPAKE2/CPace/SRP types). The permissively licensed options are Swift `adam-fowler/swift-srp` (Apache-2.0, README states RFC 5054 compliance and test-vector checks) and Rust RustCrypto `srp` (MIT/Apache).
  - **Found:** `srp` 0.6.0 does not follow RFC 5054 for `u` (unpadded A/B, `utils.rs:7-12`), uses the raw S as the key, and uses non-RFC M1/M2. Off the shelf it would fail interop about 1 in 128 pairings. The spec therefore pins every formula with `PAD()`, defines VCP's own proofs and HKDF key schedule over `K = H(PAD(S))`, and requires the RFC 5054 Appendix B vectors (open item O-3).
  - **Owner may want to review this choice.** It adds a Swift dependency (`swift-srp`, Apache-2.0, allowed for iOS by C-1) when task 1.4.3 comes. No dependency was added this iteration.
- **Facts checked in the SDK before relying on them:**
  - `ARConfiguration.h`: `.gravity` defines gravity as (0, −1, 0).
  - `ARTrackingState`/`Reason` enum names.
  - `ARFrame.timestamp` and `ARCamera.transform` headers don't state the clock base or the camera-local axes. These are recorded as open items O-1/O-2 for a device check (1.4.2), not asserted.
  - RFC 5054 3072-bit group generator `g = 5`, and N = 384 bytes (`srp-0.6.0/src/groups.rs`, `groups/3072.bin`).
- **Fix during verification:** the `HELLO` size said "38 + name"; it's 37 + name. Corrected.
- **Files changed:** `docs/protocol/vcp.md` (new), `IMPLEMENTATION_PROGRESS.md` (DM-001..003, DM-004, PR-001..004/006, PR-005 rows), `docs/LOOP_LOG.md`.
- **Commands run / verification:**
  - Example hex was generated with Python `struct` + `hmac` (keys `00..1f` d2h, `20..3f` h2d, `session_id 0x1234ABCD`).
  - An independent checker parsed all **6** example blocks straight from `vcp.md` at the spec's offsets. For each: header, `len`, and `session_id` checked; HMAC verified with the correct direction key and rejected with the wrong one; every field value matches the prose; sizes match (`POSE` 42, `CONTROL_STATE` 16, `CLOCK` 28, `STATUS` 16 + name, `HELLO` 37 + name). Output: `6 example blocks: ['POSE ok', 'CONTROL_STATE ok', 'CLOCK req ok', 'CLOCK rep ok', 'STATUS ok', 'HELLO ok (37+name)']`.
  - Clock example: θ = −4.000075 s, δ = 0.95 ms (matches §6.3).
  - §7: the quaternion rule `q_C ⊗ q` equals the position rule `(x,y,z)→(x,−z,y)` for 1000 random orientations (max error 4.4e-16). An identity ARKit camera looks along canonical +Y with up +Z.
  - No code changed, so the Rust, Python, iOS, and Blender suites weren't re-run.
- **Blocked:** none new.
- **Next task:** first read CI run `35958600428` (`gh run view --log-failed`) and fix any failures locally, since CI green is a P0 gate item. Otherwise 1.1.2: `testdata/vcp/*.bin` + `*.json` (the §6 examples, plus a full SRP-6a pairing transcript with fixed `a`, `b`, `s`, code, including RFC 5054 Appendix B vectors) and `testdata/coords/*.json` (DM-004 set). Generate them with a committed script, so the vectors are reproducible.

## 2026-09-24 — Iteration 15 — 0.1.5 follow-up (XP-001/002, NFR-QA-002) — CI failure fixed locally

- **CI run `35958600428`** (the owner's first push, read with `gh run view --json jobs` and `--log-failed`):
  - **10 of 13 jobs green:** rust-fmt, `wheels` ×3 (manylinux_2_28 x86-64, Windows, macOS arm64), `extension` (`--split-platforms`), `blender-smoke` ×3, python, ios.
  - `blender-smoke` printed `VCAM_NATIVE_OK 0.1.0` on Linux (`/home/runner/…`), Windows (`D:\a\_temp…`), and macOS (`/Users/runner/…`). **P0 gate item "the extension with the Rust module installs and imports on all three OSes" is met.**
  - **3 failures:** `rust (ubuntu|windows|macos)`, step `cargo clippy`. Cause: new lint `clippy::chunks_exact_to_as_chunks` ("using `chunks_exact` with a constant chunk size"), which fired at `vcam-video/examples/s2_jpeg.rs:46` (×2) and `s2_videotoolbox.rs:396`.
  - CI's `stable` is **rustc 1.98.1** (from the `wheels` logs), while this Mac has **1.97.1**, so local clippy couldn't see the new lint.
- **Fix:** replaced `chunks_exact(4)` / `chunks_exact_mut(4)` with `as_chunks::<4>().0` / `as_chunks_mut::<4>().0` (`slice::as_chunks`, stable since 1.88.0, confirmed in the local `core/src/slice/mod.rs`). There are no other constant-size `chunks_exact` uses in `native/`.
- **Verification:**
  - In `native/` (rustc 1.97.1): `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings; `cargo test` shows 5 × `test result: ok. 1 passed`.
  - **The 1.98 lint itself can't be checked locally** (only `stable-aarch64-apple-darwin` 1.97.1 is installed; `rustup toolchain list`). Confirmation needs the next CI run.
  - Behaviour unchanged:
    - `s2_jpeg` on `solid_960x540` and `material_1280x720`: all 12 rows' sizes and PSNR are identical to `reports/s2-jpeg-2026-09-24-macos-arm64.txt` (`diff`: no output).
    - `s2_videotoolbox`: completed. Decoded frame 0 of the 540p stream has RGB means (102.1, 77.4, 73.7) vs. source (104.0, 80.0, 73.1), max diff 2.6; an R/B swap would give 30.3. `CHANNEL_ORDER_OK`.
- **Files changed:** `native/vcam-video/examples/s2_jpeg.rs`, `native/vcam-video/examples/s2_videotoolbox.rs`, `IMPLEMENTATION_PROGRESS.md` (Repo/CI, maturity; ARC-001 and FR-BL-001 now **Done**; XP-001 **Done**; XP-002 and NFR-QA-002 evidence), `docs/LOOP_LOG.md` (blocked table, this entry).
- **Owner actions:**
  1. Push, so CI can confirm the clippy fix.
  2. Optional, to stop this class of surprise: run `rustup update stable` on this Mac, so local clippy matches CI's stable. The loop may not update global toolchains without asking. The alternative is pinning `native/rust-toolchain.toml` to an exact version, which would change the plan's "stable" choice (0.1.3) — owner's call.
- **Next task:** read the next CI run once pushed. Otherwise 1.1.2: `testdata/vcp/` and `testdata/coords/` golden vectors from a committed generator script.

## 2026-09-24 — Iteration 16 — 1.1.2 (NFR-QA-003, DM-004, PR-004) — done

- **Orient:** `main` is 2 commits ahead of `origin`, so the iteration-15 clippy fix is unpushed and there's no new CI run to read. Local rustc is still 1.97.1.
- **Work:**
  - `tools/gen_testdata.py`: stdlib-only reference implementation of `vcp.md` Draft 1 and generator of `testdata/`. It refuses to write unless:
    - its SRP-6a reproduces **RFC 5054 Appendix B** exactly (k, x, v, A, B, u, premaster; SHA-1, 1024-bit, same code path as VCP's SHA-256/3072);
    - its HKDF reproduces **RFC 5869 A.1**;
    - its bytes equal all **6** example blocks in `vcp.md`;
    - its coordinate cases match hand-derived forward/up directions.

    `--check` mode is for CI.
  - `testdata/vcp/`:
    - `messages.json` + 10 `.bin`: the 6 spec examples, plus a large-seq limited pose, an epoch-only `CONTROL_STATE`, a UTF-8 `STATUS`, and `ERROR`;
    - `receive.json`: 26 §4.3/§6 cases, 5 accept, covering every §4.3 step, the size boundaries 1200/1201, reflection (wrong direction key), forward-compatible longer payload, non-finite floats, quaternion norm limits, `motion_scale` range, and absent-field bytes ignored;
    - `freshness.json`: seq, state_seq, status_seq, origin_epoch wrap;
    - `pairing.json`: fixed code `042917`, s, a, b; all SRP values; K, T_pair, M1, M2, PK; the 4 TCP messages; a wrong-code M1;
    - `session.json`: T_sess, proofs, k_d2h/k_h2d, the 4 TCP messages, and a first POSE under the derived key;
    - `srp-rfc5054-appendix-b.json`.
  - `testdata/coords/arkit_to_canonical.json`: 9 DM-004 cases.
  - `.github/workflows/ci.yml`: job `python` gains a step `python tools/gen_testdata.py --check`.
- **Independent verification** (a separate script, not the generator's code):
  - The 3072-bit N typed from RFC 5054 Appendix A equals `srp-0.6.0/src/groups/3072.bin`: `True`.
  - A from-scratch §4.3/§6 receiver agreed with all 26 `receive.json` labels (mismatches: `[]`) and accepted all 7 valid UDP messages in `messages.json`.
  - `.bin` files are identical to their hex.
  - The session's first POSE verifies under `k_d2h`.
  - Pairing TCP payloads: HELLO 43, CHALLENGE 416, PROOF 416, ACCEPT 32, as specified.
  - Coordinates re-derived with rotation matrices (Ry·Rx·Rz, C = Rx(90°)): max difference 4.82e-10 against the 1e-6 tolerance.
- **Commands run:**
  - `python3 tools/gen_testdata.py` (Python 3.14.6): `wrote 17 files to testdata/`.
  - `--check`: `testdata/ up to date (17 files)`, with both `python3` and `.venv.nosync/bin/python`.
  - `.venv.nosync/bin/actionlint .github/workflows/ci.yml`: exit 0.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.02s`.
  - No Rust or Swift change, so cargo and xcodebuild weren't re-run. The consumers come in 1.1.3/1.1.4.
- **Files changed:** `tools/gen_testdata.py` (new), `testdata/vcp/*` and `testdata/coords/*` (new, 17 files), `.github/workflows/ci.yml`, `IMPLEMENTATION_PROGRESS.md` (DM-004 Partial; PR-004 **Done**; PR-001..003/006 and NFR-QA-003 Partial), `docs/LOOP_LOG.md`.
- **Owner action:** push; this and iteration 15's clippy fix are both waiting. Three commits are now ahead of `origin`.
- **Next task:** 1.1.3, `vcam-protocol` types, encode/decode, HMAC, conversions, tests from `testdata/`, and fuzz targets. It's too big for one iteration, so split it:
  - 1.1.3a: header + UDP messages + receive rules, against `messages.json`/`receive.json`/`freshness.json`;
  - 1.1.3b: pairing/session crypto against `pairing.json`/`session.json`/RFC 5054;
  - 1.1.3c: `native/fuzz/` targets.

  Crypto crates (sha2/hmac/hkdf and an SRP bigint) will need pinning; the plan names HMAC and PAKE work but not specific crates, so pick RustCrypto and log it.

## 2026-09-24 — Iteration 17 — 1.1.3a (PR-001..003, PR-005, PR-006, NET-002/003) — done

- **Orient:** `main` is still 3 ahead of `origin` (unpushed), so there's no new CI run. Local rustc is 1.97.1.
- **Split of 1.1.3** (recorded in iteration 16):
  - **1.1.3a** (this): UDP framing, messages, receive rules, freshness, clock math, tests from `testdata/`.
  - **1.1.3b:** TCP `HELLO`/pairing (SRP-6a)/session/`ERROR` codecs and crypto, against `pairing.json`/`session.json`/RFC 5054.
  - **1.1.3c:** `native/fuzz/` targets.
- **Dependencies added (pinned):**
  - `vcam-protocol`: `hmac = "=0.13.0"` and `sha2 = "=0.11.0"` (RustCrypto, MIT OR Apache-2.0, both on `digest 0.11.3`). HMAC-SHA256 is named by PR-006.
  - `serde_json = "=1.0.151"` as a dev-dependency (MIT OR Apache-2.0), only for reading `testdata/` in tests.
  - API confirmed in the crate sources: `Mac::verify_truncated_left` (`digest-0.11.3/src/mac.rs:161-169`, constant-time `ct_eq` over `tag.len()` left bytes), and `KeyInit::new_from_slice` (`crypto-common-0.2.2`).
- **Work (`native/vcam-protocol`):**
  - `src/wire.rs`: bounds-checked LE `Reader`; every read returns `Option`.
  - `src/message.rs`: `Pose`/`ControlState`/`Clock`/`Status` exact decode/encode with §6 validation (non-finite, quaternion norm 0.9–1.1, `motion_scale` [0.001, 1000] only when present, name UTF-8 ≤ 63 bytes); `orientation_normalized()`; `ClockSample::from_timestamps` in i128.
  - `src/endpoint.rs`: `Endpoint { role, session_id, precomputed send/recv HMAC }`.
    - `seal`: enforces direction, ≤ 1200 bytes, and name length; on failure the buffer is left unchanged.
    - `open`: vcp.md §4.3 steps 1–8 in order, then the direction/`CLOCK`-mode check, returning a `DropReason` per step.
  - `src/fresh.rs`: `SeqFilter` (newest wins) and `EpochWatcher` (any change, including wrap; the first value is not a reset).
  - `tests/golden.rs`: 7 tests consuming `testdata/vcp/messages.json` (8 UDP cases, byte-exact decode → fields → re-encode), `receive.json` (all 26 verdicts, plus exact `DropReason` for 10), `freshness.json`, the clock example, seal limits, and a no-panic sweep (every prefix, every byte flip, 20,000 pseudo-random datagrams).
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings (one `match_like_matches_macro` fixed); `cargo test` passes. `golden`: `test result: ok. 7 passed; 0 failed`; the other 5 crates' unit tests: 5 × `ok. 1 passed`.
  - **Mutation check** (temporary, reverted):
    - removing the version check made `receive_rules_match_vectors` and `drop_reasons_follow_rule_order` fail (`FAILED. 5 passed; 2 failed`);
    - accepting an equal seq made `freshness_sequences_match_vectors` fail (`FAILED. 6 passed; 1 failed`);
    - after restoring: `ok. 7 passed`.
  - `maturin build --release … -i …/python3.13`: `Built wheel`. Blender smoke (temporary `BLENDER_USER_RESOURCES`): `VCAM_NATIVE_OK 0.1.0`, exit 0.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed`. `python3 tools/gen_testdata.py --check`: up to date.
  - Rust 1.98 clippy lints are still unverifiable locally (see iteration 15).
- **Files changed:** `native/vcam-protocol/{Cargo.toml,src/lib.rs,src/wire.rs,src/message.rs,src/endpoint.rs,src/fresh.rs,tests/golden.rs}`, `native/Cargo.lock`, `IMPLEMENTATION_PROGRESS.md` (ARC-002; PR-001..003/006, PR-005, NET-002 Partial with Rust evidence; NET-003 split out as Partial), `docs/LOOP_LOG.md`.
- **Owner action:** push; 4 commits will then be ahead of `origin`, including the unconfirmed clippy fix.
- **Next task:** 1.1.3b. TCP messages (`HELLO`, `PAIR_*`, `SESSION_*`, `ERROR`) and the pairing/session crypto against `testdata/vcp/pairing.json`, `session.json`, and `srp-rfc5054-appendix-b.json`.
  - This needs `hkdf` (RFC 5869) and a big-integer modpow for SRP. The RustCrypto `srp 0.6.0` defaults don't match RFC 5054 (iteration 14), so either use its group constants with our own formulas over `num-bigint`, or use `crypto-bigint`. Pick one, pin it, log it.
  - Constant-time modpow matters for the host's secret `b`; prefer `crypto-bigint`'s constant-time ops if the API allows it.

## 2026-09-24 — Iteration 18 — 1.1.3b (PR-001..003, PR-006, NFR-SEC-001, FR-UX-002) — done

- **Orient:** `main` is still 4 ahead of `origin` (unpushed). No new CI run.
- **Dependencies added (pinned; plan names HMAC and the PAKE/HKDF pairing, PR-006 / 1.2.2):**
  - `hkdf = "=0.13.0"` (RustCrypto, MIT OR Apache-2.0).
  - `crypto-bigint = "=0.7.5"` (RustCrypto, Apache-2.0 OR MIT; default features). Chosen over `num-bigint` for constant-time modular exponentiation: `FixedMontyForm::pow_bounded_exp` does fixed work for a fixed bit bound (`modular/fixed_monty_form/pow.rs:27`).
  - Dev-only: `sha1 = "=0.11.0"`, just to run RFC 5054 Appendix B (SHA-1) through the same code.
  - APIs confirmed in the sources: `MontyParams::new(Odd<Uint>)`, `FixedMontyForm::{new, mul, add, sub, pow_bounded_exp, retrieve}`, `Uint::{from_be_slice (panics on wrong length, so only called on exact-width buffers), from_be_hex, to_be_bytes, rem_vartime (constant-time in self for a fixed modulus), wrapping_mul/add, is_zero_vartime}`, `Odd/NonZero::new → CtOption::into_option`, and `Hkdf::<Sha256>::{new, expand}`.
- **Work (`native/vcam-protocol`):**
  - `src/control.rs`: TCP frames per vcp.md §9–§11: `ControlMessage::{encode, payload, decode, frame_len}` (`session_id` 0, len ≤ 4096, forward-compatible tails, str8 limits 64/127).
  - `src/pairing.rs`:
    - generic `SrpGroup<L>` over group size and `Digest` (RFC 5054 formulas with `PAD`);
    - VCP `HostPairing::{new, challenge, verify}`, `device_pair` → `PendingPair::finish`;
    - `SessionHandshake::{device_proof, host_proof, verify_*, keys}`;
    - secrets (`a`, `b`, salt, nonces) are injected by the caller (no RNG or I/O in this crate);
    - rejects `A ≡ 0`, `B ≡ 0`, `u = 0`, and codes that aren't exactly 6 ASCII digits.
  - `tests/pairing.rs`: 5 tests. Full host↔device pairing byte-exact against `pairing.json` (HELLO, PAIR_CHALLENGE, PAIR_PROOF, PAIR_ACCEPT, M1, M2, PK on both ends); wrong code; tampered M2; session proofs and keys, with the keys opening the vector's first POSE and wrong keys failing; control frames from `messages.json`; malformed-frame rejection plus a no-panic sweep. Unit tests: RFC 5054 Appendix B (k, x, v, A, B, u, client S, server S) and bad-code / zero-value rejection.
- **Bug found in the golden vectors and fixed:** `tools/gen_testdata.py` built the wrong-code case by re-running SRP with the wrong code on **both** sides, which also changed the host's verifier and B. The Rust test (an independent implementation) disagreed. Fix: the device uses the wrong code against the host's real B and u. A new generator self-check requires the wrong-code S and M1 to differ from the correct ones. Only `wrong_code.M1` in `testdata/vcp/pairing.json` changed (`git diff --stat`: 1 line).
- **Spec:** `vcp.md` open item O-3 is marked verified on the Rust side (Swift still open).
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings (fixed along the way: a `from_*` naming lint, so the helper was renamed `reduce_be`, and one type annotation); `cargo test`: `vcam-protocol` lib `ok. 3 passed`, `golden` `ok. 7 passed`, `pairing` `ok. 5 passed`, plus 4 × `ok. 1 passed` in the other crates.
  - **Mutation check** (temporary, reverted):
    - an altered M2 label failed `pairing_transcript_matches_vector`;
    - dropping `session_id` from the HKDF info failed `session_setup_matches_vector_and_keys_open_first_pose`;
    - after restoring, all green.
  - `python3 tools/gen_testdata.py` then `--check`: up to date (17 files).
  - `maturin build`: `Built wheel`. Blender smoke: `VCAM_NATIVE_OK 0.1.0`, exit 0. `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed`.
- **Noted for later (not done):** secrets aren't zeroized (`crypto-bigint`'s `zeroize` feature is off). Consider it when `vcam-net` stores `PK` and the SRP state (1.2.2).
- **Files changed:** `native/vcam-protocol/{Cargo.toml,src/lib.rs,src/control.rs,src/pairing.rs,tests/pairing.rs}`, `native/Cargo.lock`, `tools/gen_testdata.py`, `testdata/vcp/pairing.json`, `docs/protocol/vcp.md` (O-3 row), `IMPLEMENTATION_PROGRESS.md` (PR-001..003/006, FR-UX-001/002, NFR-SEC-001 split out), `docs/LOOP_LOG.md`.
- **Owner action:** push (5 commits will be ahead of `origin`).
- **Next task:** 1.1.3c, `native/fuzz/` with cargo-fuzz targets for `Endpoint::open`, `ControlMessage::decode`, and the pairing inputs (`HostPairing::verify` with arbitrary `PairProof`). It needs nightly plus `cargo install cargo-fuzz` (allowed by the loop prompt); the fuzz crate stays outside the workspace. Time-box the runs and record executions/s and coverage.

## 2026-09-24 — Iteration 19 — 1.1.3c (PR-005, NFR-QA-002) — done, except the coverage-guided run

- **Orient:** `main` is still 5 ahead of `origin` (unpushed). No new CI run. The only toolchain is `stable-aarch64-apple-darwin` 1.97.1, and `cargo-fuzz` isn't installed.
- **Constraint:** `cargo fuzz` needs a nightly toolchain (sanitizer-coverage flags). The loop prompt allows `cargo install cargo-fuzz` and `rustup component add` only; installing a new **toolchain** (`rustup toolchain install nightly`) is "ask first". So I didn't install it locally, and didn't install cargo-fuzz either, since it's useless without nightly. Logged as blocked in the table. CI installs nightly on the runner instead.
- **Dependency (fuzz crate only, pinned):** `libfuzzer-sys = "=0.4.13"` ((MIT OR Apache-2.0) AND NCSA). It isn't linked into the wheel or any workspace crate.
- **Work:**
  - `native/fuzz/` (the `cargo fuzz init` layout, with its own `[workspace]` so the main workspace is unchanged: `cargo metadata` still lists the 5 crates). Targets:
    - `udp_open`: `Endpoint::open` from both roles; anything accepted must satisfy `open(seal(msg)) == msg`.
    - `control_decode`: `ControlMessage::decode`; `frame_len` must agree with `decode`, and accepted frames must round-trip through `encode`.
    - `pairing_inputs`: arbitrary `PAIR_PROOF` against a fixed `HostPairing` (a random `M1` must never verify) and arbitrary `PAIR_CHALLENGE` into `device_pair`.
  - `.github/workflows/ci.yml`: new job `fuzz` (ubuntu): `rustup toolchain install nightly --profile minimal`, `cargo install cargo-fuzz --version 0.13.2 --locked`, seeds `fuzz/corpus/<target>` from `testdata/vcp` (the UDP `.bin` files, the TCP messages from `pairing.json`/`session.json`, and one proof and one challenge seed), then `cargo +nightly fuzz run <target> -- -max_total_time=60` for each target. It uploads `fuzz/artifacts/` on failure. The corpus/artifact paths were confirmed in `cargo-fuzz-0.13.2/src/project.rs:17,1017-1028,1083`.
  - `.gitignore`: `native/fuzz/{corpus,artifacts,coverage}/`. `native/fuzz/Cargo.lock` is committed.
- **Verification this iteration (stable only):**
  - In `native/fuzz`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings -W clippy::unwrap_used` shows `Finished`, 0 warnings.
  - `cargo build --release --bins` builds the three libFuzzer binaries (libFuzzer's C++ is compiled by `libfuzzer-sys`'s build script).
  - **Seed replay** (`-runs=0`): `udp_open` `Done 9 runs`, `control_decode` `Done 11 runs`, `pairing_inputs` `Done 3 runs`, all exit 0. The seed count + 1 is libFuzzer's empty input.
  - **Coverage-blind** mutation, 60 s per target in parallel (`-max_total_time=60`):
    - `udp_open`: 274,500,204 execs (4.5M/s);
    - `control_decode`: 279,870,211 execs (4.59M/s);
    - `pairing_inputs`: 45,093 execs (739/s, one 3072-bit modpow per input);
    - all exit 0, 0 artifacts.

    **This is not coverage-guided fuzzing.** Without sancov, most mutations die at the size/magic/tag checks, as the high exec rate suggests. It's a smoke check only.
  - `.venv.nosync/bin/actionlint .github/workflows/ci.yml`: exit 0.
  - The main workspace and Python/Blender aren't affected (no changes outside `native/fuzz`, CI, `.gitignore`), so they weren't re-run.
- **Files changed:** `native/fuzz/{Cargo.toml,Cargo.lock,fuzz_targets/udp_open.rs,fuzz_targets/control_decode.rs,fuzz_targets/pairing_inputs.rs}` (new), `.github/workflows/ci.yml`, `.gitignore`, `IMPLEMENTATION_PROGRESS.md` (PR-005, NFR-QA-002), `docs/LOOP_LOG.md`.
- **Owner actions:**
  1. Push (6 commits ahead). CI will then run the guided fuzz job and confirm the iteration-15 clippy fix.
  2. Optional: OK installing a nightly toolchain locally (`rustup toolchain install nightly --profile minimal` plus `cargo install cargo-fuzz --version 0.13.2 --locked`), so the loop can run guided fuzzing without a push.
- **1.1.3 status:** 1.1.3a, b, c are done. `vcam-protocol` covers DM-001 (pose type) and PR-001..006. The DM-002/003 "conversions" part is iOS-side by design (DM-002: the conversion happens once on the iPhone), so the Rust coordinate code is only needed for the Blender apply step (1.3.2).
- **Next task:** 1.1.4, the Swift `VCP` module in VCamIOS (encoder/decoder + ARKit→canonical conversion) with XCTests on `testdata/` (folder reference in the test bundle). Split it: 1.1.4a UDP messages + HMAC + coords tests; 1.1.4b pairing via `swift-srp` (needs owner review of that dependency per iteration 14).

## 2026-09-24 — Iteration 20 — 1.1.4a (DM-001..004, PR-001..003, PR-006, NFR-QA-003) — done

- **Orient:** `main` is still 6 ahead of `origin` (unpushed). No new CI run or owner notes.
- **Split of 1.1.4:**
  - **1.1.4a** (this): Swift UDP messages, HMAC, receive rules, ARKit→canonical, and XCTests on `testdata/`.
  - **1.1.4b**: Swift TCP control frames and SRP-6a pairing/session, needing the `swift-srp` dependency (Apache-2.0). The owner should review it first (iteration 14).
- **APIs confirmed in the Xcode 27 iOS SDK interfaces before use:**
  - CryptoKit `HMAC<H>.authenticationCode(for:using:)` (`D: DataProtocol`) and `SymmetricKey(data:)`;
  - simd `simd_quatf.init(_ rotationMatrix: simd_float3x3)`, quaternion `*`, `act(_:)`, `init(ix:iy:iz:r:)`, and the `simd_quatf { simd_float4 vector }` layout (ix, iy, iz, r = VCP's x, y, z, w);
  - Swift 6.4 (`xcrun swift --version`), which has `nonisolated` type declarations (SE-0449).
- **Work (no dependencies added):**
  - `VCamIOS/VCamIOS/VCP/VCPMessages.swift`: `VCPPose`/`VCPControlState`/`VCPClock`/`VCPStatus`/`VCPMessage`, exact decode/encode with §6 validation (same rules as Rust); `VCPSeqFilter`; bounds-checked `VCPReader`.
  - `VCPEndpoint.swift`: `seal`/`open` with the §4.3 rule order and a typed `VCPDropReason`; HMAC-SHA256 truncated to 8 bytes; hand-written constant-time comparison (CryptoKit's validator compares full-length MACs only); direction rules per §5.
  - `VCPCoordinates.swift`: `canonicalPose(fromARKit:)` with `(x, −z, y)` and `q_C ⊗ q` (w ≥ 0).
  - All types are `nonisolated`, so they work both in the app target (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) and off the main actor later (ARC-005).
  - Written from the spec. No GPL code: the Rust extension code wasn't translated, only the shared vectors were used (C-1).
  - `VCamIOSTests/VCPGoldenTests.swift`: 6 tests: 8 UDP messages open, match their fields, and re-seal byte-exactly; 26 `receive.json` verdicts plus 6 exact drop reasons; freshness; 9 DM-004 cases; seal limits; a prefix/byte-flip sweep.
  - `project.pbxproj` (+10 lines, `plutil -lint` OK):
    - a `testdata` **folder reference** (`path = ../testdata`) in the test target's Resources phase, as the plan asks;
    - the three `VCP/*.swift` files added to the test target's `membershipExceptions`, the same pattern the FreeD files use (the test bundle compiles app sources directly and has no test host).
- **Commands run:**
  - `xcodebuild test … name=iPhone 17 Pro`: first run failed to compile (`withUnsafeBytes` resolved to the `Array` instance method), fixed with `Swift.withUnsafeBytes`. Second run: `Executed 11 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **` (6 VCP + 5 FreeD).
  - **Mutation check** (`-only-testing:VCamIOSTests/VCPGoldenTests`, reverted):
    - dropping the version check gave `Executed 6 tests, with 2 failures`;
    - position `(x, z, y)` instead of `(x, −z, y)` gave `Executed 6 tests, with 1 failure`;
    - after restoring: `0 failures`, `** TEST SUCCEEDED **`.
  - No Rust, Python, or testdata change this iteration, so those suites weren't re-run.
- **Files changed:** `VCamIOS/VCamIOS/VCP/{VCPMessages,VCPEndpoint,VCPCoordinates}.swift` (new), `VCamIOS/VCamIOSTests/VCPGoldenTests.swift` (new), `VCamIOS/VCamIOS.xcodeproj/project.pbxproj`, `IMPLEMENTATION_PROGRESS.md` (Pose maths, DM-001..003, DM-004, PR-001..003/006, NFR-QA-003), `docs/LOOP_LOG.md`.
- **Owner actions:**
  1. Push (7 commits ahead).
  2. **Approve or reject `swift-srp`** (`adam-fowler/swift-srp`, Apache-2.0) for 1.1.4b. It isn't GPL, so C-1 allows it; the alternative is our own SRP-6a in Swift over a BigInt package, which is more code to audit.
- **Next task:** 1.1.4b if `swift-srp` is approved (Swift pairing/session against `pairing.json`/`session.json`/RFC 5054 App. B). If it isn't answered yet, go on in plan order to **1.2.1** (vcam-net UDP receiver thread with latest-sample slot and per-source stats), and mark 1.1.4b "waiting for owner".

## 2026-09-24 — Iteration 21 — 1.2.1 (NET-002, FR-BL-002/004, NFR-REL-001/002) — done

- **Orient:** `main` is 7 ahead of `origin` (unpushed). No new CI run and no owner answer on `swift-srp`, so **1.1.4b is waiting for the owner** and, per iteration 20's plan, I moved on to 1.2.1.
- **Work (`native/vcam-net`, no dependencies added):**
  - `src/udp.rs` `UdpReceiver::{start, local_addr, latest_pose, latest_control, stats, stop}`:
    - The thread (`vcam-udp-rx`) owns the socket with a 50 ms read timeout and authenticates each datagram with a host-role `vcam_protocol::Endpoint`.
    - Poses go through `SeqFilter` into a latest-sample slot; `CONTROL_STATE` goes into its own newest-`state_seq` slot.
    - `ReceiverStats`: `poses_applied`, `poses_stale`, `DropCounts` per §4.3 reason, `rate_hz` and seq-gap `loss` over a 1 s window, `last_pose_age`, and `source` (latest authenticated sender, the reply address for STATUS, vcp.md §3/NET-004).
    - `Drop` stops and joins.
    - A 1201-byte buffer detects oversize datagrams. Windows `WSAEMSGSIZE` (10040) is counted as a size drop, because Windows reports oversize datagrams as an error instead of truncating them. **That path only runs on Windows, so it's unverified until the CI `rust (windows-latest)` job runs the tests.**
    - A poisoned lock is recovered (`PoisonError::into_inner`) rather than panicking.
  - **Interpretation, logged:** the plan says "latest-sample slot (atomic swap)". I used a `Mutex<Option<Sample>>` held only for a copy: the same newest-wins, O(1), no-queue semantics without `unsafe` (a lock-free `AtomicPtr` swap would need `unsafe`, which NFR-QA-004 limits to FFI/encoder modules). C-2's "bounded, non-blocking" holds: readers never wait on I/O, only on a sub-microsecond copy.
  - `tests/udp_receiver.rs`: 6 tests over real loopback sockets: newest-seq wins with a stale count; drops by reason (tag, size ×2) with no slot or reply-address update; loss 0.2 and rate 16 Hz from 16 of 20 seqs, then the window expires after 1.1 s; `CONTROL_STATE` newest wins; the reply address follows the latest source (roaming); `stop()` < 1 s, idempotent, port re-binds.
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings; `cargo test` all `ok` (vcam-net `udp_receiver` `ok. 6 passed`; vcam-protocol 3/7/5; 4 × 1).
  - Flakiness check: `udp_receiver` 10 consecutive runs, `10/10 runs passed`.
  - **Mutation check** (reverted):
    - bypassing `SeqFilter` failed `newest_seq_wins_and_reordered_poses_are_stale`;
    - dropping `+1` from the expected-count formula failed `loss_and_rate_come_from_seq_gaps_in_the_last_second`;
    - after restoring: `ok. 6 passed`.
  - `maturin build`: `Built wheel`. Blender smoke: `VCAM_NATIVE_OK 0.1.0`, exit 0. `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed`.
- **Files changed:** `native/vcam-net/src/lib.rs`, `native/vcam-net/src/udp.rs` (new), `native/vcam-net/tests/udp_receiver.rs` (new), `IMPLEMENTATION_PROGRESS.md` (FR-BL-002, NET-002, NFR-REL-001/002 split out), `docs/LOOP_LOG.md`.
- **Owner actions (unchanged):** push (8 commits ahead); decide on `swift-srp` for 1.1.4b.
- **Next task:** 1.2.2, the TCP control server in `vcam-net`: accept one device, run `HELLO` → pairing (`HostPairing` with a CSPRNG code, salt, and `b`; code policy §9.4: single use, 3 failures, 5 min) → session (`SessionHandshake`) → hand the `Endpoint` to `UdpReceiver`. Store `PK` per `device_id` behind a storage trait; the real Blender-config path comes in 1.2.5.
  - A CSPRNG crate is needed. The plan doesn't name one; `getrandom` (RustCrypto, MIT/Apache) is the minimal choice. Log it and pin it.
  - It's bigger than one iteration, so split it: 1.2.2a server state machine plus in-memory store, tested with a Rust client built from `vcam-protocol`; 1.2.2b persistence plus `STATUS`/`CLOCK` sending.

## 2026-09-24 — Iteration 22 — 1.2.2a (FR-UX-002, NFR-SEC-001, NET-004, NFR-REL-002) — done

- **Orient:** `main` is 8 ahead of `origin` (unpushed, no new CI run). No owner answer on `swift-srp` (1.1.4b still waiting).
- **Dependency added (pinned), flagged for owner review:** `getrandom = "=0.4.3"` in `vcam-net` (RustCrypto, MIT OR Apache-2.0, default features, no `std`/`sys_rng`). The plan requires random secrets for pairing (1.2.2: code, and the PAKE secret, salt, and nonces) but names no RNG crate; `getrandom` is the minimal OS-CSPRNG wrapper. API confirmed: `getrandom::fill(&mut [u8]) -> Result<(), Error>` (`getrandom-0.4.3/src/lib.rs:87`).
- **Work (`native/vcam-net/src/control.rs`):**
  - `ControlServer::{start, local_addr, enable_pairing, disable_pairing, pairing_code, try_event, stop}` plus `Drop`. `ServerConfig` (host_id, udp_port, `code_lifetime` 5 min, `max_failures` 3, `handshake_timeout` 10 s).
  - `PairingStore` trait + `MemoryStore`. `ControlEvent::{Paired, SessionStarted{keys, peer}, SessionEnded}` go through a non-blocking `try_event()` (C-2).
  - The listener thread (non-blocking, 50 ms poll) spawns one thread per connection; all are joined on stop. Reads poll every 50 ms, checking stop and the handshake deadline; frames are capped at 4096 bytes by `ControlMessage::frame_len`.
  - vcp.md §9.4 code policy: uniform 6 digits by rejection sampling below 4,294,000,000; single use; invalidated after 3 failed proofs (illegal SRP values count as failures) or on expiry; one pairing at a time (`ERROR 4`).
  - Errors: 1 version, 2 proof, 3 not paired, 4 busy, 5 disabled/expired, 6 malformed. The server sends `ERROR`, then closes.
  - Sessions: random non-zero `session_id` different from the previous one; a new session from a paired device supersedes the old one (NET-004). A generation counter makes sure `SessionEnded` is only reported by the connection that still owns the newest session.
  - v1 has no post-setup TCP messages, so the connection is simply held until it closes.
- **Tests (`native/vcam-net/tests/control_server.rs`, 9, real TCP with a device client built only from `vcam-protocol`):**
  - full pairing plus session: the server's `SessionStarted` keys equal the client's, and they authenticate a UDP `POSE`; `SessionEnded` on disconnect; the code is consumed;
  - reconnect: new `session_id` and keys;
  - 3 wrong codes lock pairing (then `ERROR 5`), with no `Paired` event;
  - code expiry;
  - unpaired device (`ERROR 3`); bad session proof (`ERROR 2`);
  - malformed HELLO (`ERROR 6`); `proto_min`/`proto_max` with no overlap and header version 2 (`ERROR 1`);
  - concurrent pairing (`ERROR 4`);
  - `stop()` < 1 s with idle connections, which are closed, and the listener is closed;
  - 50 codes all 6 digits and distinct enough.
- **Commands run:**
  - In `native/`: `cargo fmt --check` passes; `cargo clippy --all-targets -- -D warnings` shows `Finished`, 0 warnings; `cargo test` all `ok` (control_server `ok. 9 passed`; udp_receiver 6; vcam-protocol 3/7/5; 4 × 1).
  - Flakiness: `cargo test -p vcam-net` 10 consecutive runs, `10/10 runs passed`.
  - **Mutation check** (reverted):
    - code not consumed on success failed `pair_then_session_…`;
    - failures not counted failed `three_wrong_codes_lock_pairing`;
    - session proof unchecked failed `unpaired_device_and_bad_session_proof_are_refused`;
    - after restoring: `ok. 9 passed`.
  - `maturin build`: `Built wheel`. Blender smoke: `VCAM_NATIVE_OK 0.1.0`, exit 0. `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed`.
- **Files changed:** `native/vcam-net/{Cargo.toml,src/lib.rs,src/control.rs,tests/control_server.rs}`, `native/Cargo.lock`, `IMPLEMENTATION_PROGRESS.md` (FR-UX-001/002, NET-004, NFR-SEC-001), `docs/LOOP_LOG.md`.
- **Owner actions:** push (9 commits ahead); review `getrandom 0.4.3`; decide on `swift-srp` (1.1.4b).
- **Next task:** 1.2.2b, a file-backed `PairingStore`: JSON of `{device_id, device_name, PK}` in a caller-given directory (Blender's user config dir, passed from Python in 1.2.5), written atomically (write to a temp file, then rename), with owner-only permissions on Unix. Plus the host's `STATUS` sender over UDP to the receiver's `source` address, and the 1 Hz `CLOCK` request.
  - The JSON needs `serde`/`serde_json` as a normal dependency (the plan doesn't name them), or a tiny hand-written line format with no new dependency. Prefer the no-dependency option; decide then.

## 2026-09-24 — Iteration 23 — 1.2.2b.1 (FR-UX-002, NFR-SEC-001) — done

- **Scope split before work:** 1.2.2b.1 is file-backed pairing persistence and persistence-before-acknowledgement; 1.2.2b.2 remains STATUS/CLOCK sending and control-session/UDP lifecycle wiring. This iteration does only 1.2.2b.1.
- **Decision:** no new dependencies. Use a versioned, length-delimited binary snapshot containing device ID, PK, and UTF-8 device name in a private `vcam-pairings` subdirectory of a caller-supplied config directory. Write/sync a private temporary file, then rename over the snapshot; reject malformed stores instead of silently resetting them. Blender supplies its real config path and stable host ID in 1.2.5. Unix directory/file modes are 0700/0600; Windows uses the config directory's inherited ACL. One active writer per config directory.
- **Orient:** clean working tree, `main` 9 commits ahead of origin; no stop sentinel. Phase 1 continues under the existing owner waiver. No remote writes or dependencies added. LSP references were unavailable; exact-symbol search found all PairingStore callers in vcam-net.
- **Work:** `FileStore::open(config_dir)` loads all pairings or returns an error (only a missing snapshot starts empty). The versioned snapshot includes a record count and validates duplicate IDs, name length/UTF-8, truncation and trailing bytes. Replacement writes preserve other devices. Temporary files use exclusive creation; failed writes leave the in-memory pairing unchanged and attempt to remove their temporary file. Symlink directory/snapshot paths are rejected on open.
- **Control contract:** `PairingStore::put` now returns `io::Result<()>`; MemoryStore and its only server callsite migrated. The host commits before sending PAIR_ACCEPT. A storage error emits `ControlEvent::PairingStorageFailed`, closes TCP without an acceptance or Paired event, and leaves the code available for retry (subject to its original expiry). v1 has no storage-error wire code, so no new protocol value was invented.
- **Boundary:** file contents are synced before rename; this is atomic process-restart persistence, not a power-loss durability guarantee for the directory entry. One active writer per config directory; stable host identity and the Blender path remain explicit 1.2.5 work. Windows/Linux runtime checks await owner push/CI; only macOS was exercised here.
- **Regression coverage:** six new tests in `native/vcam-net/tests/control_server.rs` (starting at lines 395, 420, 473, 490, 517, 554): restart authentication without re-pairing; actual rename failure refuses acceptance and permits retry; replace one device while retaining another and UTF-8/newline names; failed replacement retains the old key; malformed/truncated files fail closed without overwriting; Unix private modes and symlink rejection.
- **Commands and observed results:**
  - In `native/`: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`: clippy `Finished` with zero warnings; `cargo test: 40 passed (13 suites, 0.00s)`. Focused control-server run: `cargo test: 15 passed (1 suite, 0.33s)`.
  - Throwaway `cargo run -p vcam-net --example pairing_persistence_smoke -- <temporary-config> pair`, then a separate process with `session`: `PERSISTENCE_SMOKE_OK mode=pair authenticated=true` and `PERSISTENCE_SMOKE_OK mode=session authenticated=true`. Both performed real TCP authentication. Initial smoke compilation failed with E0599 (Option mistaken for Result); corrected to ok_or, then both runs passed. Smoke source and temporary config/key files removed after success.
  - `.venv.nosync/bin/maturin build --release -m native/vcam-py/Cargo.toml -i /Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 -o BlenderAddOn/wheels`: `Built wheel for CPython 3.13`. Built/installed the extension in a fresh BLENDER_USER_RESOURCES, then `/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_native.py`: `VCAM_NATIVE_OK 0.1.0`, exit 0. Isolated resources removed.
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `12 passed in 0.02s`. `.venv.nosync/bin/python tools/gen_testdata.py --check`: `testdata/ up to date (17 files)`.
  - `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer xcodebuild test -project VCamIOS/VCamIOS.xcodeproj -scheme VCamIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`: `Executed 11 tests, with 0 failures (0 unexpected)`; `** TEST SUCCEEDED **` (includes shared VCP golden vectors).
- **Files changed:** `native/vcam-net/src/{store,control,lib}.rs`, `native/vcam-net/tests/control_server.rs`, `IMPLEMENTATION_PROGRESS.md`, `docs/LOOP_LOG.md`. Requirements remain Partial: the new persistence evidence does not claim Blender/iOS integration is finished.
- **Next task:** 1.2.2b.2 — session-bound UDP lifecycle, STATUS push to the authenticated source and 1 Hz CLOCK requests. Do not start it in this iteration.
- **Owner actions:** push local commits to exercise CI (this commit makes 10 ahead); existing decisions on swift-srp and review of getrandom remain outstanding. No new owner blocker for persistence.

## 2026-09-24 — Iteration 24 — 1.2.2b.2a (NFR-SEC-001, NET-004, NFR-REL-002) — done

- **Scope split before work:** 1.2.2b.2a binds UDP reception to the authenticated TCP session, including replacement, disconnect, the protocol’s 10-second authenticated-datagram timeout, and shutdown. 1.2.2b.2b remains STATUS/CLOCK sending. This iteration does only lifecycle binding.
- **Design:** ControlServer owns the bound UDP receiver and advertises its actual port. UDP starts without keys; a verified session installs its endpoint and resets samples, filters, source and stats atomically. SessionStarted reports an ID rather than exporting keys for callers to install. Old TCP readers detect replacement; cleanup cannot revoke a newer session. No new dependencies.

- **Orientation:** clean tree at entry, main 10 commits ahead; no LOOP_STOP. Continued under the existing Phase 1 owner waiver. LSP references were unavailable; exact-symbol searches located and migrated the receiver/server callers. No new dependencies or remote writes.
- **Implemented:** ControlServer binds TCP and UDP on the same IP, advertises the actual UDP port, and exposes latest pose/control and receiver statistics. Verified session activation, SESSION_ACCEPT and the start event are serialized. UDP authentication and sample publication share the state lock with session replacement/revocation, so an in-flight old packet cannot restore cleared state. TCP read/write timeouts are 50 ms. Replacement closes old TCP without allowing its cleanup to revoke the replacement; disconnect, 10 seconds without an authenticated datagram, and stop clear keys and samples. Stats expose current session ID and last authenticated datagram age. SessionStarted exposes the ID instead of keys; all callers migrated.
- **Regression coverage:** real TCP/UDP tests reject UDP before proof and prevent a bad proof from evicting a valid session; valid CONTROL_STATE refreshes the idle deadline while forged packets do not; disconnect revokes; replacement closes old TCP, rejects old keys and accepts a restarted sequence; stop closes active and idle connections and permits a fully functioning server on the same ports while the stopped handle remains alive.
- **Commands and observed results:**
  - In native/: cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test. Formatting passed; clippy finished with zero warnings; 42 Rust tests passed. Control server: `test result: ok. 17 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 12.27s`. UDP receiver: `test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.14s`. Remaining suites and doctests passed. The tool's aggregate 0.00s timing was inaccurate and reported separately; it is not the run duration.
  - Focused stop/re-enable regression: cargo test -p vcam-net --test control_server stop_closes_active_and_idle_connections_and_releases_both_ports: `test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 16 filtered out; finished in 0.45s`.
  - Throwaway cargo run -p vcam-net --example session_lifecycle_smoke: `SESSION_LIFECYCLE_SMOKE_OK gated=true replaced=true revoked=true rebind=true`. Exercised real session proofs and UDP, old/new keys, TCP EOF, disconnect, bounded stop and same-port rebind. Smoke source and its empty examples directory removed after success.
  - .venv.nosync/bin/maturin build --release -m native/vcam-py/Cargo.toml -i /Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 -o BlenderAddOn/wheels: `Built wheel for CPython 3.13`. Built/installed the extension in fresh BLENDER_USER_RESOURCES, then /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_native.py: `VCAM_NATIVE_OK 0.1.0`, exit 0, Blender 5.2.2. Isolated resources removed.
  - .venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests: ` 12 passed in 0.02s`. .venv.nosync/bin/python tools/gen_testdata.py --check: `testdata/ up to date (17 files)`.
  - DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer xcodebuild test -project VCamIOS/VCamIOS.xcodeproj -scheme VCamIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro': `Executed 11 tests, with 0 failures (0 unexpected)`; `** TEST SUCCEEDED **` (6 VCP golden and 5 FreeD tests).
- **Files changed:** native/vcam-net/src/control.rs, native/vcam-net/src/udp.rs, native/vcam-net/tests/control_server.rs, native/vcam-net/tests/udp_receiver.rs, IMPLEMENTATION_PROGRESS.md, docs/LOOP_LOG.md. Requirements remain Partial: no claim of Blender Python integration, device-side reconnect, physical-device validation or outbound STATUS/CLOCK support.
- **Next task:** 1.2.2b.2b — STATUS at 2 Hz/on change and CLOCK requests at 1 Hz to the latest authenticated source, scoped to the current session. The estimator remains 1.2.4. Do not start a second task in this iteration.
- **Owner actions:** push local commits for cross-platform CI (this commit makes 11 ahead); existing swift-srp decision and getrandom review remain outstanding. No new owner blocker for lifecycle binding.

## 2026-09-24 — Iteration 25 — 1.2.2b.2b (NET-003, NET-004, PR-006, NFR-SEC-001) — done

- **Scope before work:** authenticated outbound STATUS at 2 Hz/on change and CLOCK requests at 1 Hz, only to the latest authenticated UDP source of the active TCP session. No clock estimator/reply sampling (1.2.4), Blender bindings (1.2.5), or second task.
- **Design:** keep sending on the existing UDP worker under its session lock; reuse an output buffer and monotonic worker clock. Publish applied host state explicitly, scoped by session ID: receiving a pose/control does not acknowledge Blender application. The worker owns STATUS sequence/session flags; replacement clears publication and timers. No new dependencies.
- **Orientation:** clean tree, main 11 commits ahead; no LOOP_STOP. Existing Phase 1 owner waiver applies. LSP unavailable; exact symbol references identify callers.

- **Implemented:** existing UDP worker sends authenticated STATUS at 2 Hz/on publication changes and CLOCK requests at 1 Hz, including while otherwise idle or receiving traffic. Sending shares the session lock with revocation and uses bounded socket writes plus a reusable buffer. No outbound address exists until an authenticated device datagram arrives. Roaming follows only authenticated sources. Session replacement resets status sequence, applied state and schedules; revocation stops sending. Host timestamps are nanoseconds on a monotonic worker clock.
- **API contract:** HostStatus contains applied pose/control sequences, error code and optional bound-camera name; UdpReceiver/ControlServer::update_status(session_id, status) rejects obsolete sessions and names over 63 UTF-8 bytes. The worker generates status_seq and active/bound flags. Initial state acknowledges nothing and reports no camera; received samples alone do not acknowledge application. Changed state is sent at the next worker poll; identical publication does not trigger extra packets.
- **Regression coverage:** three new real-UDP tests cover cadence without device traffic, applied-state changes versus receive-only state, UTF-8 byte limits, stale-session updates, authentication-gated routing, forged-source rejection, roaming, replacement key/sequence reset and revocation. Existing paired TCP session test now observes published STATUS over its negotiated UDP keys.
- **Commands and observed results:**
  - In native/: cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test: formatting passed, clippy finished with zero warnings, 45 tests passed. Control server: `test result: ok. 17 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 12.19s`. UDP receiver: `test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.94s`. Remaining suites and doctests passed.
  - Focused real TCP/UDP run: cargo test -p vcam-net --test control_server paired_session_drives_real_udp_and_disconnect_revokes_it: `test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 16 filtered out; finished in 0.25s`.
  - Throwaway cargo run -p vcam-net --example outbound_smoke: `OUTBOUND_SMOKE_OK poses=119 periodic_statuses=3 clocks=2 changed=true revoked=true`. Sustained real pose traffic did not starve timers; explicit applied status arrived promptly and revocation stopped output. Removed smoke source and empty examples directory after success.
  - .venv.nosync/bin/maturin build --release -m native/vcam-py/Cargo.toml -i /Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 -o BlenderAddOn/wheels: `Built wheel for CPython 3.13`. Built and installed extension in fresh BLENDER_USER_RESOURCES, then /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_native.py: `VCAM_NATIVE_OK 0.1.0`, Blender 5.2.2, exit 0. Temporary resources removed.
  - .venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests: `12 passed in 0.01s`. .venv.nosync/bin/python tools/gen_testdata.py --check: `testdata/ up to date (17 files)`.
  - DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer xcodebuild test -project VCamIOS/VCamIOS.xcodeproj -scheme VCamIOS -destination "platform=iOS Simulator,name=iPhone 17 Pro": `Executed 11 tests, with 0 failures (0 unexpected) in 0.115 (0.202) seconds`; `** TEST SUCCEEDED **` (6 VCP golden, 5 FreeD).
- **Files changed:** native/vcam-net/src/{udp,control,lib}.rs, native/vcam-net/tests/{udp_receiver,control_server}.rs, IMPLEMENTATION_PROGRESS.md, docs/LOOP_LOG.md. No dependency or golden-vector changes. Requirement labels remain Partial; no Blender application integration, clock-reply matching/estimation, or physical-device validation claimed.
- **Next task:** 1.2.3 — Rust mDNS advertising. Task 1.2.2 is complete on the host; clock reply validation/estimation remains 1.2.4 and Python/Blender integration remains 1.2.5. No second task started.
- **Owner actions:** push local commits for cross-platform CI (this commit makes 12 ahead); existing swift-srp decision and getrandom review remain pending. No new owner blocker.

## 2026-09-24 — Iteration 26 — 1.2.3 (NET-001, NFR-REL-002) — done

- **Scope before work:** dual pure-Rust DNS-SD advertisements owned by the running ControlServer, actual bound ports, version/blend/host TXT, metadata updates and withdrawal on stop/drop. Advertising is enabled by the host application while listening (before device pairing); no iOS discovery UI or Python binding in this task.
- **Dependency:** pin mdns-sd 0.21.4, default features disabled (no async runtime/logging). Task 1.2.3 calls for pure-Rust mDNS; SRS reference §1 explicitly names mdns-sd-class crates. Apache-2.0 OR MIT; no Bonjour/Avahi runtime dependency. Context7 returned only an unrelated Go library twice; API details verified against the downloaded 0.21.4 crate source instead.
- **Design:** explicit advertise(host, blend) on ControlServer; same call updates metadata. Restrict addresses/interfaces to the listener bind family/address; use stable host-ID plus bound TCP port for DNS-safe unique labels. Surface asynchronous daemon errors, validate both records before replacing either, and return shutdown errors rather than hiding them.
- **Orientation:** clean tree, main 12 ahead, no LOOP_STOP; existing Phase 1 owner waiver applies. LSP references unavailable; exact caller search used.
- **Implemented:** `native/vcam-net/src/discovery.rs` (new): owned `ServiceDaemon`; `_vcam-ctl._tcp` and `_vcam._udp` records built together (invalid metadata leaves the old pair), actual bound ports in SRV and TXT (`vcp=1`, `blend`, `host`, `tcp`, `udp`), addresses limited to the listener's bind address/family, unique labels `vcam-<host_id hex>-<tcp port>`, async daemon errors surfaced, shutdown acknowledgement bounded to 500 ms with errors returned, withdrawal on drop. `ControlServer::advertise(host, blend)` (`control.rs:203`) starts/updates; `discovery_error()` (`:226`); `stop()` (`:282`) withdraws and now returns `io::Result<()>`; advertising after stop is `NotConnected`. `docs/protocol/vcp.md:47` documents the DNS-SD contract.
- **Files changed:** `native/vcam-net/{Cargo.toml,src/discovery.rs,src/control.rs,src/lib.rs,tests/control_server.rs}`, `native/Cargo.lock`, `docs/protocol/vcp.md`, `IMPLEMENTATION_PROGRESS.md` (FR-UX-001/002, PR-001..003/006, NET-001, NFR-REL-002, NFR-SEC-001 anchors), `docs/LOOP_LOG.md`.
- **Commands run:**
  - Throwaway `examples/discovery_smoke.rs` (removed afterwards) on real multicast: a Rust browser resolved both services with correct ports/TXT; macOS `dns-sd -L` independently resolved the TCP service and showed the updated TXT; invalid metadata was rejected without replacing records; a loopback-bound server advertised only its own address; stop withdrew both (38 ms), same ports re-enabled, drop withdrew. Output: `DISCOVERY_SMOKE_OK ... bonjour=true stop_ms=38 withdrawn=true reenable=true drop=true`.
  - `cargo fmt --check`, `cargo clippy --all-targets -D warnings`: clean. `cargo test`: 45 passed, 0 failed (including the new stopped-server advertise refusal).
  - `pytest BlenderAddOn/tests`: 12 passed. `tools/gen_testdata.py --check`: up to date (17 files).
  - maturin wheel + extension install + headless Blender 5.2.2: `VCAM_NATIVE_OK 0.1.0`, exit 0.
  - `xcodebuild test` (iPhone 17 Pro sim): 11 tests, 0 failures.
- **Not verified:** Windows/Linux multicast at runtime (CI only compiles/tests loopback there); iOS discovery (1.4.3); Python/Blender wiring (1.2.5).
- **Blocked:** none.
- **Next task:** 1.2.4 — clock sync estimator (CLOCK reply matching, offset/jitter). No second task started.
- **Owner actions:** push local commits for cross-platform CI (this commit makes 13 ahead); review the new pinned dependency `mdns-sd 0.21.4` (Apache-2.0 OR MIT); existing swift-srp decision and getrandom review remain pending.

## 2026-09-24 — Iteration 27 — 1.2.4 (NET-003) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 13 ahead of `origin`; latest CI run is still `35958600428` (no push since). Existing Phase 1 owner waiver applies.
- **Scope:** host-side `CLOCK` reply matching and offset/jitter estimation, reported in stats. Not included: Python exposure (1.2.5), device replies (1.4.x). No new dependencies.
- **Design (vcp.md §6.3, now spelled out there):** pure `ClockEstimator` in `vcam-protocol`.
  - Replies must match one of the last 4 requests; a match is consumed, so a repeat is rejected. The reply must arrive < 2 s after `t1`; `t4 < t1`, `t3 < t2` or δ < 0 is invalid.
  - The window is the last 8 accepted samples. Offset/δ come from the lowest-δ sample, newest on ties; jitter is the integer RMS of θ around it.
  - `vcam-net` keeps one estimator per session. `t4` is read on receipt, and a request is recorded only after `send_to` succeeds. `ReceiverStats` gains `clock`/`clock_rejected`, and `UdpReceiver`/`ControlServer::host_clock_ns()` exposes the host clock that `ClockEstimate::host_time_ns` maps capture times onto.
- **Golden vectors:** `testdata/vcp/clock_sync.json` (new; 20 replies). Generated by an independent Python reference in `tools/gen_testdata.py` (`build_clock_sync`), which self-checks the tie and eviction effects. Cases: asymmetric paths, odd negative θ (truncation), duplicate, unrequested, evicted, exactly 2 s (expired), just under 2 s, t3 < t2, negative δ, best sample leaving the window, and an equal-δ tie.
- **Files changed:** `native/vcam-protocol/src/{clock.rs (new),lib.rs}`, `native/vcam-protocol/tests/golden.rs`, `native/vcam-net/src/{udp.rs,control.rs}`, `native/vcam-net/tests/udp_receiver.rs`, `tools/gen_testdata.py`, `testdata/vcp/clock_sync.json` (new), `docs/protocol/vcp.md` §6.3, `IMPLEMENTATION_PROGRESS.md` (NET-003, NFR-QA-003), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo fmt --check`: OK. `cargo clippy --all-targets -D warnings`: clean. `cargo test`: 47 passed, 0 failed.
  - Mutation check on `clock.rs` (each restored afterwards): picking the oldest on ties, not consuming `t1`, `>` instead of `>=` for the 2 s timeout, and not checking `t3 < t2`. Each failed `clock_sync_matches_vectors`. The first vector version missed "not consumed" (its duplicate targeted an already-evicted request); I fixed the vector to replay the newest answered reply, and the mutant is now caught.
  - `clock_replies_estimate_offset_and_reject_replays` (real loopback sockets, device clock 3.5 s ahead): 10/10 runs passed.
  - `pytest BlenderAddOn/tests`: 12 passed. `tools/gen_testdata.py --check`: up to date (18 files).
  - maturin wheel + extension install + headless Blender 5.2.2: `VCAM_NATIVE_OK 0.1.0`, `SMOKE_EXIT=0`.
  - `xcodebuild test` (iPhone 17 Pro sim): 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:** real-device clock behaviour (O-1, 1.4.2) and Wi-Fi jitter (S-4); both need the owner/device.
- **Blocked:** none.
- **Next task:** 1.2.5 — Python API (`Session.start(port)`, `.latest_pose()`, `.stats()`, `.pairing_code()`, `.stop()`), releasing the GIL, panics → exceptions, clean shutdown on unregister. Likely split: 1.2.5a PyO3 `Session` over `ControlServer` plus headless-Blender test; 1.2.5b add-on register/unregister wiring. No second task started.
- **Owner actions:** push (this commit makes 14 ahead); pending: the `mdns-sd`/`getrandom` dependency reviews and the `swift-srp` decision.

## 2026-09-24 — Iteration 28 — 1.2.5a (C-2, NFR-REL-001, NFR-REL-002, FR-BL-002) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 14 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Split of 1.2.5** (too big for one iteration):
  - **1.2.5a (this):** PyO3 `vcam_native.Session` over `ControlServer`: GIL release, panic → exception, clean stop, verified in headless Blender.
  - **1.2.5b (next):** add-on wiring: a stable `host_id` and config directory (Blender user config), start on enable, `stop()` in `unregister()`, and a `bpy.app.timers` poll. The Python FreeD path is still replaced in 1.3.1.
- **API (`native/vcam-py/src/lib.rs`):**
  - `Session.start(port, config_dir, host_id, bind="0.0.0.0", udp_port=0)`, `stop()` (idempotent), `running()`, `port()`, `udp_port()`.
  - Pairing and discovery: `advertise(host, blend)`, `discovery_error()`, `enable_pairing()`, `disable_pairing()`, `pairing_code()`.
  - Reads and status: `poll_event()`, `latest_pose()`, `stats()`, `host_clock_ns()`, `update_status(...)`. Also `NativeError`, and the private `_panic_probe()` test hook (like `_frame_probe`).
  - Plan names covered: `start`/`latest_pose`/`stats`/`pairing_code`/`stop`. The rest is what 1.2.5b/1.3.x need to pair, advertise and acknowledge. `latest_control` is deferred to FR-BL-005 (1.3.x).
- **Decisions:**
  - Panics become `NativeError(RuntimeError)` via `catch_unwind`, because PyO3's default `PanicException` derives from `BaseException` and escapes `except Exception` in add-on code (confirmed in the PyO3 0.29.2 source, `src/panic.rs:14`).
  - `io::ErrorKind::InvalidInput` maps to `ValueError`; every other kind uses PyO3's `OSError` family (checked against `src/err/impls.rs:52-66`).
  - `start` and `stop` release the GIL with `Python::detach` (`src/marker.rs:562`). `stop` takes the server out of the mutex first. `advertise` keeps the GIL: it only queues registrations, and releasing the GIL while holding the session lock could deadlock a second Python caller (found and fixed before the first build).
  - The pyclass is `frozen` with `Mutex<Option<ControlServer>>`, so it's `Send + Sync` without `unsendable`. No new dependencies.
- **Files changed:** `native/vcam-py/src/lib.rs`, `tests/blender/session_native.py` (new), `.github/workflows/ci.yml` (`blender-smoke` runs `session_native.py` after `smoke_native.py`), `IMPLEMENTATION_PROGRESS.md` (FR-BL-002, NFR-REL-001, NFR-REL-002, NFR-QA-001), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo fmt --check`: OK. `cargo clippy --all-targets -D warnings`: clean. `cargo test`: 48 passed, 0 failed (new `guard_turns_panics_into_errors_and_passes_results_through`).
  - maturin wheel + extension install + headless Blender 5.2.2: `smoke_native.py` gave `VCAM_NATIVE_OK 0.1.0`, exit 0. `session_native.py` gave `VCAM_SESSION_OK tcp=62213 udp=50488 stop_ms=50 panic=NativeError refused=ConnectionRefusedError`, exit 0. It covers real bind/connect, `ValueError`/`OSError` mapping (short host_id, bad IP, port in use, oversize TXT, 64-byte camera name, `update_status` with no session), pairing code, stats/pose/event before a device, advertise/update, panic caught by `except Exception` with the session still alive, stop < 1 s, idempotent stop, `RuntimeError` after stop, refused TCP after stop, and same-port restart.
  - Mutation check in Blender (rebuilt each time, source restored and `cmp`-verified): removing the panic guard, `stop()` leaving the server running, and `InvalidInput` staying `OSError`. All 3 failed `session_native.py` (exit 1).
  - `actionlint ci.yml`: OK. `pytest BlenderAddOn/tests`: 12 passed. `tools/gen_testdata.py --check`: up to date (18 files). `xcodebuild test` (iPhone 17 Pro sim): 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:**
  - `latest_pose()`/`poll_event()`/`stats()` with a real paired device. The Python side has no device client yet; the Rust paths are covered by `vcam-net` tests. The first end-to-end check through Python is the fake iPhone (1.2.7) / integration test (1.3.5).
  - That the GIL is actually released during `stop` isn't observed from Python (stop takes about 50 ms). The code uses `detach`.
  - `session_native.py` on Windows/Linux CI (awaiting push).
- **Blocked:** none.
- **Next task:** 1.2.5b — add-on register/unregister wiring of `Session` (stable host_id + config dir in Blender's user config, `stop()` on unregister, main-thread timer poll), tested headlessly with enable → disable → re-enable. No second task started.
- **Owner actions:** push (this commit makes 15 ahead; CI will run `session_native.py` on 3 OSes). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-24 — Iteration 29 — 1.2.5b (NFR-REL-002, NFR-SEC-003, NFR-SEC-001, FR-BL-002, C-2) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 15 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Scope:** add-on lifecycle only.
  - In: a stable host ID and pairing directory, start/stop operators, a main-thread event poll, and a stop in `unregister()`.
  - Not in: the N-panel toggle and pairing-code UI (1.3.3), replacing the FreeD path and applying poses (1.3.1/1.3.2), and `load_post` re-advertising after a file reload (1.3.4).
- **Design:**
  - **`BlenderAddOn/core/session.py` (new):** one `vcam_native.Session` per process. Nothing listens until `vcam.session_start` runs (NFR-SEC-003).
  - **Storage:** `config_dir()` is `bpy.utils.extension_path_user(__package__, create=True)`, which survives extension updates (confirmed in `bpy/utils/__init__.py:952-998`). It holds `host_id` (16 bytes, created once atomically, mode 0600; a damaged file raises `ValueError` rather than silently invalidating paired devices) and `vcam-pairings/`.
  - **Start:** `start()` advertises the hostname and `.blend` basename. A DNS-SD failure is recorded in `state.last_error` and doesn't abort the session: manual host entry still works (FR-UX-001).
  - **Poll:** a persistent `bpy.app.timers` callback (0.1 s, at most 64 events per tick, never raises) updates `SessionState` in place.
  - **Stop:** `stop()` unregisters the timer, then stops the session; it never raises. `unregister()` calls it before any class is unregistered.
  - **Defaults:** operators `vcam.session_start(port=47000, bind="0.0.0.0")` and `vcam.session_stop`. TCP default 47000 is a stable port for manual entry; UDP uses any free port, which is sent in `SESSION_CHALLENGE`.
- **Files changed:** `BlenderAddOn/core/session.py` (new), `BlenderAddOn/operators/session.py` (new), `BlenderAddOn/operators/__init__.py`, `BlenderAddOn/__init__.py`, `BlenderAddOn/tests/test_session_host_id.py` (new), `tests/blender/addon_session.py` (new), `.github/workflows/ci.yml` (`blender-smoke` also runs `addon_session.py`), `IMPLEMENTATION_PROGRESS.md` (FR-UX-001/002, FR-BL-002, NET-002, NFR-REL-002, NFR-SEC-001, NFR-SEC-003 split from 002, NFR-QA-001), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `pytest BlenderAddOn/tests`: 14 passed (2 new). The first run hit a collection error: the new test imported `BlenderAddOn.core` instead of the existing `sys.path` convention. Fixed.
  - Headless Blender 5.2.2 with a fresh wheel and extension install:
    - `smoke_native.py`: `VCAM_NATIVE_OK 0.1.0`.
    - `session_native.py`: `VCAM_SESSION_OK ... stop_ms=55`.
    - `addon_session.py`: `VCAM_ADDON_SESSION_OK tcp=62440 udp=50541 disable_ms=84 host_id_stable=true`. All exit 0.
  - `addon_session.py` covers: no listening after enable; start; a real TCP connect; the config dir under the user resources; host_id 16 bytes and 0600; the pairings dir; the timer registered and `_poll` returning 0.1; a second start refused by poll; disable < 1 s with the socket closed, the timer removed and the port refused; re-enable with the same host ID on the same port; the stop operator.
  - Mutation check (source restored and `cmp`-verified): `unregister` not stopping, the timer left registered, and the host ID regenerated on every start. Each failed `addon_session.py`; the last also failed 2 pytest tests.
  - `cargo fmt --check` OK; `cargo clippy -D warnings` clean; `cargo test` 48 passed, 0 failed. `actionlint` OK. `gen_testdata.py --check`: up to date (18 files). `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:**
  - The timer firing inside Blender's event loop (background scripts don't run timers; `_poll` was called directly).
  - Behaviour with a connected device (needs 1.2.7).
  - The new Blender tests on Windows/Linux CI (awaiting push).
- **1.2.5 status:** 1.2.5a and 1.2.5b are both done, so task 1.2.5 is complete.
- **Blocked:** none.
- **Next task:** 1.2.6 — optional One-Euro smoothing in Rust (FR-BL-006). No second task started.
- **Owner actions:** push (this commit makes 16 ahead; CI will run `session_native.py` and `addon_session.py` on 3 OSes). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 30 — 1.2.6 (FR-BL-006) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 16 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Scope:** native One-Euro smoothing with a per-session toggle, keeping raw data (FR-BL-006, SHOULD). Not in: N-panel UI (1.3.3), applying poses (1.3.2), and device tuning of the defaults (needs real ARKit data). No new dependencies.
- **Design:** `native/vcam-net/src/smooth.rs` (new). One-Euro (Casiez et al., CHI 2012): `alpha = 1/(1 + tau/dt)`, `tau = 1/(2π·cutoff)`, `cutoff = min_cutoff + beta·|filtered speed|`.
  - **Position:** 3 scalar channels.
  - **Orientation:** `q` is flipped into the last output's hemisphere, speed is angle/dt, and the output is slerped by alpha.
  - **Timing:** dt comes from `capture_time_ns` (device clock), not arrival time. A restart at the raw sample happens on dt > 0.5 s, a non-increasing capture time, or a `tracking_state` change.
  - **Defaults (untuned):** position min_cutoff 1 Hz, beta 2 per m/s; rotation 1 Hz, 0.5 per rad/s; d_cutoff 1 Hz.
  - **Receiver:** `UdpReceiver::set_smoothing(Option<Smoothing>)` validates the parameters (`InvalidInput` becomes `ValueError` in Python). A new `State::reset()` keeps the setting through expiry/revocation/replacement/stop and clears the filter; set_session copies the setting.
  - **Raw kept:** `PoseSample` gains `smoothed` (equal to `pose` when off); `pose` stays raw.
  - **Python:** `Session.set_smoothing(enabled, position_min_cutoff=1.0, position_beta=2.0, rotation_min_cutoff=1.0, rotation_beta=0.5, d_cutoff=1.0)`, `smoothing()`, and `latest_pose()` gains `smoothed_position`/`smoothed_orientation`.
- **Files changed:** `native/vcam-net/src/{smooth.rs (new),udp.rs,control.rs,lib.rs}`, `native/vcam-net/tests/udp_receiver.rs`, `native/vcam-py/src/lib.rs`, `tests/blender/session_native.py`, `IMPLEMENTATION_PROGRESS.md` (FR-BL-006 split from FR-BL-007), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo fmt --check` OK; `cargo clippy --all-targets -D warnings` clean; `cargo test`: 56 passed, 0 failed (8 new filter unit tests, 1 new loopback test).
  - **Mutation check, round 1:** rotation cutoff ignoring speed, position cutoff ignoring speed, and no capture-time-reversal restart were caught. Three survived:
    - removing the hemisphere flip (the test used exactly −q, which slerp handles by accident);
    - `reset()` dropping the setting (only `set_session`'s explicit copy was exercised);
    - re-setting the parameters not restarting the filter.
  - **Round 2:** I strengthened the tests (−yaw(1.1) after yaw(1.0) must land in [1.0, 1.1); a `clear_session` path; re-set then raw passthrough). All 3 are now caught, and the sources were restored and `cmp`-verified.
  - `pytest BlenderAddOn/tests`: 14 passed. `gen_testdata.py --check`: up to date (18 files).
  - Headless Blender 5.2.2 (fresh wheel and install): `VCAM_NATIVE_OK 0.1.0`; `VCAM_SESSION_OK ... stop_ms=50` (now also covers smoothing off by default, the defaults readback, `ValueError` on 0 cutoff and NaN beta keeping the old setting, and turning it off); `VCAM_ADDON_SESSION_OK ... disable_ms=63`. All exit 0.
  - `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:** the filter on real ARKit motion; the default parameters are unverified starting points. Smoothed output through Python with a connected device (needs 1.2.7).
- **Blocked:** none.
- **Next task:** 1.2.7 — `vcam-fake-iphone` binary: pairs, then streams scripted motion (pan, tilt, dolly, crane) from `testdata/`. No second task started.
- **Owner actions:** push (this commit makes 17 ahead). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 31 — 1.2.7 (SRS §11, XP-002, NFR-QA-003) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 17 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Scope:** the `vcam-fake-iphone` binary plus the scripted motion in `testdata/`. Not in: the Blender `matrix_world` CI test (1.3.5), CONTROL_STATE changes over time (scale/locks/origin, later with FR-CTL), and impairment/soak (NFR-REL-003).
- **Motion vectors** (`tools/gen_testdata.py` `build_motion`): canonical axes at 60 Hz, 390 frames, written as `testdata/motion/scripted.json` (frames plus keyposes with `matrix_world`, for Python/Blender) and `scripted.bin` (the same f32 frames in a small LE format, so the Rust binary needs no JSON dependency).
  - **Moves:** a level start (looking +Y), then pan 90° left, tilt 30° down, dolly 2 m, crane 1.5 m. Each is a 1 s move followed by a 0.5 s hold; each keypose is the last hold frame.
  - **Self-checks:** the look direction at start/pan/tilt and the final position. `--check` now also covers `testdata/motion/`.
- **Binary** (`native/vcam-fake-iphone/src/main.rs`), with args `--host --state [--code] --motion [--rate] [--linger] [--name]`:
  - **Pairing:** with `--code`, a new random device_id, SRP pairing (CSPRNG `a` and nonces), and `device_id‖PK` saved atomically (0600). Without a code, the stored pairing is loaded.
  - **Session:** verifies the host proof, then opens a device `Endpoint`.
  - **Streaming:** frames at the rate (the default is the file's), seq from 1, and `capture_time_ns` from its own monotonic clock at +1000 s. It sends a complete CONTROL_STATE at 2 Hz, answers CLOCK with t2 at receipt and t3 at send, and records the newest STATUS.
  - **Output:** `FAKE_IPHONE_PAIRED` / `FAKE_IPHONE_SESSION` / `FAKE_IPHONE_DONE ...` on stdout; errors go to stderr with exit 1.
- **Dependencies:** `getrandom = "=0.4.3"`, the same pinned crate `vcam-net` already uses, so nothing new enters the lockfile. `vcam-net` moved to dev-dependencies (tests only).
- **Files changed:** `tools/gen_testdata.py`, `testdata/motion/scripted.{json,bin}` (new), `native/vcam-fake-iphone/{Cargo.toml,src/main.rs,tests/fake_iphone.rs (new)}`, `native/Cargo.lock`, `IMPLEMENTATION_PROGRESS.md` (XP-002, NFR-QA-003), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo fmt --check` OK; `cargo clippy --all-targets -D warnings` clean; `cargo test`: 59 passed, 0 failed. New tests:
    - a motion-file parser unit test (390 frames, last position, truncated/magic/count rejected);
    - `pairs_streams_the_script_answers_clock_and_reconnects_without_a_code`: Paired, SessionStarted, SessionEnded; last pose seq 390 at [-2, 0, 3.1]; full CONTROL_STATE; ≥ 2 clock replies; offset > 900 s; STATUS applied_pose_seq 42 / ack 1 / camera Cam seen by the device; the stored pairing reconnects with no Paired event;
    - `wrong_code_fails_cleanly_and_stores_nothing`.
  - The first run failed one assertion: SessionEnded arrives just after the process exits, and the test stopped draining events too early. Fixed in the test by waiting up to 2 s. Then 5/5 repeated runs passed.
  - **Mutation check** (restored and `cmp`-verified): no CLOCK replies, pairing not stored, and no CONTROL_STATE were all caught. The last needed a second attempt, because my first `sed` didn't match the rustfmt-wrapped line.
  - **One-off Blender end to end** (throwaway script, deleted): headless Blender 5.2.2 ran `vcam_native.Session` (smoothing on) against the real binary: `VCAM_E2E_OK events=['paired', 'session_started'] seq=390 clock_offset_s=999.595 jitter_us=16 poses_applied=390`, with all `latest_pose()` keys, smoothed values settled on the final hold, and `update_status` reaching the device. This closes the 1.2.5a gap "Python reads with a connected device".
  - `pytest BlenderAddOn/tests`: 14 passed. `gen_testdata.py --check`: up to date (20 files). Blender: `VCAM_NATIVE_OK 0.1.0`, `VCAM_SESSION_OK ... stop_ms=53`, `VCAM_ADDON_SESSION_OK ... disable_ms=76`, all exit 0. `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:** the binary on Windows/Linux (CI runs `cargo test` there once pushed).
- **Section 1.2 status:** 1.2.1–1.2.7 are done, so section 1.2 is complete.
- **Blocked:** none.
- **Next task:** 1.3.1 — replace `core/udp_client.py` + `core/freed_parser.py` with `vcam_native` and delete the FreeD path (PR-FD-001, FR-BL-002). No second task started.
- **Owner actions:** push (this commit makes 18 ahead). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 32 — 1.3.1 (PR-FD-001, FR-BL-002, ARC-003, FR-BL-003) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 18 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Scope:** replace the Python FreeD transport with `vcam_native` and delete the FreeD path. A minimal apply step replaces the FreeD apply. Not in: the `VCam_Origin` rig, scale and locks, and CONTROL_STATE apply (1.3.2); the full N-panel with pairing code (1.3.3); reload/undo handling (1.3.4); the CI integration test (1.3.5).
- **Deleted** (kept in git history): `BlenderAddOn/core/{freed_parser,udp_client,transform}.py`, `operators/tracking_receiver.py`, `tests/test_freed_parser.py`, `tests/test_transform.py`, an empty `tests/test_data/`, and the root `tests/freed_test_sender.py`. The scene properties lost the FreeD-only fields (Euler order, zoom/focus encoder mapping, debug readbacks, `is_tracking`). `host` became `bind_address`, and the default port is now 47000 (TCP).
- **New `BlenderAddOn/core/apply.py`:**
  - `pose_matrix` is `Translation(position) @ Quaternion((w, x, y, z))`: canonical is Blender's axes, so there's no conversion.
  - `target_camera` is the VCam target, else the scene camera; camera objects only.
  - `Applier.tick` applies the smoothed pose when `seq` advances (reset per session) and publishes STATUS with the actual applied seq, `error_code` 0/1 (no camera) and the camera name cut to 63 UTF-8 bytes. STATUS goes out at once on camera/error change and otherwise at most every 0.5 s, so a 60 Hz apply doesn't make 60 Hz STATUS.
- **`core/session.py`:** the timer poll now runs at 60 Hz and calls the applier after draining events. `control_ack` stays 0 until CONTROL_STATE is applied (1.3.2).
- **UI and manifest:** `ui/panels.py` is a minimal panel (bind/port, camera, start/stop, port, device, rate/loss, last error). The manifest's network permission text is updated; Blender limits it to 64 characters, which the first build hit and I fixed.
- **Files changed:** the deletions above; `BlenderAddOn/core/apply.py` (new), `core/session.py`, `operators/__init__.py`, `properties/scene_props.py`, `ui/__init__.py`, `ui/panels.py`, `blender_manifest.toml`; `tests/blender/addon_apply.py` (new); `IMPLEMENTATION_PROGRESS.md` (summary, pytest row, ARC-003, FR-BL-002..005, UI text, PR-FD-001, NFR-QA-001, shifted `session.py` line anchors); `docs/LOOP_LOG.md`.
- **Commands run:**
  - `tests/blender/addon_apply.py` (new; runs the real fake iPhone at 120 Hz against the add-on in headless Blender 5.2.2, calling the poll itself because background scripts don't run timers): `VCAM_ADDON_APPLY_OK keyposes=5 max_err=6.30e-08 applied_pose_seq=390 camera=Camera`. All 5 keyposes match `scripted.json` `matrix_world`. The session ended cleanly, the device received STATUS with applied seq 390 and camera `Camera`, and a stub check covers no-camera error 1 and 2 Hz throttling.
  - **Mutation check** (restored and `cmp`-verified): quaternion component order, the camera name not published, and STATUS not throttled. All 3 failed `addon_apply.py`.
  - Other Blender scripts on the same fresh install: `VCAM_NATIVE_OK 0.1.0`, `VCAM_SESSION_OK ... stop_ms=59`, `VCAM_ADDON_SESSION_OK ... disable_ms=88`. All exit 0.
  - `pytest BlenderAddOn/tests`: 2 passed (down from 14: 12 FreeD tests deleted with their code). `gen_testdata.py --check`: up to date (20 files). `actionlint`: OK.
  - `cargo fmt --check` OK, clippy clean, `cargo test` 59 passed, 0 failed (no Rust changes). `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:**
  - The timer-driven apply inside Blender's GUI event loop (background scripts don't run timers).
  - The panel drawing, visually.
  - `addon_apply.py` isn't in CI yet (it needs the fake binary in the Blender job; that's 1.3.5).
- **Blocked:** none.
- **Next task:** 1.3.2 — rig: create or find `VCam_Origin` + the camera; apply the canonical pose as the camera's local transform; motion scale and axis locks from CONTROL_STATE (FR-BL-003, FR-CTL-004). No second task started.
- **Owner actions:** push (this commit makes 19 ahead). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 33 — 1.3.2a (FR-BL-003, FR-CTL-004, FR-TRK-003) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 19 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Split of 1.3.2** (too big for one iteration):
  - **1.3.2a (this):** rig math + golden vectors, the `VCam_Origin` rig in Blender, and CONTROL_STATE (scale, locks, Set origin, `control_ack`).
  - **1.3.2b (next):** `vcam-fake-iphone` control scripting (`--scale`, `--locks`, `--set-origin-at FRAME`) and the end-to-end check in Blender.
- **Semantics** (the plan puts scale and locks "on the origin/apply step"; now spelled out in `BlenderAddOn/core/rig.py`'s docstring):
  - **Relative pose:** p_rel = Rz(−ψ₀)(p − p₀), q_rel = Rz(−ψ₀)q. ψ is the heading (0 along +Y, counter-clockwise; taken from the up vector when looking straight up or down).
  - **Locks:** pan only sets p = 0, lock height sets local z = 0, and lock roll keeps the forward direction with up in the forward/world-Z plane. Lock roll does nothing when looking straight up or down.
  - **Scale:** position × motion_scale.
  - **User rig:** the user's `VCam_Origin` transform, including its own scale, composes on top. Motion scale is not written into the origin's scale, so the device never overwrites the user's placement.
  - **Set origin:** any `origin_epoch` change after the first one seen in a session, the same rule as `freshness.json`.
- **Code:**
  - `BlenderAddOn/core/rig.py` (new, pure Python): `local_pose`, `heading`, `zero_from_pose`, `remove_roll`, `Controls` (merges absent fields, ignores stale `state_seq`).
  - `core/apply.py`: `ensure_rig` (reuses the user's `VCam_Origin` or creates one at the camera's position; parents the camera with an identity inverse), the zero stored as custom properties on the origin, the camera's `matrix_basis` set to the local pose, and `control_ack` in STATUS.
  - `native/vcam-py`: `Session.latest_control()` (absent fields as None).
- **Golden vectors:** `testdata/rig/rig_cases.json` (new; 8 cases: identity, scale 10, lock roll/height/pan-only on a yaw 30/pitch −20/roll 15 pose, Set origin then walk, combined, straight-down lock roll). Built by `tools/gen_testdata.py` `build_rig` with 3×3 matrices, independent of the quaternion code. It self-checks the walk result against a hand derivation and lock roll against the analytic no-roll camera. Inputs are rounded before the expected values are computed.
- **Files changed:** `BlenderAddOn/core/{rig.py (new),apply.py}`, `BlenderAddOn/tests/test_rig.py` (new), `native/vcam-py/src/lib.rs`, `tools/gen_testdata.py`, `testdata/rig/rig_cases.json` (new), `tests/blender/addon_apply.py`, `IMPLEMENTATION_PROGRESS.md` (FR-CTL-004 split, FR-TRK-003, FR-BL-003, pytest row, NFR-QA-003, anchors), `docs/LOOP_LOG.md`.
- **Commands run:**
  - Generator: its first run failed my own hand-derived check (I'd written local x = +0.5; left of a camera facing −X is local −X, so −0.5). I fixed the check and note, not the math. The first pytest run failed one case by about 1e-9 because the expected values were computed from unrounded inputs; I fixed the generator to round inputs first.
  - `pytest BlenderAddOn/tests`: 12 passed (8 rig vectors, the origin_epoch vector, control merging, 2 host ID).
  - `addon_apply.py` (fake iPhone, headless Blender 5.2.2, user rig at (1, 2, 0.5), yaw 90°, scale 2): `VCAM_ADDON_APPLY_OK keyposes=5 max_err=1.79e-07 rig_err=1.12e-07 applied_pose_seq=390 camera=Camera`, with control_ack=1 on the device. The first run failed on world matrices: the local transforms were exact, but a child's `matrix_world` is only re-evaluated by the depsgraph, so the test now calls `view_layer.update()` before reading it (the GUI evaluates on every redraw). Also covered: the stub-driven "combined" vector (Set origin via an epoch change, then scale 2 + locks 3) and the no-camera STATUS.
  - **Mutation check** (restored and `cmp`-verified): heading sign, lock height ignored, scale ignored, lock roll ignored, and the first epoch counted as a reset all failed pytest; the zero not read back, control_ack always 0, and the user rig ignored all failed `addon_apply.py`. 8/8 caught.
  - Blender `smoke_native`/`session_native`/`addon_session` pass. `cargo fmt --check`/clippy clean; `cargo test` 59 passed. `gen_testdata.py --check`: up to date (21 files). `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:** CONTROL_STATE changes over the real wire into Blender (1.3.2b); the rig in the GUI.
- **Blocked:** none.
- **Next task:** 1.3.2b — fake-iPhone control scripting and the Blender end-to-end check of scale, locks and Set origin. No second task started.
- **Owner actions:** push (this commit makes 20 ahead). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 34 — 1.3.2b (FR-CTL-004, FR-TRK-003, FR-BL-003) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 20 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Scope:** fake-iPhone control scripting plus the end-to-end check in Blender of scale, locks and Set origin over the real wire. No new dependencies.
- **`vcam-fake-iphone`:**
  - New options: `--scale S` (validated to [0.001, 1000] as in vcp.md §6.2), `--locks FLAGS` (bits 0-2 only), and `--set-origin-at FRAME`.
  - Behaviour: the first complete CONTROL_STATE carries the scale and locks with epoch 0. At the given frame the fake iPhone presses Set origin: `state_seq` + 1 and epoch + 1, sent at once before that frame and then every 500 ms.
- **Vectors:** `tools/gen_testdata.py` `build_rig(motion)` adds `scripted_tilt`, `scripted_dolly` and `scripted_crane`: the keyposes after Set origin at frame 105, inside the pan hold where the pose equals the pan keypose, with scale 2 and lock height. It also adds a `scripted` block (set_origin_at, scale, locks, case names) and self-checks that the dolly comes out as local (0, 4, 0), i.e. 2 m along the zeroed heading × 2.
- **Files changed:** `native/vcam-fake-iphone/{src/main.rs,tests/fake_iphone.rs}`, `tools/gen_testdata.py`, `testdata/rig/rig_cases.json`, `tests/blender/addon_apply.py` (the fake runs refactored into `run_fake()`; run 2 reconnects with the stored pairing and scripted controls), `IMPLEMENTATION_PROGRESS.md` (FR-CTL-004, FR-TRK-003, FR-BL-003, pytest row, NFR-QA-003), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo test`: 60 passed, 0 failed, including the new `scripted_controls_reach_the_host_in_order`: the host saw exactly [(1, 2.0, 5, 0), (2, 2.0, 5, 1)], and `--scale 5000` was rejected. `cargo fmt --check` OK; clippy clean.
  - `pytest BlenderAddOn/tests`: 15 passed (the 3 new scripted vectors through `rig.py`). `gen_testdata.py --check`: up to date (21 files).
  - Headless Blender 5.2.2 `addon_apply.py`: `VCAM_ADDON_APPLY_OK keyposes=5 max_err=1.79e-07 scripted_err=5.96e-08 rig_err=1.12e-07 applied_pose_seq=390 camera=Camera`. Run 2's device-side `control_ack=2`.
  - **Mutation check** (restored and `cmp`-verified): the fake iPhone sending Set origin without an epoch bump, and the add-on not resetting its controls/apply state per session. Both failed `addon_apply.py`.
  - Other Blender scripts: `VCAM_NATIVE_OK 0.1.0`, `VCAM_SESSION_OK ... stop_ms=54`, `VCAM_ADDON_SESSION_OK ... disable_ms=67`. `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **1.3.2 status:** 1.3.2a and 1.3.2b are both done, so task 1.3.2 is complete.
- **Not verified:** the rig in the interactive GUI; iOS-side controls (1.4.4).
- **Blocked:** none.
- **Next task:** 1.3.3 — N-panel: session toggle, pairing code, device, stats, camera picker, origin reset, scale/locks (FR-BL-004). No second task started.
- **Owner actions:** push (this commit makes 21 ahead). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 35 — 1.3.3 (FR-BL-004, FR-BL-006, FR-TRK-003) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 21 ahead of `origin`; no new CI run. Existing Phase 1 owner waiver applies.
- **Scope:** the full N-panel for FR-BL-004 plus the operators and state it needs. Not in: FR-TRK-002 "hold the last good pose while limited" (not in the 1.3.3 row), FR-BL-007 robustness (1.3.4), the CI integration test (1.3.5).
- **Decisions:**
  - Scale and locks are shown read-only. The iPhone owns them as idempotent CONTROL_STATE (FR-CTL-009), and a second writer in Blender would split the source of truth.
  - Set/Clear Origin act on the host-side zero stored on `VCam_Origin`, so they don't conflict with the device.
  - Latency is the pose leg: host clock − (capture − clock offset) when the pose is applied.
  - The panel redraws at 4 Hz from the session poll, because panels otherwise redraw only on user events.
  - Smoothing is a scene property: it's applied at session start and when toggled.
- **Code:**
  - `BlenderAddOn/core/status.py` (new, pure): tracking/scale/locks/code labels and `pose_latency_ms`.
  - `core/apply.py`: `clear_zero`; `Applier.request_set_origin`/`reapply`; `tick` returns the applied pose.
  - `core/session.py`:
    - new state fields: tracking_state, latency_ms, clock_jitter_ms;
    - entry points `applier()`, `set_origin()`, `clear_origin()`, `set_smoothing()`;
    - latency computed after each apply;
    - the 4 Hz `_tag_redraw`;
    - smoothing applied at start.
  - Operators `vcam.pairing_start`, `vcam.pairing_cancel`, `vcam.origin_set`, `vcam.origin_clear` (with polls); the scene property `smoothing`; `ui/panels.py` rewritten.
- **Files changed:** `BlenderAddOn/core/{status.py (new),apply.py,session.py}`, `BlenderAddOn/operators/{__init__.py,session.py}`, `BlenderAddOn/properties/scene_props.py`, `BlenderAddOn/ui/panels.py`, `BlenderAddOn/tests/test_status.py` (new), `tests/blender/addon_panel.py` (new), `IMPLEMENTATION_PROGRESS.md` (FR-BL-004 Done, FR-BL-006, FR-UX-001/002, pytest row, NFR-QA-001, re-anchored `session.py`/`apply.py` line numbers), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `pytest BlenderAddOn/tests`: 19 passed (4 new).
  - `tests/blender/addon_panel.py` (headless, fake iPhone at 60 Hz): `VCAM_ADDON_PANEL_OK latency_ms=2.88 jitter_ms=0.000 pairing=start/cancel/start set_origin=zeroed clear_origin=raw smoothing=toggled`. The first run measured 0.57 ms; both are loopback.
  - **GUI visual check** (Blender 5.2.2 with its window, timer-driven throwaway script, deleted afterwards): `GUI_PANEL_OK distinct_camera_positions=17 parent=VCam_Origin latency=11.780312 tracking=5`. Two screenshots were inspected:
    - pairing: "Pairing code 045 479", Cancel Pairing, Waiting for the iPhone, scale 1:1, locks None, Set/Clear Origin disabled;
    - streaming: Fake iPhone, Tracking Normal, 60 Hz loss 0.0 %, latency 11.8 ms (jitter 0.01 ms), scale 1:10, locks Roll (from `--scale 10 --locks 2`), origin VCam_Origin, Set Origin enabled, Clear disabled.
    The factory-startup splash partly covers the left edge of the panel text. This run is also the first check of the session timer driving the camera in the real event loop.
    Its final `applied_pose_seq=244` comes from the script itself: it blocked Blender's main thread in `communicate()` during the fake's linger, so this isn't a product issue.
  - **Mutation check** (restored and `cmp`-verified): latency sign (pytest), Set Origin a no-op, and the smoothing toggle not wired (`addon_panel.py`). All 3 caught.
  - Blender `smoke_native`, `session_native`, `addon_session` and `addon_apply` pass. `cargo fmt --check`/clippy clean; `cargo test` 60 passed. `gen_testdata.py --check`: up to date. `xcodebuild test`: 11 tests, 0 failures, `** TEST SUCCEEDED **`.
- **Not verified:** the panel on Windows/Linux; latency on real Wi-Fi (S-4, owner/device).
- **Blocked:** none.
- **Next task:** 1.3.4 — robustness: file reload (`load_post`), undo, camera deleted or renamed (FR-BL-007). No second task started.
- **Owner actions:** push (this commit makes 22 ahead). Pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 36 — 1.3.4 (FR-BL-007, NET-004) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 22 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **API probes (headless Blender 5.2.2, throwaway):**
  - `bpy.app.handlers.persistent(f)` returns `f` and marks it.
  - `undo_post`, `redo_post` and `load_post` exist and fire in background mode (undo args are `(scene, None)`; load args are `(filepath, None)`).
  - Persistent timers and handlers survive `open_mainfile` and `read_homefile`.
  - After `ed.undo()` an old Python reference raises `ReferenceError: StructRNA of type Object has been removed`.
  - `object.delete` on a camera that a PointerProperty uses: the object stays in `bpy.data` with 1 user and `users_scene == ()`, and `scene.camera` still names it. `bpy.data.objects.remove` clears the pointer to None.
  - A renamed object keeps its `session_uid` and the pointer follows it.
- **Bug found:** before this change, a camera deleted in the UI kept being "driven" as an invisible orphan, and STATUS told the device everything was fine. A renamed `VCam_Origin` made the add-on create a second rig and re-parent the camera to it (the camera jumped).
- **Code:**
  - `core/apply.py`: `camera_status(scene)` returns (camera, warning) and requires the camera to be in the scene. A deleted target is not replaced by the scene camera. `target_camera` wraps it. `find_origin(camera)` looks for the camera's parent marked `vcam_origin`, then `VCam_Origin`, then any marked object. `ensure_rig` marks the rig.
  - `core/session.py`: persistent `load_post` (re-apply, the new file's smoothing, re-advertise the file name) and `undo_post`/`redo_post` (re-apply) handlers, added in `register` and removed in `unregister`. `clear_origin` uses `find_origin`.
  - `ui/panels.py`: the camera warning under the camera picker; the origin row uses `find_origin`. `operators/session.py`: the Clear Origin poll uses `find_origin`.
- **Files changed:** `BlenderAddOn/core/{apply.py,session.py}`, `BlenderAddOn/operators/session.py`, `BlenderAddOn/ui/panels.py`, `tests/blender/addon_robust.py` (new), `IMPLEMENTATION_PROGRESS.md` (FR-BL-007 Done, NET-004 reload evidence, NFR-QA-001, re-anchored `apply.py`/`session.py` line numbers), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `tests/blender/addon_robust.py` (headless, fake iPhone at 60 Hz, 30 s linger): `VCAM_ADDON_ROBUST_OK final_seq=390 rename=cam+rig undo=reapplied reload=same_session deleted=no_camera empty_file=no_camera`, exit 0. The log has no handler tracebacks.
  - **Mutation check** (restored and `cmp`-verified):
    - no re-apply on load: `reload: pose not re-applied`;
    - undo handler does nothing: `undo: pose not re-applied`;
    - `_in_scene` always true: the deleted-camera assertion failed;
    - handlers not persistent: `the reloaded file's smoothing setting was not applied`;
    - rig found by name only (no marker lookup): `a second rig was created`.
    - Removing only the parent branch of `find_origin` survives, because the marker scan finds the rig. The branch is kept as the O(1) path, so the scan isn't run every tick.
  - **Incident:** my first mutation batch ran 5 mutations in parallel on shared files and a shared backup file. That emptied `core/apply.py` and `core/session.py`, and all 5 results were invalid. I restored both from `HEAD`, re-applied the edits, snapshotted them, and re-ran the mutations one at a time. The results above come from that sequential run.
  - **GUI visual check** (Blender 5.2.2 with its window; the panel was moved to the Item tab by the throwaway script, since `region.active_panel_category` is read-only; the file was opened from the command line, so there was no splash): after deleting the target camera, the panel shows `⚠ "Camera" was deleted` under the camera picker. An earlier wording was cut off in the middle by the sidebar width, so the messages were shortened.
  - After the final edit: Blender `smoke_native`, `session_native`, `addon_session`, `addon_apply` and `addon_panel` all pass (`VCAM_ADDON_PANEL_OK latency_ms=1.24 …`). `pytest BlenderAddOn/tests`: 19 passed. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. In `native/`: `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` clean; `cargo test`: 60 passed, 0 failed (no Rust changes). `xcodebuild test`: `Executed 11 tests, with 0 failures`, `** TEST SUCCEEDED **`.
- **Not verified:** Windows/Linux; interactive Ctrl+Z in the GUI (background `ed.undo` exercises the same memfile undo and `undo_post`); a DNS-SD re-advertise of the new file name as seen by a browser (the call is made; loopback tests don't browse).
- **Blocked:** none.
- **Next task:** 1.3.5 — headless integration test with the fake iPhone that asserts `matrix_world` for each scripted keypose and runs in CI on 3 OSes (XP-002). No second task started.
- **Owner actions:** push (this commit makes 23 ahead). Still pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 37 — 1.3.5 (XP-002) — done locally; awaiting a push to run on GitHub

- **Orientation:** no LOOP_STOP; clean tree; `main` 23 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Scope:** `tests/blender/addon_apply.py` already asserts the camera's `matrix_basis` and `matrix_world` at all 5 scripted keyposes, so no new test was needed. The task was to run it, together with `addon_panel.py` and `addon_robust.py`, in CI on all 3 OSes. Not in scope: a single Blender test runner, and actually running the job on GitHub (that needs a push).
- **Change (`.github/workflows/ci.yml`, job `blender-smoke`):**
  - adds `Swatinem/rust-cache` and builds the fake iPhone with `cargo build --release --locked -p vcam-fake-iphone`;
  - exports `FAKE_IPHONE` as an absolute path into `GITHUB_ENV`, with the `.exe` suffix on Windows;
  - a new step runs the 3 integration tests with `--python-exit-code 1` in log groups.
  - The header comment and the `addon_apply.py` docstring were updated to match.
- **Files changed:** `.github/workflows/ci.yml`, `tests/blender/addon_apply.py` (docstring), `IMPLEMENTATION_PROGRESS.md` (XP-002, NFR-QA-001, NFR-QA-002), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `actionlint ci.yml`: OK.
  - **CI simulation** (throwaway `/tmp/ci_sim.py`, deleted afterwards): it extracted the `blender-smoke` job's `run:` blocks from `ci.yml` and executed them in order with `bash -eo pipefail`. It used `RUNNER_OS=macOS`, a real `GITHUB_ENV` file, `GITHUB_WORKSPACE` set to the repo (the path has spaces), and a local `--split-platforms` build of `dist/vcam_blender-0.1.0-macos_arm64.zip`. Only the download-Blender step was replaced with the local Blender. Result: all 4 blocks exit 0; the job's own steps printed `VCAM_NATIVE_OK`, `VCAM_SESSION_OK`, `VCAM_ADDON_SESSION_OK`, `VCAM_ADDON_APPLY_OK keyposes=5 max_err=1.79e-07 …`, `VCAM_ADDON_PANEL_OK latency_ms=3.37 …` and `VCAM_ADDON_ROBUST_OK …`; the simulator printed `CI_SIM_OK 4`.
  - **Mutation check:** `pose_matrix` with the translation dropped makes the integration step fail with `AssertionError: 6.199999809265137`, `block 3 exit=1`, and the loop stops. The file was restored and `cmp`-verified; `dist/` was removed.
  - `pytest BlenderAddOn/tests`: 19 passed. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. In `native/`: `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` clean; `cargo test`: 60 passed, 0 failed (summed from the `test result:` lines). `xcodebuild test`: `Executed 11 tests, with 0 failures`, `** TEST SUCCEEDED **`.
- **Not verified:** the job on GitHub's Linux and Windows runners. Possible risks there: Windows sleep resolution in the 2 ms poll loops (the keypose holds are 250 ms, so there is plenty of margin), and a slow runner overshooting the 83 ms margin before the tilt in `addon_panel.py`'s pan-hold Set Origin. If either fails after the push, read the log with `gh run view --log-failed`.
- **Blocked:** none.
- **Next task:** 1.4.x, the first iOS task in plan order (1.4.1). No second task started.
- **Owner actions:** push, so this job runs on 3 OSes (this commit makes 24 ahead). Still pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 38 — 1.4.1 (ARC-005) — done (device run owner-blocked)

- **Orientation:** no LOOP_STOP; clean tree; `main` 24 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Change:**
  - **Project:** `SWIFT_VERSION` 5.0 → 6.0 for the app and test targets. The app keeps default `MainActor` isolation. The zero-width spaces (U+200B, 2 per config) are removed from `INFOPLIST_KEY_NSCameraUsageDescription`; the built `Info.plist` has none. `TrackingPipeline.swift` and `UDPSender.swift` were added to the test target's synchronized-folder membership.
  - **`TrackingPipeline.swift` (new):** a `TrackingPipeline` actor whose executor is its own `DispatchSerialQueue`. The same queue is `ARSession.delegateQueue` and the `NWConnection` queue, so `receive` and send completions enter it with `assumeIsolated` and no hop. `start`/`stop` are synchronous (`queue.sync`), so they stay in order when issued from the main actor. `UIThrottle` gives ≤ 15 Hz: slots advance exactly one interval per publish, with 1 ms tolerance, and a clock jump restarts the cadence. There's also a `TrackingSnapshot`.
  - **`TrackingSessionController.swift`:**
    - `@Observable @MainActor` replaces `ObservableObject`/`@Published`, with `@ObservationIgnored` for the session, pipeline and receiver.
    - Snapshots arrive through `AsyncStream` (`bufferingNewest(1)`).
    - A new `ARFrameReceiver` (a `Sendable` NSObject delegate) copies the transform and timestamp out of the `ARFrame` on the pipeline queue and sends rare events to the main actor.
    - `requestAccess` uses the async API.
  - **`UDPSender`:** `nonisolated`, owned by the pipeline, runs on the pipeline's queue, and its completion is a `@Sendable (String?)`.
  - `TrackingPose` is now `nonisolated … Sendable`, and `FreeDPacketEncoder` is `nonisolated`.
  - `ContentView` uses `@Bindable` and the app uses `@State`.
- **Files changed:** `VCamIOS/VCamIOS.xcodeproj/project.pbxproj`, `VCamIOS/VCamIOS/{TrackingPipeline.swift (new),TrackingSessionController.swift,UDPSender.swift,TrackingPose.swift,FreeDPacketEncoder.swift,ContentView.swift,VCamIOSApp.swift}`, `VCamIOS/VCamIOSTests/TrackingPipelineTests.swift` (new), `IMPLEMENTATION_PROGRESS.md` (ARC-005, iOS test row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test` (iPhone 17 Pro sim, Swift 6): `Executed 14 tests, with 0 failures`, `** TEST SUCCEEDED **`, with no Swift errors or warnings in the log. `-showBuildSettings`: `SWIFT_VERSION = 6.0`.
  - The first run failed `XCTAssertFalse(anyOnMain)`. The cause was in the test: a `queue.sync` issued from the main thread runs the block on the main thread. The test now feeds frames with `queue.async` like ARKit, then waits with a `sync` barrier.
  - **Mutation check** (restored and `cmp`-verified):
    - a mutable `var` on the `Sendable` delegate: the Swift 6 build failed with `stored property 'frames' of 'Sendable'-conforming class 'ARFrameReceiver' is mutable`;
    - throttle bypassed: 1200 > 301 and window 18 > 16, among others;
    - frames not dropped after stop: 18 ≠ 2.
  - **Simulator smoke:** the app was built, installed and launched (`simctl launch` → pid; `launchctl` lists it). The screenshot shows the form, Idle, and 0 packets, so the new controller initialises without a crash. ARKit doesn't run in the simulator, so Start only reports Unsupported.
  - `pytest BlenderAddOn/tests`: 19 passed. `gen_testdata.py --check`: up to date (21 files). `cargo test`: 60 passed, 0 failed. No Rust or Python changes, so the Blender suites were not re-run.
- **Not verified (BLOCKED, needs owner/device):** ARKit frames on the delegate queue on a real iPhone (`assumeIsolated` would trap if ARKit ignored `delegateQueue`), and the UI refresh rate on the device.
- **Next task:** 1.4.2 — replace FreeD/Euler with VCP `POSE` (seq, capture time, quaternion, state) (FR-TRK-001/002, PR-FD-001). No second task started.
- **Owner actions:** push (this commit makes 26 ahead; includes the owner's `.omp/` ignore commit `468a4a3`). Run the app on an iPhone once to confirm tracking still streams (device test). Still pending: the `mdns-sd`/`getrandom` reviews and the `swift-srp` decision.

## 2026-09-25 — Iteration 39 — 1.4.2 (FR-TRK-001/002, PR-FD-001) — sub-step 1.4.2a done

- **Orientation:** no LOOP_STOP; clean tree; `main` 26 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Split:**
  - **1.4.2a (this iteration):** the device builds VCP `POSE` (seq, capture time, canonical quaternion, tracking state), seals it with a session endpoint and sends it over UDP. The FreeD/Euler code is deleted.
  - **1.4.2b:** give the pipeline a real `VCPEndpoint` from the TCP session. That needs the Swift pairing and session code (1.1.4b, **BLOCKED on the owner's `swift-srp` decision**), and it overlaps 1.4.3.
  - Until then the app runs ARKit and shows poses, with the note "Not paired with Blender: poses are shown here but not sent". Blender dropped FreeD in 1.3.1, so nothing that worked before is lost.
- **Change:**
  - `TrackingPipeline`: `start(TrackingDestination)`, where the destination is host, port and an optional `VCPEndpoint`.
    - Per frame: `seq &+= 1` (restarting at 1 each run), `capture_time_ns` = `ARFrame.timestamp`·1e9 rounded, then `VCPCoordinates.canonicalPose`, then `VCPPose`.
    - `endpoint.seal(.pose)` goes to `UDPSender` when there is an endpoint.
    - Snapshots carry the `VCPPose`.
  - New `VCP/VCPTrackingState.swift`: the vcp.md §6.1 codes from `ARCamera.TrackingState`, taken from each frame's own camera.
  - `ARFrameReceiver` passes the state with every frame.
  - Controller: `latestPose: VCPPose?` and `sessionEndpoint` (nil until 1.4.2b).
  - UI: seq, canonical position and quaternion, and the not-paired note.
  - Deleted: `FreeDPacketEncoder.swift`, `TrackingPose.swift`, `FreeDPacketEncoderTests.swift`. The test target's membership was updated.
- **Finding:** the device's ARKit → canonical quaternion for the §6.1 example is `0x3F3504F4` for w, while the golden vector (Python-rounded 0.7071068) has `…F3`: a 1-ulp difference. The host renormalises accepted quaternions, so it doesn't matter on the wire. The end-to-end test therefore checks that the datagram is authentic under the host key with the exact header, seq, time, position, state and flags, and a quaternion within 1.5e-7. No vector change is needed.
- **O-1** (which clock `ARFrame.timestamp` uses): the iOS SDK header only says "A timestamp identifying the frame". It stays open and needs a device check before the device's `CLOCK` replies are written; that part is owner/device-blocked.
- **Files changed:** `VCamIOS/VCamIOS/{TrackingPipeline.swift,TrackingSessionController.swift,ContentView.swift,VCP/VCPTrackingState.swift (new)}`, deleted `VCamIOS/VCamIOS/{FreeDPacketEncoder.swift,TrackingPose.swift}` and `VCamIOS/VCamIOSTests/FreeDPacketEncoderTests.swift`, `VCamIOS/VCamIOSTests/TrackingPipelineTests.swift`, `VCamIOS/VCamIOS.xcodeproj/project.pbxproj` (test membership), `IMPLEMENTATION_PROGRESS.md` (FR-TRK-001/002, PR-FD-001, iOS test row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test` (iPhone 17 Pro sim, Swift 6): `Executed 12 tests, with 0 failures`, `** TEST SUCCEEDED **`, no Swift warnings. New tests:
    - the golden POSE over a real loopback UDP socket;
    - an unpaired run sends nothing but still builds poses;
    - seq, capture time and state are carried, seq restarts per run, and frames after stop are dropped;
    - the tracking-state table.
  - The first runs failed: a compile error (`self` captured before init in the test socket helper, now fixed) and the byte-exact golden comparison (the 1-ulp finding above).
  - **Mutation check** (restored and `cmp`-verified):
    - seq not reset: `9 != 1`;
    - capture time in µs: `1000000 != 1000000000`, and jitter windows over the limit;
    - wrong session and keys: host `open` failed with `VCPDropReason` 5 and a header mismatch;
    - relocalizing → initializing: the table test failed.
  - **Simulator smoke:** built, installed and launched; `launchctl` lists the app. No screenshot was captured this time (the `simctl io` call wrote no file).
  - `pytest BlenderAddOn/tests`: 19 passed. `gen_testdata.py --check`: up to date (21 files). `cargo test`: 60 passed, 0 failed.
- **Not verified:** a device run and a Swift ↔ Rust live session (both need 1.1.4b and a device).
- **Blocked:** 1.4.2b (needs 1.1.4b / the `swift-srp` decision).
- **Next task:** 1.4.3 — discovery (`NetworkBrowser`), pairing UI, Keychain, `NSLocalNetworkUsageDescription`, `NSBonjourServices` (FR-UX-001/002, C-4). Its pairing part is blocked like 1.4.2b, so start with 1.4.3a: Bonjour discovery plus the Info.plist keys. No second task started.
- **Owner actions:** push (this commit makes 27 ahead). **Decide on `swift-srp`**: it now blocks the iPhone sending anything to Blender. Still pending: the `mdns-sd`/`getrandom` reviews, and a device run.

## 2026-09-25 — Iteration 40 — 1.4.3a (FR-UX-001, NET-001, C-4) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` 27 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Split of 1.4.3:**
  - **1.4.3a (this iteration):** Bonjour discovery and the Info.plist keys.
  - **1.4.3b:** selecting a listed host, connecting, pairing UI, Keychain. **BLOCKED** on Swift pairing (1.1.4b, the owner's `swift-srp` decision); added to the Blocked items table together with 1.4.2b.
- **API checked in the iOS 27 SDK** (`Network.swiftmodule/arm64e-apple-ios.swiftinterface:137-160`, `:2357-2382`, `:2406`, `:2430`): `NetworkBrowser(for:using:)`, `onStateUpdate`, `run(_:)` (the handler gets the full endpoint list on each change), `.bonjour(_:domain:includeTxtRecord:)`, `Bonjour.Endpoint.{name,txtRecord}`, `NWTXTRecord.dictionary`. `NetworkBrowser.State` is non-frozen, so the switch needs `@unknown default` (first build failed on that).
- **Change:**
  - `VCamIOS/VCamIOS/HostDiscovery.swift` (new):
    - `DiscoveredHost` parses the vcp.md §3 TXT: `host=` (falls back to the opaque instance name), `blend=` (empty = "Unsaved file"), `tcp=` (0 or invalid = nil), `vcp=` (compatible if ≥ 1, our `HELLO.proto_min`). `udp=` is ignored on purpose: the device takes the UDP port from `SESSION_CHALLENGE`.
    - `list` deduplicates per-interface duplicates and sorts by machine, then file.
    - `HostBrowser` (`@MainActor @Observable`): `run()` browses `_vcam-ctl._tcp` until its task is cancelled, then clears the list. `problem` reports waiting/failed states (for example, local-network permission denied).
  - `ContentView`: a first section "Blender on this network" (machine + file per row, "unsupported VCP version" when incompatible, a "Searching…" hint, and the problem text), browsing via `.task`. Manual host entry stays (FR-UX-001). Rows aren't tappable yet; selection comes with connecting (1.4.3b).
  - `VCamIOS/Info.plist` (new, outside the synchronized folder so it isn't copied as a resource; merged with the generated plist via `INFOPLIST_FILE`): `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_vcam-ctl._tcp]`. `_vcam._udp` isn't listed because the device never browses it.
  - `project.pbxproj`: `INFOPLIST_FILE = Info.plist` (Debug/Release app configs); `HostDiscovery.swift` added to the test target's membership.
- **Files changed:** `VCamIOS/VCamIOS/{HostDiscovery.swift (new),ContentView.swift}`, `VCamIOS/Info.plist` (new), `VCamIOS/VCamIOS.xcodeproj/project.pbxproj`, `VCamIOS/VCamIOSTests/HostDiscoveryTests.swift` (new), `IMPLEMENTATION_PROGRESS.md` (FR-UX-001/002, NFR-SEC-003, iOS test row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test` (iPhone 17 Pro sim): `Executed 18 tests, with 1 test skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`. New: 4 TXT/list unit tests, and a live browse against an `NWListener` advertising `_vcam-ctl._tcp` (found, TXT update seen, gone after withdrawal, list empty after the browse task is cancelled; 6.3 s). The skip is the opt-in interop test.
  - **Interop with the real Rust advertiser:** `vcam_native` (wheel rebuilt with maturin for Blender's Python 3.13, run from Blender's `python3.13`) `Session.start(0, …)` + `advertise("Interop Mac 1.4.3a", "interop_shot.blend")`, then `TEST_RUNNER_VCAM_INTEROP_HOST=… TEST_RUNNER_VCAM_INTEROP_BLEND=… xcodebuild test -only-testing:…/testFindsTheRustHostAdvertiser`: `VCAM_INTEROP_FOUND id=vcam-e171…-62150 machine=Interop Mac 1.4.3a file=interop_shot.blend tcp=62150`, `** TEST SUCCEEDED **`. Repeated with `blend=""`: `file=Unsaved file`, passed. So mdns-sd's empty `blend=` reaches `NWTXTRecord.dictionary` as `""`.
  - **Built Info.plist** (`plutil -p`): `NSBonjourServices => ["_vcam-ctl._tcp"]`, `NSLocalNetworkUsageDescription => "VCamIOS finds Blender on your local network, …"`, camera string unchanged.
  - **Simulator smoke:** built, installed, launched (`kr8t0s.VCamIOS: 75546`); the screenshot shows "Blender on this network" listing "Studio Mac (Rust host) / shot_010.blend" from a live Rust host, plus the ones below.
  - **Mutation check** (sequential, snapshot restored and `cmp`-verified): empty `blend=` kept (`XCTAssertNil failed: ""`), no dedupe (list order/ids), version `>` instead of `>=` (boundary test), list not cleared after stop (`a stopped browser keeps no stale hosts`), TXT not requested (live test: machine fell back to the instance name). 5/5 caught.
  - `pytest BlenderAddOn/tests`: `19 passed`. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. `cargo test` (in `native/`, no Rust change): 60 passed, 0 failed. No add-on change, so the Blender scripts weren't re-run.
- **Finding (flag, not fixed):** the smoke list also showed the two interop hosts I had stopped with SIGKILL and six `owners-Mac.local / Unsaved file` hosts whose processes no longer exist (`dns-sd -B _vcam-ctl._tcp` listed 7 instances; only one advertiser was running). A host that dies without its goodbye stays in the Bonjour cache until the PTR/TXT TTL, which mdns-sd sets to 4500 s (`mdns-sd-0.21.4/src/service_info.rs:24`). Blender crashing or a headless test exiting without `Session.stop()` therefore leaves "ghost" Blenders on the iPhone for up to 75 min. Options for a later task: a shorter host TTL for our records, or have the device resolve/probe before listing. No requirement changed.
- **Not verified:** the local-network permission prompt and browsing on a real iPhone over Wi-Fi (device, owner).
- **Blocked:** 1.4.3b (with 1.4.2b), added to the table.
- **Next task:** 1.4.4 — origin reset, scale/locks UI sent as `CONTROL_STATE`; LiDAR/plane detection when available (FR-TRK-003/004, FR-CTL-004). Sending needs a session endpoint (1.4.2b), so the state/encoding and UI parts come first. No second task started.
- **Owner actions:** push (this commit makes 28 ahead). **Decide on `swift-srp`**: it blocks 1.4.2b/1.4.3b. Still pending: the `mdns-sd`/`getrandom` reviews, a device run.

## 2026-09-25 — Iteration 41 — 1.4.4 (FR-TRK-003, FR-CTL-004) — sub-step 1.4.4a done

- **Orientation:** no LOOP_STOP; clean tree; `main` 28 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Split of 1.4.4:**
  - **1.4.4a (this iteration):** the iOS controls (Set Origin, motion scale, axis locks) and sending them as `CONTROL_STATE` per vcp.md §6.2, including repeat-until-acknowledged via `STATUS.control_ack`.
  - **1.4.4b (next):** LiDAR scene reconstruction and plane detection when supported (FR-TRK-004). `ARWorldTrackingConfiguration.supportsSceneReconstruction(_:)` and `planeDetection` are confirmed in the iOS 27 SDK's `ARConfiguration.h:398`, `:286`. Can't run in the simulator.
- **API checked in the iOS 27 SDK:** `NWConnection.receiveMessage(completion:)` (`Network.swiftmodule/arm64e-apple-ios.swiftinterface:2141`). vcp.md §3 "Addresses": the host sends to the source address and port of the device's latest authenticated datagram, so the device's connected UDP `NWConnection` receives `STATUS`. The Rust host does this (`native/vcam-net/src/udp.rs:256`, `:567`).
- **Change:**
  - `TrackingPipeline.swift`: new `DeviceControls` (scale, lock bits, `origin_epoch` with `setOrigin()` wrapping at 65535 → 0, `parseScale` for the custom 1:N field, 0.001–1000, comma accepted). The pipeline keeps the current controls. Each run opens with the complete state as `state_seq` 1. Every real change (a no-op doesn't count) is the next `state_seq` and is sent at once. A `DispatchSourceTimer` on the pipeline queue repeats the latest state every 500 ms until an authentic `STATUS` with a newer `status_seq` (`VCPSeqFilter`) carries `control_ack` ≥ `state_seq`. Without a session endpoint nothing is sent. `TrackingSnapshot` carries `controlSeq`/`controlAck`. POSE and CONTROL_STATE share one `send` helper.
  - `UDPSender.swift`: the connection now reads datagrams (`receiveMessage` loop until error/cancel) and hands them to `onReceive`, which the pipeline sets in `start`.
  - `TrackingSessionController.swift`: `controls` (observable, `didSet` → `pipeline.setControls`), `controlSeq`/`controlAck` from snapshots.
  - `ContentView.swift`: a "Rig" section: Set Origin (enabled while tracking), a motion-scale picker (1:1, 1:2, 1:5, 1:10; a custom value shows as its own entry), a custom 1:N field with Apply (disabled while invalid), Lock height / Lock roll / Pan only toggles, and a "Blender" row: not paired / sent when tracking starts / waiting for Blender (#n) / applied (#n).
- **Note for 1.4.2b:** `seq` and `state_seq` restart at 1 per tracking **run**, like 1.4.2a's POSE seq. The host's filters are per **session**. When 1.4.2b binds a real session, a second run on the same session must not restart them (or must start a new session), or the host drops everything as stale.
- **Files changed:** `VCamIOS/VCamIOS/{TrackingPipeline.swift,UDPSender.swift,TrackingSessionController.swift,ContentView.swift}`, `VCamIOS/VCamIOSTests/TrackingPipelineTests.swift`, `IMPLEMENTATION_PROGRESS.md` (FR-TRK-003, FR-CTL-004, re-anchored FR-TRK-001 lines, iOS test row), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test` (iPhone 17 Pro sim, Swift 6): `Executed 21 tests, with 1 test skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`, no Swift warnings. New tests, all over a real loopback UDP socket playing the host (it now replies to the sender's address):
    - numbering plus golden bytes: the run opens with seq 1 (scale 1, no locks, epoch 0, all fields); 6 changes plus 1 no-op give exactly seqs 1–7, and seq 7 is byte-identical to `control_state_full` (the vector the Rust host is tested with);
    - repeats: a second seq 1 arrives after > 0.4 s. `STATUS` with ack 0, then a stale `status_seq` with ack 1, don't stop it; a fresh one with ack 1 does (≤ 1 in-flight repeat afterwards). Set Origin then sends seq 2 at once with epoch 1, and that repeats again;
    - `DeviceControls`: lock bits, epoch wrap, scale parsing bounds (0.001, 1000 accepted; 0.0009, 1000.5, 0, −2, inf, nan, empty, text rejected);
    - the unpaired test now also changes a control: still nothing sent.
    - The golden POSE test now skips the run's opening CONTROL_STATE.
  - **Mutation check** (sequential; the snapshot was restored after each and verified identical with `filecmp` byte comparison): ack ignored (`("3") is greater than ("1") - repeats stop once acknowledged`), STATUS freshness not checked (`XCTAssertNotNil failed` after the stale STATUS), no-op change counted (golden bytes differ: epoch 2 at seq 7), no opening state at start (`XCTUnwrap failed` ×2), repeat interval 100 ms (`0.104 is not greater than 0.4`). 5/5 caught.
  - **Incident:** the first mutation run hung: with the ack ignored, the drain loop in the repeat test never ended (repeats kept arriving), and the harness's 600 s timeout fired before its restore step. I restored the source from the snapshot (verified identical), bounded the loop at 3, and re-ran all five mutations with a `finally` restore. The results above come from that run. The final `xcodebuild test` ran after the restore.
  - **Simulator smoke:** built, installed and launched (`kr8t0s.VCamIOS: 78833`). The Rig section is below the fold, so a throwaway build with the section moved to the top (source restored and verified identical right after the build) was screenshotted: Set Origin greyed out (not tracking), "Motion scale 1:1", "Custom 1: 25" placeholder with Apply disabled, three toggles off, "Blender: Not sent (not paired)". The real build was reinstalled afterwards.
  - `pytest BlenderAddOn/tests`: `19 passed in 0.03s`. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. `cargo test` (in `native/`, no Rust change): 60 passed, 0 failed. No add-on or Rust change, so the Blender scripts, fmt and clippy weren't re-run.
- **Not verified:** a live device ↔ Blender control exchange (needs a session endpoint: 1.4.2b, blocked on `swift-srp`), toggles and Set Origin tapped in the running UI (no UI automation in the simulator; the logic is covered by the pipeline tests), a device run.
- **Blocked:** none new (sending for real is covered by the existing 1.4.2b row).
- **Next task:** 1.4.4b — LiDAR scene reconstruction and plane detection when supported (FR-TRK-004). No second task started.
- **Owner actions:** push (this commit makes 29 ahead). **Decide on `swift-srp`**: it blocks 1.4.2b/1.4.3b and therefore the iPhone actually sending poses and controls. Still pending: the `mdns-sd`/`getrandom` reviews, a device run.

## 2026-09-25 — Iteration 42 — 1.4.4b (FR-TRK-004) — done (device run owner-blocked)

- **Orientation:** no LOOP_STOP; clean tree; `main` 29 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **API checked in the iOS 27 SDK** (`ARKit.framework/Headers/ARConfiguration.h`): `+supportsSceneReconstruction:` (`:398`), `sceneReconstruction` (`:408`, default none; mesh output arrives as `ARMeshAnchor`s), `ARConfiguration.SceneReconstruction.mesh` (`:119-128`), `planeDetection` (`:286`, default none), and `ARWorldTrackingConfiguration.PlaneDetection` `.horizontal`/`.vertical` (`ARPlaneDetectionTypes.h:22-26`).
- **Change:**
  - `VCamIOS/VCamIOS/SceneUnderstanding.swift` (new): `SceneUnderstanding.best(meshSupported:)` always turns on horizontal + vertical plane detection and asks for `.mesh` only when it is supported. `forThisDevice()` asks ARKit. `makeConfiguration()` builds the gravity-aligned `ARWorldTrackingConfiguration` with both aids, and `summary` gives the UI label ("LiDAR mesh + planes" / "Planes").
  - `TrackingSessionController.startTracking` uses it instead of the bare configuration, and exposes `sceneUnderstanding` while tracking (nil after stop).
  - `ContentView`: a "Scene understanding" row in the Tracking section while tracking.
  - `project.pbxproj`: `SceneUnderstanding.swift` added to the test target's membership.
  - POSE is unchanged: anchors aren't read or sent; ARKit uses them internally.
- **Files changed:** `VCamIOS/VCamIOS/{SceneUnderstanding.swift (new),TrackingSessionController.swift,ContentView.swift}`, `VCamIOS/VCamIOSTests/SceneUnderstandingTests.swift` (new), `VCamIOS/VCamIOS.xcodeproj/project.pbxproj`, `IMPLEMENTATION_PROGRESS.md` (FR-TRK-004 now Partial, iOS test row, FR-TRK-003/FR-CTL-004 `ContentView` lines re-anchored), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test` (iPhone 17 Pro sim): `Executed 24 tests, with 1 test skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`, no Swift errors or warnings. New: mesh only when supported and planes always; `forThisDevice` follows ARKit's query (false in the simulator); the configuration carries the aids and stays `.gravity`.
  - **Mutation check** (sequential, one backup, restored and `cmp`-verified): mesh unconditional (`XCTAssertEqual failed` at `:13`, `:15`), mesh never (`:8`, `:10`), planes not set on the configuration (`:30`), alignment `.gravityAndHeading` (`ARWorldAlignment(rawValue: 1) is not equal to (rawValue: 0)`). 4/4 caught. Deleting the `worldAlignment` line survives, because `.gravity` is ARKit's default (equivalent mutant).
  - **Simulator smoke:** built (`** BUILD SUCCEEDED **`), installed, launched (`kr8t0s.VCamIOS: 80003`); `launchctl` lists it. The new row only shows while tracking, and ARKit doesn't run in the simulator, so it wasn't seen on screen.
  - `pytest BlenderAddOn/tests`: `19 passed in 0.04s`. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. `cargo test` (no Rust change): 60 passed, 0 failed. No add-on or Rust change, so the Blender scripts, fmt and clippy weren't re-run.
- **Not verified (BLOCKED, needs owner/device):** that a LiDAR iPhone starts the session with `.mesh` and tracks at least as steadily, and the thermal/CPU cost of the mesh over a long take (NFR thermal runs are device work). If the mesh costs too much, a later task can add a toggle.
- **Blocked:** none new.
- **Next task:** 1.4.5 — landscape status screen (no video yet): tracking state, rate, connection, thermal (FR-UX-003/004). No second task started.
- **Owner actions:** push (this commit makes 30 ahead). Try a LiDAR iPhone once and check the "Scene understanding" row says "LiDAR mesh + planes". **Decide on `swift-srp`**: it blocks 1.4.2b/1.4.3b. Still pending: the `mdns-sd`/`getrandom` reviews, a device run.

## 2026-09-25 — Iteration 43 — 1.4.5 (FR-UX-003/004) — done (FR-UX-004 stream reduction waits for Phase 2 video)

- **Orientation:** no LOOP_STOP; clean tree; `main` 30 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Change:**
  - `VCamIOS/VCamIOS/StatusHUD.swift` (new, pure logic, in the test target):
    - `PoseRateMeter`: poses per second from `seq` steps over ARKit capture time, recomputed after each ≥ 1 s window. Frames the ≤ 15 Hz UI throttle skipped still count. A seq restart (new run) or a capture-clock jump starts over.
    - `ThermalStatus`: label per `ProcessInfo.ThermalState`; `isWarning` from `.serious`.
    - `ChromeVisibility`: while tracking, the controls hide 4 s after the last use, and a tap on the frame toggles them. While idle they stay up, so Start is always reachable.
    - `HUDLayout`: a 44 pt status strip on the top edge and a 96 pt control rail on the trailing edge, each capped at 20 % of the frame. Neither enters `centre`, the middle half of the frame in each direction (it holds the rule-of-thirds points).
  - `ContentView.swift` is now the landscape status screen: a black frame area (future viewfinder), the status strip (tracking state dot + text, pose rate in Hz, connection, thermal with an orange warning, last error), and the rail (Start/Stop, Origin, Settings), placed at the `HUDLayout` rects.
  - The former portrait `Form` moved (`git mv`) to `SettingsView.swift` unchanged apart from the name, a Done button, and being shown as a sheet. Discovery now browses while the sheet is open.
  - `TrackingSessionController`: `poseRate` (reset per run and on stop) and `thermal`, kept current from `ProcessInfo.thermalStateDidChangeNotification` (main-queue observer, `MainActor.assumeIsolated`).
  - `project.pbxproj`: iPhone orientations are landscape left/right only (iPad keeps all four, which iPad multitasking needs); `StatusHUD.swift` added to the test target's membership.
- **FR-UX-004 scope:** the thermal state is shown and warns from `.serious`. The automatic stream resolution/fps reduction needs the video stream, which doesn't exist until Phase 2, so FR-UX-004 stays Partial. Not an owner block; it belongs with the stream tasks.
- **Files changed:** `VCamIOS/VCamIOS/{ContentView.swift (rewritten),SettingsView.swift (moved from ContentView.swift),StatusHUD.swift (new),TrackingSessionController.swift}`, `VCamIOS/VCamIOSTests/StatusHUDTests.swift` (new), `VCamIOS/VCamIOS.xcodeproj/project.pbxproj`, `IMPLEMENTATION_PROGRESS.md` (FR-UX-003/004 now Partial, iOS test row, FR-TRK-003/004, FR-CTL-004 and FR-UX-001 lines re-anchored to `SettingsView.swift`), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test` (iPhone 17 Pro sim, Swift 6): `Executed 30 tests, with 1 test skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`, no Swift errors or warnings. New (6): rate at 60 Hz with only every 4th pose seen, then 30 Hz; rate restart on a new run and on a clock jump; thermal labels and warning; auto-hide boundary (3.999 s shown, 4 s hidden), restart on use, pinned while idle; tap toggles; strip/rail never intersect the centre at 5 sizes (iPhone 17 Pro, iPhone SE, iPad landscape/portrait, 320×180) and sit on their edges.
  - **Mutation check** (sequential, one backup, restored and `filecmp`-verified identical): no reset on a new run (`XCTAssertNil failed: "1431655712.3333333"`), warning only at `.critical` (`FR-UX-004 acts from .serious on: Serious`), not pinned while idle (`Start stays reachable while not tracking`), tap hides while idle (`XCTAssertTrue failed`), hide boundary `<=` (`hidden after the delay`), rail width unclamped (`rail at (320.0, 180.0)`). 6/6 caught.
  - **Simulator smoke:** `** BUILD SUCCEEDED **`, installed, launched (`kr8t0s.VCamIOS: 81399`). The screenshot is landscape: top strip "Idle · – Hz · Not paired · Thermal: Normal", right rail Start / Origin (greyed) / Settings, empty centre. Built `Info.plist`: `UISupportedInterfaceOrientations~iphone` = LandscapeLeft, LandscapeRight. The settings sheet, auto-hide and tap toggle weren't exercised on screen (no UI automation in the simulator; the logic is covered by the tests).
  - `pytest BlenderAddOn/tests`: `19 passed in 0.04s`. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. `cargo test` (no Rust change): 60 passed, 0 failed. No add-on or Rust change, so the Blender scripts, fmt and clippy weren't re-run.
- **Not verified (BLOCKED, needs owner/device):** one-handed use and legibility on a real iPhone, thermal notifications under real heat, and O-2 (ARKit camera-local axes now that the UI is landscape-only).
- **Blocked:** none new.
- **Next task:** 1.5.1 — pose-leg latency: map iPhone capture time through the `CLOCK` offset to Blender time at apply, log histograms, write a report artefact (NFR-LAT-001/002). No second task started.
- **Owner actions:** push (this commit makes 31 ahead). Hold the app in landscape on an iPhone once: check the rail is thumb-reachable and hides while tracking. **Decide on `swift-srp`**: it blocks 1.4.2b/1.4.3b. Still pending: the `mdns-sd`/`getrandom` reviews, a device run.

## 2026-09-25 — Iteration 44 — 1.5.1a (NFR-LAT-001) — done (host side; device measurement owner-blocked)

- **Orientation:** no LOOP_STOP; clean tree; `main` 31 ahead of `origin`. The existing Phase 1 owner waiver applies.
- **Split of 1.5.1:**
  - **1.5.1a (this iteration):** host side of the pose leg: map each applied pose's capture time through the `CLOCK` offset to Blender's clock at apply, log histograms, write the report artefact.
  - **1.5.1b (next):** NFR-LAT-002, the iPhone send leg (`ARFrame` → datagram handed to the OS, p95 ≤ 2 ms, no allocation per pose), measured in `TrackingPipeline`.
  - **1.5.1c: BLOCKED (needs owner/device):** the real Wi-Fi/wired pose leg. Needs a paired iPhone (1.4.2b, `swift-srp`) and O-1 (which clock `ARFrame.timestamp` uses).
- **Change:**
  - `BlenderAddOn/core/latency.py` (new, pure Python): `LatencyLog` per device session (a new `session_id` starts over; a re-apply of the same `seq`, e.g. after Set origin or undo, isn't a sample; seq gaps count as `poses_not_applied`; at most 36,000 samples per leg). `report()` gives count/min/mean/p50/p95/p99/max (nearest rank), 0.5 ms histograms 0–100 ms with underflow/overflow, and `meets` for NFR-LAT-001 (pose leg p95 ≤ 20 ms; every apply ≤ 1 ms).
  - `core/session.py` `_poll`: times `Applier.tick` (apply cost), reads `host_clock_ns()` right after it, computes the pose leg with the existing `pose_latency_ms`, and records both while a device session is active. `latency_report()` adds date, platform, Blender version, device name, poll interval and the `CLOCK` estimate used. The log resets on `start()`.
  - `operators/session.py`: `vcam.latency_report_save` (`ExportHelper`, default `latency-<date>.json`); prints the summary line to the console.
  - `ui/panels.py`: "Save Latency Report (N poses)" button, shown while samples exist, including after the device left. No percentiles in `draw()`, so the 4 Hz redraw doesn't sort 36,000 samples.
  - `tests/blender/pose_leg_latency.py` (new): fake iPhone at 60 Hz over loopback, the session poll driven at its own 60 Hz, report saved after `SessionEnded`, then checks: device name, clock samples, every frame applied or counted, pose leg min > −1 ms and p50 < 50 ms (a wrong offset shows up as ±2,000,000 ms), histogram totals. Added to the CI `blender-smoke` loop (`.github/workflows/ci.yml:226`).
- **Results** (SRS §13.4, new dated note; report `reports/latency-2026-09-25-macos-arm64-loopback.json`): loopback pose leg p50/p95/p99 16.06/16.79/17.31 ms, apply p95 0.10 ms. With a 1 ms poll (throwaway probe) the pose leg is 0.81 ms p50, which confirms the clock mapping.
- **Flagged (SRS §13.4, no requirement changed):**
  - The 60 Hz `POLL_INTERVAL` adds 0–16.7 ms of slot wait depending on phase (p50 ranged 1.2–16.5 ms across runs). That leaves ≤ 3 ms for Wi-Fi in the worst phase and makes the wired ≤ 8 ms target unreachable. At equal rates some polls apply only the newer of two poses (up to 37 % in the GUI run). Options: faster poll, or a wake-up on pose arrival.
  - Single applies of 1.17–1.65 ms in 3 of 13 runs (p95 ≈ 0.1 ms), so `meets.apply_max` can be false.
  - **Flaky test, not caused by this change (no Rust changed):** one `cargo test` run failed `vcam-fake-iphone` `scripted_controls_reach_the_host_in_order` (`fake_iphone.rs:254`: state 1 was never observed, only state 2). At `--rate 2000` Set origin comes 5 ms after the first state, and the latest-sample slot can overwrite state 1 before the test polls. Two re-runs passed. Fix in a later task: have the test wait for state 1 before Set origin, or use a later `--set-origin-at`.
- **Files changed:** `BlenderAddOn/core/{latency.py (new),session.py}`, `BlenderAddOn/operators/{session.py,__init__.py}`, `BlenderAddOn/ui/panels.py`, `BlenderAddOn/tests/test_latency.py` (new), `tests/blender/pose_leg_latency.py` (new), `.github/workflows/ci.yml`, `reports/latency-2026-09-25-macos-arm64-loopback.json` (new), `docs/SRS.md` (§13.4 only), `IMPLEMENTATION_PROGRESS.md` (NFR-LAT-001 now Partial, NFR-LAT-002 row, FR-BL-004 line and visual check, FR-BL-007 re-anchored, NFR-QA-001), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`: `24 passed` (5 new).
  - Wheel rebuilt with maturin for Blender's Python 3.13 (`Built wheel for CPython 3.13`), extension built and installed into a temporary `BLENDER_USER_RESOURCES`, then headless Blender 5.2.2 with `--python-exit-code 1`, all exit 0: `VCAM_POSE_LEG_OK … poses=346 not_applied=44 pose_leg_p50=16.06 p95=16.79 … meets={'pose_leg_p95': True, 'apply_max': True}`, `VCAM_NATIVE_OK 0.1.0`, `VCAM_ADDON_APPLY_OK keyposes=5 max_err=1.79e-07 …`, `VCAM_ADDON_PANEL_OK latency_ms=2.87 …`, `VCAM_ADDON_ROBUST_OK final_seq=390 …`, `VCAM_ADDON_SESSION_OK …`, `VCAM_SESSION_OK …`.
  - An earlier run of the new script failed on my own assertion (`>= 300` applied: only 289, because the 60 Hz poll skips superseded poses). I replaced it with the `poses_not_applied` accounting above.
  - **GUI check** (Blender window, real `bpy.app.timers` poll, throwaway timer script, fake iPhone at 60 Hz; the panel was moved to the open Tool tab for the screenshot because `Region.active_panel_category` is read-only): `GUI_LATENCY_OK {'FINISHED'} … pose_leg_ms n=246 p50=1.18 p95=2.00 …`. Screenshots inspected: streaming shows "Fake iPhone, Tracking: Normal, Poses: 60 Hz, loss 0.0 %, Latency: 1.1 ms, Save Latency Report (156 poses)"; after the device left, "Waiting for the iPhone" with "Save Latency Report (246 poses)". The splash covers the panel's left edge.
  - **Mutation check** (sequential, one snapshot, restored and `filecmp`-verified identical): re-apply counted (`assert not True`), percentile off by one (`51.0 == 50.0`), negatives binned (histogram test), apply verdict on p95 (`meets` mismatch), gap count off by one (`4 == 2`), offset sign flipped in `_poll` (Blender script: pose leg min −1,999,756 ms). 6/6 caught. Not covered by a test: the "no sample after the device left" guard (needs an undo after disconnect).
  - `.venv.nosync/bin/actionlint .github/workflows/ci.yml`: no findings. `gen_testdata.py --check`: `testdata/ up to date (21 files)`. `cargo test` (no Rust change): 60 passed, 0 failed on two runs, after the flaky failure above. fmt/clippy not re-run (no Rust change).
- **Blocked:** 1.5.1c (device pose leg), covered by the existing 1.4.2b row plus O-1.
- **Next task:** 1.5.1b — NFR-LAT-002 iPhone send leg (`ARFrame` → datagram handed to the OS) in `TrackingPipeline`. No second task started.
- **Owner actions:** push (this commit makes 32 ahead). Decide whether the 60 Hz poll's 0–16.7 ms slot wait (SRS §13.4) needs a faster poll before T1's latency gate. **Decide on `swift-srp`**: it blocks 1.4.2b/1.4.3b and the device pose-leg run. Still pending: the `mdns-sd`/`getrandom` reviews, a device run.

## 2026-09-25 — Iteration 45 — 1.5.1b (NFR-LAT-002) — done (simulator; device run owner-blocked)

- **Orientation:** no LOOP_STOP; `main` 32 ahead of `origin`. The tree was **not** clean: uncommitted 1.5.1b work (8 files plus the new `AllocationCounter.swift`, all timestamped 10:41–10:56 today, after the 1.5.1a commit, and self-described as task 1.5.1b in SRS §13.5) from an interrupted earlier iteration. It is the next planned task, so this iteration reviewed, verified and finished it rather than halting. The local `iPhone 17 Pro` simulator no longer exists (the iOS 27.0 runtime has iPhone 17 / 17 Pro Max / 18 Pro); tests ran on `iPhone 17`. CI still names `iPhone 17 Pro` (present on the runner image).
- **Change (NFR-LAT-002: `ARFrame` → datagram handed to the OS, p95 ≤ 2 ms, no allocation per pose):**
  - `TrackingPipeline.swift`: `SendLegMeter` (`:116`, 500 × 10 µs bins + overflow, nearest-rank percentiles reporting the bin's upper edge, never understating) timed from `receive` (`:253`) to a successful `send`; summary published in `TrackingSnapshot.sendLeg`. `receive` enters the actor through a context-free `handleFrame` bit-cast instead of `assumeIsolated` (2 closure blocks per pose). Datagrams are sealed into one reused buffer. A `run` counter drops host-name resolutions that finish after their run ended.
  - `UDPSender.swift`: `NWConnection` replaced by a connected, non-blocking BSD UDP socket (`send(2)`, 0 blocks vs. 5–9); replies read through a `DispatchSourceRead` on the pipeline queue. `getaddrinfo` numeric-only on the ARKit queue, names resolved off it, IPv4 preferred because Blender binds `0.0.0.0`.
  - `VCP/VCPEndpoint.swift`: `seal(_:into:)` and CommonCrypto `CCHmac` one-shot (CryptoKit `HMAC` allocates 4–8 blocks per call). Golden-vector tests unchanged and passing.
  - `SettingsView.swift` / `TrackingSessionController.swift`: "Send leg p95" row (orange above 2 ms).
  - Tests: `VCamIOSTests/AllocationCounter.swift` (new; counts the calling thread's heap allocations via libmalloc's `malloc_logger` hook), `TrackingPipelineTests` +5 (`testPoseSendPathAllocatesNothing` Release-only, send-leg measured / not measured without a session, host-name resolution, meter percentiles). CI step runs the allocation test with `-configuration Release` (`.github/workflows/ci.yml:253`).
  - SRS §13.5 (dated note): before/after block counts, simulator numbers, and a flag that the pose/control UDP socket is now BSD rather than the §1.4 Network framework. No requirement text changed.
- **Files changed:** `VCamIOS/VCamIOS/{TrackingPipeline,UDPSender,SettingsView,TrackingSessionController}.swift`, `VCamIOS/VCamIOS/VCP/VCPEndpoint.swift`, `VCamIOS/VCamIOSTests/{TrackingPipelineTests.swift,AllocationCounter.swift (new)}`, `.github/workflows/ci.yml`, `docs/SRS.md` (§13.5 only), `IMPLEMENTATION_PROGRESS.md` (NFR-LAT-002 now Partial), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'` (Debug): `Executed 35 tests, with 2 tests skipped and 0 failures`, `** TEST SUCCEEDED **`. `VCAM_SEND_LEG n=609 p50=20000 p95=20000 p99=30000 max=305417 ns` (p95 0.02 ms). Skipped: the live-host discovery test (needs a host) and the Release-only allocation test.
  - Same, `-configuration Release -only-testing:…/testPoseSendPathAllocatesNothing`: `VCAM_SEND_ALLOCATIONS poses=600 allocations=0`, `** TEST SUCCEEDED **`.
  - **Mutation check** (sequential, one snapshot, restored and `cmp`-verified identical): M1 `receive` via `assumeIsolated` → Release test fails with `allocations=1200` (2 per pose, matching §13.5); M2 sample recorded on failed sends (`if !send`) → 2 failures (`testSendLegIsMeasuredForSentPoses`, `testSendLegIsNotMeasuredWithoutASession`). 2/2 caught.
  - `.venv.nosync/bin/actionlint .github/workflows/ci.yml`: clean. No Rust, Python or `testdata/` change, so cargo/pytest/Blender/`gen_testdata --check` were not re-run.
- **Owner-directed deviation:** the owner asked in this session to open a PR with the accumulated progress and merge it. §2 forbids the loop from pushing or creating PRs on its own; this was done on the owner's explicit instruction, not as a loop decision.
- **Blocked:** device measurement of the send leg on a real iPhone (NFR-LAT-002 on hardware) — covered by the existing 1.4.2b / 1.5.1c rows.
- **Next task:** read the CI run for the merged push (`gh run list`, `gh run view --log-failed`) and fix failures locally — the first CI run since `35958600428`. Then fix the flaky `vcam-fake-iphone` `scripted_controls_reach_the_host_in_order` test noted in iteration 44. No second task started.
- **Owner actions:** run the app on an iPhone once and read "Send leg p95" in Settings (needs 1.4.2b to send). **Decide on `swift-srp`**. Still pending: the `mdns-sd`/`getrandom` reviews; whether the 60 Hz poll needs speeding up (SRS §13.4).

## 2026-09-25 — Iteration 46 — ci-fix-2026-09-25 (NFR-QA-001/002) — done locally; PR #2 CI pending

- **Orientation:** no LOOP_STOP; clean tree; `main` = `origin/main` (`0520133`); no open PR. First iteration under the GitHub PR flow (§1b/§3). Branch `loop/ci-fix-2026-09-25`, draft PR https://github.com/0xkr4t0s/VCamBlender/pull/2.
- **CI run `36093150776`** (push of `f2825b4` to `main`): 10 of 14 jobs green: rust-fmt, python, fuzz, wheels ×3, extension, blender-smoke ×3 (all seven Blender scripts on every OS). Failed, each for a different reason:
  - `rust (ubuntu-latest)`: `turbojpeg-sys v1.2.0` build script: `No CMAKE_ASM_NASM_COMPILER could be found` (libjpeg-turbo's x86-64 SIMD; `vcam-video` dev-dependency).
  - `rust (macos-latest)`: `using chunks_exact with a constant chunk size` at `vcam-fake-iphone/src/main.rs:149` (`clippy::chunks_exact_to_as_chunks`, Rust 1.98; local 1.97.1 doesn't have it).
  - `rust (windows-latest)`: `variable does not need to be mutable` at `vcam-net/src/store.rs:39` (`DirBuilder::mode` is Unix-only).
  - `ios` (Xcode 26.6, iOS 26.5 simulator): the test process died in `TrackingPipelineTests` right after `testPoseSendPathAllocatesNothing` was skipped, while `testSendLegIsMeasuredForSentPoses` ran (`Restarting after unexpected exit, crash, or test timeout`); on restart every test passed, but xcodebuild reported `testPoseSendPathAllocatesNothing` as failing. No crash log: the result bundle wasn't uploaded.
- **Changes:**
  - `.github/workflows/ci.yml:49-57`: install NASM before clippy (apt on Linux; `choco install nasm` plus `GITHUB_PATH` on Windows). No `ci-ok` change.
  - `native/vcam-fake-iphone/src/main.rs:148`: `as_chunks::<28>().0.iter()` (stable since 1.88).
  - `native/vcam-net/src/store.rs:39`: `#[cfg_attr(not(unix), allow(unused_mut))]` on the builder.
  - `VCamIOS/VCamIOSTests/AllocationCounter.swift`: the `malloc_logger` hook runs inside malloc on every thread. In Debug it called `swift_beginAccess`/`swift_endAccess` on every allocation of every thread, because the counted thread was a `var` global (confirmed with `objdump` of the Debug test bundle). It now keeps the thread in an `Atomic<UInt>` (`let`, no access checks); the hook calls only `pthread_self` and the atomics' addressors (`objdump`: 0 `swift_*Access` calls). **[INFERENCE]** This is the likely iOS 26.5 crash: the runtime may allocate a thread's exclusivity state on first use, which re-enters the hook. I couldn't reproduce it on iOS 27 (see below), and only iOS 27 is installed locally, so PR #2's CI is the check.
  - `.github/workflows/ci.yml:266-280`: both `xcodebuild test` steps write `-resultBundlePath xcresult/…`, uploaded as `ios-xcresult` on failure, so a recurrence has its crash log.
  - `native/vcam-fake-iphone/tests/fake_iphone.rs:225-239`: the flaky `scripted_controls_reach_the_host_in_order` (iteration 44) now runs at `--rate 600` with Set origin at frame 200 (~330 ms of state 1 against a 5 ms sample loop), not 2000 Hz at frame 10 (5 ms, one sample).
- **Files changed:** `.github/workflows/ci.yml`, `native/vcam-fake-iphone/src/main.rs`, `native/vcam-fake-iphone/tests/fake_iphone.rs`, `native/vcam-net/src/store.rs`, `VCamIOS/VCamIOSTests/AllocationCounter.swift`, `IMPLEMENTATION_PROGRESS.md` (Repo/CI row, maturity line, NFR-QA-001/002), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo fmt --check`: clean. `cargo clippy --all-targets -- -D warnings`: `Finished`, no warnings (local 1.97.1; the 1.98 lint and the Windows `cfg` can only be confirmed by CI). `cargo test`: 60 passed, 0 failed.
  - Flaky test, 8 copies of the test binary at once × 4 rounds, sequential snapshot/restore (`cmp`-verified): old test `pass=28 fail=4`, each failure `left: [(2, Some(2.0), Some(5), Some(1))]` (state 1 never sampled, as in iteration 44); new test `pass=32 fail=0`. Also 15 plain sequential runs of the new test: 15/15.
  - iOS repro attempt, before the fix: `xcodebuild test -only-testing:VCamIOSTests/TrackingPipelineTests -test-iterations 40 -run-tests-until-failure` (iPhone 17, iOS 27.0): `Executed 521 tests, with 1 test skipped and 0 failures`, `** TEST SUCCEEDED **`. A throwaway test that starts fresh pthreads that allocate under the old hook also passed (`allocations=7`). A throwaway probe confirmed that the hook does fire for a fresh thread's malloc (`size4097_allocs=2`). Not reproducible on iOS 27. Throwaway code removed (`cmp`-verified).
  - After the fix: `xcodebuild test` (iPhone 17, Debug): `Executed 35 tests, with 2 tests skipped and 0 failures`, `** TEST SUCCEEDED **`. `-configuration Release -only-testing:…/testPoseSendPathAllocatesNothing`: `VCAM_SEND_ALLOCATIONS poses=600 allocations=0`, `** TEST SUCCEEDED **` (its self-check, one array = 1 allocation, passed, so the hook still counts).
  - `.venv.nosync/bin/actionlint .github/workflows/ci.yml`: no findings.
  - No Python, add-on or `testdata/` change, so pytest, `gen_testdata --check` and the Blender scripts weren't re-run (all green in run `36093150776`).
- **Blocked:** none new.
- **Next task:** the next iteration checks PR #2's CI (§1b). If it's green and merged, continue in Phase 1 order: 1.5.1c stays owner-blocked, so take the next unblocked plan task. No second task started.
- **Owner actions:** none needed for PR #2 (auto-merge). Still pending: **decide on `swift-srp`**, the `mdns-sd`/`getrandom` reviews, and whether the 60 Hz poll needs speeding up (SRS §13.4).

## 2026-09-25 — Iteration 47 — ci-fix-2026-09-25 (NFR-QA-001/002) — PR #2 CI failure fixed on the same branch

- **Orientation:** no LOOP_STOP; clean tree on `loop/ci-fix-2026-09-25`; PR #2 ready with auto-merge armed. `gh pr checks 2 --watch` finished in about 5 min: `mergeStateStatus: BLOCKED`. (The `ci-ok` fail from run `36094843762` is the draft-time run where every job was skipped, as designed at `ci.yml:282-299`.)
- **PR #2 run `36094854974`:** 16 of 17 jobs green: rust-fmt, rust (ubuntu, macos), fuzz, wheels ×3, extension, blender-smoke ×3, python, **ios** (the iOS 26.5 crash from `36093150776` didn't recur), which confirms iteration 46's fixes for NASM, `as_chunks` and the `malloc_logger` hook. Failed: `rust (windows-latest)`, which passed clippy this time and reached `cargo test`:
  - `fake_iphone.rs:27:39: called Result::unwrap() on an Err value: Os { code: 267, kind: NotADirectory, message: "The directory name is invalid." }` in all 3 tests of `vcam-fake-iphone --test fake_iphone`.
  - Cause: `Scratch::new` put `{:?}` of an `Instant` in the directory name. On Windows that renders as `Instant { t: … }`, and `:` isn't valid in a Windows path component. This was latent: every earlier Windows run stopped at clippy before reaching the tests.
- **Change:** `native/vcam-fake-iphone/tests/fake_iphone.rs:18-29`: the scratch directory is now named `vcam-fake-iphone-<tag>-<pid>-<n>`, where `n` is a per-process `AtomicU32` counter. That keeps names unique across parallel tests and processes, using only portable characters. No other `temp_dir()` name in `native/` uses `Debug` output (`vcam-net/tests/control_server.rs:570` uses hex).
- **Files changed:** `native/vcam-fake-iphone/tests/fake_iphone.rs`, `IMPLEMENTATION_PROGRESS.md` (Repo/CI row, maturity line, NFR-QA-002), `docs/LOOP_LOG.md`.
- **Commands run:**
  - `cargo fmt --check`: clean. `cargo clippy --all-targets -- -D warnings`: `Finished`, no warnings. `cargo test`: 60 passed, 0 failed (the three `fake_iphone` tests: `3 passed`).
  - Windows can't be run locally, so PR #2's next CI run is the check for the fix. No Python, add-on, iOS or `testdata/` change, so those suites weren't re-run (all green in `36094854974`).
- **Blocked:** none new.
- **Next task:** the next iteration checks PR #2's CI (§1b). Once it merges, P0's CI gate (0.1.5) is met; continue with the next unblocked Phase 1 task. No second task started.
- **Owner actions:** none needed for PR #2 (auto-merge). Still pending: **decide on `swift-srp`**, the `mdns-sd`/`getrandom` reviews, and whether the 60 Hz poll needs speeding up (SRS §13.4).

## 2026-09-25 — Iteration 48 — ci-fix-2026-09-25 (NFR-QA-001/002, PR-006) — second PR #2 CI failure fixed on the same branch

- **Orientation:** no LOOP_STOP; clean tree on `loop/ci-fix-2026-09-25`; PR #2 ready, auto-merge armed. `gh pr checks 2 --watch` finished in about 9 min: `mergeStateStatus: BLOCKED`.
- **PR #2 run `36095300417`:** 13 of 14 jobs green: rust-fmt, rust (ubuntu, macos), fuzz, wheels ×3, extension, blender-smoke ×3, python, ios. The iteration 47 fix worked: `vcam-fake-iphone --test fake_iphone` passed on Windows (`3 passed`). Failed: `rust (windows-latest)`, one test further on:
  - `malformed_and_wrong_version_hello_are_refused` at `vcam-net/tests/control_server.rs:67:36`: `Os { code: 10054, kind: ConnectionReset, message: "An existing connection was forcibly closed by the remote host." }` (`control_server`: 15 passed, 1 failed). The client had already read the `ERROR` frame; the read that expects the server's EOF got a reset.
  - Cause: in the header-version-2 case the server rejects the frame from its 12-byte header (`ControlMessage::frame_len`) and never reads the payload. `Conn::serve` then wrote `ERROR` and closed with that input unread, and Windows answers that with RST instead of FIN. That's a product bug, not just a test flake: a Windows RST can also discard an `ERROR` the device hasn't read yet, so the iPhone could see "connection reset" instead of the reason. Latent until now, like iteration 47's: every earlier Windows run stopped before `vcam-net`'s tests.
- **Stop-rule note:** §6 says to stop when CI fails on the same PR in two consecutive iterations. Iterations 47 and 48 both found PR #2 red, but on different, newly reached Windows failures (each fix got further into `cargo test`), and the owner said "continue" in this session. So I fixed it instead of halting. If PR #2's next run fails again, the next iteration should create `docs/LOOP_STOP`.
- **Change:** `native/vcam-net/src/control.rs:420-457`: after writing `ERROR`, `linger_close()` shuts down the write side (FIN), then reads and discards input until the peer closes, an error, the server stops, or `ERROR_LINGER` (1 s, `:27`) passes; then the socket is closed as before. The normal close path is unchanged. The peer sees `ERROR` followed by EOF on every OS.
- **Files changed:** `native/vcam-net/src/control.rs`, `IMPLEMENTATION_PROGRESS.md` (Repo/CI row, maturity line, NFR-QA-002), `docs/LOOP_LOG.md`.
- **Commands run:**
  - Local repro attempts (macOS, before the fix): the failing test run 531 times in a loop, `fails 0`; with a throwaway 300 ms sleep before the client reads the `ERROR` (restored, `cmp`-verified): `1 passed`. macOS closes after `shutdown(Both)` without a reset, so it can't reproduce here; Windows CI is the check.
  - `cargo fmt --check`: clean. `cargo clippy --all-targets -- -D warnings`: clean (after collapsing one nested `if`). `cargo test`: 60 passed, 0 failed (`control_server`: `17 passed`).
  - No Python, add-on, iOS or `testdata/` change, so those suites weren't re-run (all green in `36095300417`).
- **Blocked:** none new.
- **Next task:** the next iteration checks PR #2's CI (§1b). Merged: 0.1.5 is met, and every remaining Phase 1 task is owner-blocked (1.1.4b/1.4.2b/1.4.3b on `swift-srp`, 1.5.1c on a device), so expect a §6 stop. Failed again: create `docs/LOOP_STOP` (§6). No second task started.
- **Owner actions:** none for PR #2 (auto-merge). Still pending: **decide on `swift-srp`**, the `mdns-sd`/`getrandom` reviews, and whether the 60 Hz poll needs speeding up (SRS §13.4).

## 2026-09-25 — Iteration 49 — 0.1.5 close-out (XP-002, NFR-QA-002) — PR #2 green and merged; loop stops (§6)

- **Orientation:** no LOOP_STOP; clean tree on `loop/ci-fix-2026-09-25`. Open PRs: #2 (loop, ready) and #3 (`docs/readme`, draft, not opened by the loop, left alone).
- **PR #2 run `36096344645`** (head `01299b8`): `gh pr checks 2 --watch` finished in about 11 min with every check `pass`: rust-fmt, rust (ubuntu, macos, windows 5m44s), fuzz, wheels ×3, python, ios, extension, blender-smoke ×3, ci-ok; `gh run view`: `conclusion: success`, 15 of 15 jobs. Iteration 48's lingering close fixed the Windows `ConnectionReset`. The logs show all seven Blender scripts' `VCAM_*_OK` lines in each of the 3 `blender-smoke` jobs. Auto-merge fired: PR #2 `MERGED` as `bdc338e`; `main` fast-forwarded, local branch deleted.
- **Record:** 0.1.5 is done and the P0 CI gate is met. `IMPLEMENTATION_PROGRESS.md`: Repo/CI row and XP-002, NFR-QA-002 now Done; maturity line and NFR-QA-001 evidence moved to run `36096344645` (NFR-QA-001 stays Partial: no single `blender --background … tests` runner). Blocked-items row for 0.1.5 resolved.
- **Files changed:** `IMPLEMENTATION_PROGRESS.md`, `docs/LOOP_LOG.md`. No code change, so no local suite was re-run; the CI run above is the evidence.
- **Stop (§6):** 
  - P0 exit gate met apart from owner items (S-1 Windows/Linux, S-2d/e, S-3b/c).
  - Every remaining Phase 1 plan task is owner-blocked: 1.1.4b/1.4.2b/1.4.3b on the `swift-srp` decision, 1.5.1c on a real iPhone (plus O-1). The T1 gate items the loop can reach are met: the fake-iPhone headless test passes on 3 OSes and the CI fuzz job ran clean (60 s per target, coverage-guided on nightly); the device checklist and device pose-leg p95 need the owner.
  - `docs/LOOP_STOP` created (not committed) and posted as a GitHub issue.
- **Unplanned Phase 1 gap the owner may want to schedule:** FR-TRK-002's Blender side, "hold the last good pose while tracking is limited", isn't in any plan row (noted in the 1.3.3 entry). It's unblocked host work.
- **Next task:** none until the owner resumes. Once `swift-srp` is decided: 1.1.4b (Swift SRP pairing), then 1.4.2b/1.4.3b. Otherwise, authorise Phase 2 early (2.x viewfinder stream).
- **Owner actions:** **decide on `swift-srp`** (Apache-2.0; blocks 1.1.4b/1.4.2b/1.4.3b); run the device checklist once pairing exists; the `mdns-sd`/`getrandom` reviews; whether the 60 Hz poll needs speeding up (SRS §13.4); optionally authorise Phase 2 or the FR-TRK-002 hold option; then delete `docs/LOOP_STOP`.

## 2026-09-25 — Owner session — windows-udp-loss (NET-002, NFR-QA-002) — Windows UDP receiver lost datagrams

- **Trigger:** PR #4's first CI attempt (run `36096910927`) failed `rust (windows-latest)`: `authenticated_control_refreshes_idle_timeout_but_forged_udp_does_not` panicked at `vcam-net/tests/control_server.rs:144:9`, "timed out waiting for control refresh". A rerun passed. The owner wants Windows green before the Sightline rename (PR #3).
- **Repro (owner's Windows PC over SSH):** 8 concurrent `control_server` runs × 6 failed most runs, in every UDP test ("first pose", "UDP pose", "old pose", "pending UDP rejected", …). Instrumented trace: the test's `send_to` returned `Ok(62)`, the receiver kept waking from its 50 ms timeout, and the datagram never arrived. A single test alone never failed.
- **Cause:** `UdpReceiver` waited with `SO_RCVTIMEO` (`set_read_timeout(POLL)`). On Windows a blocking `recv` that times out while a datagram arrives can drop that datagram. Standalone probe (`recv` thread with a 50 ms timeout, 16 senders, 24 CPU-spinning threads): 15 and 21 of 960 lost; without load 0 of 960; non-blocking polling 0 of 960; `mio` readiness 0 of 1,920. It's a product bug, not only a flake: a busy Windows Blender could lose poses, CONTROL_STATE and CLOCK replies.
- **Change:** `native/vcam-net/src/udp.rs`: the socket is a `mio::net::UdpSocket` registered with a `mio::Poll`; the thread polls with the same 50 ms timeout, then drains `recv_from` until `WouldBlock` after every wake. Oversize and transient-error handling are unchanged in effect. `native/vcam-net/Cargo.toml`: `mio = "=1.2.3"` with `os-poll`, `net` (already in the lockfile through `mdns-sd`, same features, so no new crate). The fake iPhone's `service()` still uses `set_read_timeout` on its UDP socket; its tests pass on Windows and the host resends STATUS/CLOCK, so it's left alone.
- **Commands run:**
  - macOS: `cargo fmt --check` clean; `cargo clippy -p vcam-net --all-targets -- -D warnings` clean; `cargo test -p vcam-net`: all pass (`control_server` 17 passed).
  - Windows (owner PC, Rust 1.97 MSVC): `cargo clippy -p vcam-net --all-targets -- -D warnings` clean; the 8 × 6 concurrent `control_server` stress went from most runs failing to `fails=0/6` on all 8 workers; `cargo test -p vcam-net -p vcam-protocol -p vcam-fake-iphone`: all pass. (`vcam-video` doesn't build there: no NASM for turbojpeg-sys.)
- **Next:** CI on the PR is the 3-OS check. Then PR #3 (Sightline rename) can be rebased on `main`.

## 2026-09-25 — Owner session — decisions to resume the loop

- **Owner decisions:**
  - **`swift-srp` approved:** `adam-fowler/swift-srp` pinned exactly at `2.4.0` (Apache-2.0, matching the iOS app's Apache-2.0 licence from PR #6). Transitive: `apple/swift-crypto` (Apache-2.0), `adam-fowler/big-num` `2.0.3` (MIT). Unblocks 1.1.4b, then 1.4.2b/1.4.3b.
  - **Hold last good pose scheduled** as plan task 1.3.6 (FR-TRK-002, Blender side).
  - **Phase 2 may start early**, before the T1 gate closes (plan, Phase 2 note).
  - **Future idea recorded:** post-take gap and jump repair, FR-TAKE-006 (T4), plan Phase 4.
- **Other changes since the loop stopped:** the iOS app moved to `SightlineIOS/` (scheme `SightlineIOS`, bundle ID `kr8t0s.Sightline`) and is licensed Apache-2.0 (PR #6). The Blender extension has `BlenderAddOn/LICENSE` (GPL-3.0). The GitHub repo is now `0xkr4t0s/Sightline`.
- **Still open for the owner:** `mdns-sd`/`getrandom` reviews; whether the 60 Hz poll needs speeding up (SRS §13.4); licence of the Rust crates and protocol (S-5); device and Windows/Linux items in the blocked table.
- **Next task:** 1.1.4b (plan, "Immediate next steps" 1).

## 2026-09-25 — Iteration 50 — 1.1.4b (PR-001..003, PR-006, NFR-SEC-001; O-3) — done

- **Orientation:** no LOOP_STOP; clean tree; `main` = `origin/main` (`9418d08`); no open PR. Task from "Immediate next steps" 1. Branch `loop/1.1.4b`, PR https://github.com/0xkr4t0s/Sightline/pull/9.
- **Dependencies (owner-approved, pinned exactly in `project.pbxproj` and `Package.resolved`):** `adam-fowler/swift-srp` 2.4.0 (`1345dfe`) and `adam-fowler/big-num` 2.0.3 (`9059dca`, MIT; added as a direct product because the app computes `A = g^a` itself), products `SRP` and `BigNum` on the app and test targets. SPM resolved the transitive `apple/swift-crypto` 4.5.2 and `apple/swift-asn1` 1.7.3 (both Apache-2.0; swift-asn1 wasn't in the owner's list, it comes with swift-crypto 4.x).
- **API checked before use:** read `swift-srp` 2.4.0's `client.swift`/`keys.swift`/`srp.swift`: `u = H(A.bytes ‖ B.bytes)` over keys padded to `sizeN`, `x = H(s ‖ H("I:P"))`, `S` returned padded, `nullServerKey` for `B mod N = 0` and `u = 0`; its M1/M2 are RFC 2945-style, so only `S` is used and K/M1/M2/PK follow vcp.md. big-num's `power(_:modulus:)` is BoringSSL `BN_mod_exp`, which reduces a negative base first (`exponentiation.c:573`), so `B − k·g^x` is correct.
- **Change:**
  - `SightlineIOS/SightlineIOS/VCP/VCPControl.swift` (new): `VCPControlMessage` (HELLO, PAIR_CHALLENGE/PROOF/ACCEPT, SESSION_CHALLENGE/PROOF/ACCEPT, ERROR): `payload()`, `encode()`, `frameLength(header:)` for stream readers (magic, `session_id` 0, `len` ≤ 4096, then version) and `decode` (exact length, longer payloads accepted, strings bounded and UTF-8-checked). Mirrors `native/vcam-protocol/src/control.rs`.
  - `SightlineIOS/SightlineIOS/VCP/VCPPairing.swift` (new): generic `VCPSRPClient<H>` (`PAD(A)`, `PAD(S)`); `VCPPairing.devicePair` (6-digit check, `T_pair`, `K = H(PAD(S))`, M1) → `VCPPendingPair.finish(m2:)` (constant-time M2 check via CryptoKit `HMAC.isValidAuthenticationCode`, HKDF PK); `VCPSessionHandshake` (`proof_d`, constant-time `proof_h` check, then HKDF `k_d2h ‖ k_h2d` with `session_id` LE) → `VCPSessionKeys.deviceEndpoint`; `randomSecret()` from `SecRandomCopyBytes`.
  - `project.pbxproj`: package references and products; the two new files added to the test target's membership list.
  - `SightlineIOSTests/VCPGoldenTests.swift`: +6 tests (`:184` all 10 TCP frames in `messages.json`/`pairing.json`/`session.json` byte-exact; `:216` malformed frames; `:253` RFC 5054 App. B through `VCPSRPClient<Insecure.SHA1>`; `:264` full `pairing.json` transcript incl. `S`, M1, PAIR_PROOF bytes, PK, every M2 bit flip, `wrong_code` M1; `:295` `B = 0`, `B = N`, bad codes; `:317` `session.json` proof_d, keys, first POSE sealed byte-exact, every proof_h flip, other PK).
  - `docs/protocol/vcp.md`: O-3 closed (§13) and a change-log row; no wire change. `IMPLEMENTATION_PROGRESS.md`: PR-001..003/PR-006, NFR-SEC-001, maturity line, iOS test-run row.
- **Commands run:**
  - `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'` (Debug, full suite): `Executed 41 tests, with 2 tests skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **` (skips: the opt-in live-host discovery test and the Release-only allocation test).
  - Same, `-configuration Release -only-testing:…/testPoseSendPathAllocatesNothing`: `VCAM_SEND_ALLOCATIONS poses=600 allocations=0`, `** TEST SUCCEEDED **`.
  - `-only-testing:SightlineIOSTests/VCPGoldenTests`: `Executed 12 tests, with 0 failures`.
  - **Mutation check** (sequential, one snapshot, restored and `cmp`-verified identical): M1 `T_pair` without `PAD(A)`, M2 `K` = raw `S`, M3 M2 without M1 → `testPairingTranscriptMatchesVector`; M4 key info without `session_id` → `testSessionSetupMatchesVectorAndKeysSealFirstPose`; M5 `str8` without its limit, M6 TCP `session_id` unchecked → `testMalformedControlFramesAreRejected`; M7 5-digit codes accepted → `testPairingRejectsIllegalValuesAndCodes`. 7/7 caught.
  - No Rust, Python, add-on or `testdata/` change, so cargo, pytest, `gen_testdata --check` and the Blender scripts weren't re-run.
- **Flag (not a requirement change):** `swift-srp` exponentiates with `BN_mod_exp`, which BoringSSL's header says isn't for secret exponents (`CBigNumBoringSSL_bn.h:889-890`: use `BN_mod_exp_mont_consttime`). On the device the secret exponent is `a + u·x` with a fresh 256-bit `a` per attempt, so one timing trace per code; the Rust host is constant-time. Replacing it would mean patching or forking the library; left for the owner to judge.
- **Blocked:** none new.
- **Next task:** 1.4.2b (iOS session endpoint: TCP connection, HELLO → SESSION_* with these types, then UDP with `VCPSessionKeys`), then 1.4.3b. No second task started.
- **Owner actions:** none for PR #9 (auto-merge). Optional: judge the `BN_mod_exp` timing note above. Still pending: `mdns-sd`/`getrandom` reviews; whether the 60 Hz poll needs speeding up (SRS §13.4).

## 2026-09-25 — Iteration 51 — 1.4.2b (FR-TRK-001, PR-001..003, PR-006, NFR-SEC-001, NET-004) — done

- **Orientation:** no LOOP_STOP. PR #9 (1.1.4b) was ready: `gh pr checks 9 --watch` ended with every check `pass` in run `36112570520` (rust ×3 incl. windows 5m20s, fuzz, wheels ×3, extension, blender-smoke ×3, python, ios, ci-ok); the earlier `ci-ok` fail was the draft-time run `36112556531` (all jobs skipped). Auto-merge fired: `MERGED` as `5cae5e5`; `main` fast-forwarded, local branch deleted. Task from "Immediate next steps" 2. Branch `loop/1.4.2b`, PR https://github.com/0xkr4t0s/Sightline/pull/10.
- **Split of 1.4.2b (this iteration):** the device's TCP session client and its wiring into a tracking run. **1.4.2c (new, next after 1.4.3b):** vcp.md §8 device liveness (session lost after 3 s without an authenticated host datagram), reconnect with `HELLO(mode 1)` every ≤ 500 ms, and the NET-004 3 s reconnect measurement. Today a lost session stops the run instead.
- **API checked before use** (iOS 27 SDK `Network.swiftmodule/arm64e-apple-ios.swiftinterface`): `NWConnection(host:port:using:)` (`:2113`), `State.waiting/.failed/.ready/.cancelled`, `receive(minimumIncompleteLength:maximumLength:completion:)` (`:2138`), `send(content:…completion: .contentProcessed)` (`:2145-2148`), `NWPath.remoteEndpoint` (`:850`), `NWEndpoint.hostPort`, `Host.ipv4/.ipv6/.name` (`:397-401`), `IPv6Address.interface`/`asIPv4` and `NWEndpoint.Port(rawValue:)`. `NWConnection` rather than the iOS 26 `NetworkConnection`: the latter's interface has no explicit cancel (`:1763-1777`), and the session must close its TCP connection on stop.
- **Change:**
  - `SightlineIOS/SightlineIOS/VCP/VCPSessionClient.swift` (new): `VCPControlChannel` (whole control frames over `NWConnection`; `ERROR` → `.host`; refused/unroutable fails at once instead of waiting; `withDeadline` cancels the connection → `.timeout`; `peerAddress` = numeric TCP peer, IPv6 keeps `%iface`); `VCPSessionClient.pair` (HELLO mode 0 → PAIR_* → `VCPHostPairing`, connection left open for mode 1 as the host expects), `startSession` (HELLO mode 1 → SESSION_*; no proof for an unknown `host_id`; UDP to the TCP peer and the challenge's `udp_port`), `connect` (open + session within 10 s, the host's own handshake limit); `VCPLiveSession` (`destination` for the pipeline, `ended()`, `close()`); `VCPLinkError.message` for the status line.
  - `TrackingSessionController`: `pairing: VCPHostPairing?` (nil until 1.4.3b stores one) and a new session per run: connect before the pipeline starts (status "Connecting to Blender"; failure → "Not connected" + reason), which also settles iteration 41's note (seq/state_seq restart per run = per session); the run stops with "Blender session ended" when the host closes or sends `ERROR`; stop closes the TCP connection; a second tap during the handshake is ignored.
  - `TrackingSettings`: default port 47000 = Blender's control port (`core/session.py:32`; the field was the old FreeD UDP port 7000); `DeviceIdentityStore`: 16-byte `device_id` made once and kept in `UserDefaults`, name = device name cut to 64 UTF-8 bytes. `VCPPairing.randomBytes(_:)`.
  - UI: "Not paired" and control status follow `pairing`; the destination section is "Blender" with the control port.
  - `project.pbxproj`: the new file in the test target's membership list.
- **Commands run:**
  - `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'` (Debug, full suite): `Executed 50 tests, with 3 tests skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **` (skips: the two opt-in live-host tests and the Release-only allocation test). No Swift warnings (one `String(cString:)` deprecation fixed).
  - Same, `-configuration Release -only-testing:…/testPoseSendPathAllocatesNothing`: `VCAM_SEND_ALLOCATIONS poses=600 allocations=0`, `** TEST SUCCEEDED **`.
  - `-only-testing:SightlineIOSTests/VCPSessionClientTests`: `Executed 9 tests, with 1 test skipped and 0 failures`. Loopback scripted host: `session.json` HELLO/SESSION_PROOF byte-exact, keys, UDP address and host-close → `.closed` (`VCPSessionClientTests.swift:137`); `close()` gives the host EOF (`:161`); bad `proof_h` → `.pairing(.badProof)`, nothing more sent (`:180`); unknown `host_id` → no proof (`:205`); `ERROR` 3 (`:226`); silent host → `.timeout` in < 3 s (`:246`); refused → `.network` in < 3 s (`:266`); `pairing.json` HELLO/PAIR_PROOF byte-exact and PK (`:290`).
  - **Live Rust host:** wheel rebuilt (`maturin build --release … -i …/python3.13`: `Built wheel for CPython 3.13`), a throwaway host script on Blender's `python3.13` (`Session.start(0, tmp, host_id, "127.0.0.1")`, `enable_pairing()`, answering `latest_control()` with `update_status`), then `TEST_RUNNER_VCAM_INTEROP_TCP=… TEST_RUNNER_VCAM_INTEROP_CODE=… xcodebuild test -only-testing:…/testLiveSessionWithTheRustHost`: `VCAM_INTEROP_SESSION n=1 session=1652583245 udp=127.0.0.1:51900 sent=61 ack=2`, `n=2 session=3626687483 sent=30 ack=1`, `** TEST SUCCEEDED **`. Host side: events `paired`, `session_started`/`session_ended` ×2; session 1 `max_seq=60 pos=[0.3, -0.0, 0.0] state=5 control={'state_seq': 2, 'motion_scale': 2.0, 'lock_flags': 0, 'origin_epoch': 1}`, session 2 `max_seq=30`, `state_seq 1`; `VCAM_HOST_OK`. (The first host run printed `VCAM_HOST_FAIL` because the throwaway script expected x = 0.60; the test restarts x at 1 cm per batch, so 0.30 is right. Script fixed, both sides re-run green.)
  - **Mutation check** (sequential, one snapshot, restored and `cmp`-verified identical): M1 session HELLO ignores `nonce` → `:137`, `:161`; M2 `ERROR` not mapped → `:226`; M3 `.waiting` keeps waiting → `:266`; M4 deadline never fires → `:246`; M5 proof sent without a key → `:205`; M6 UDP not to the TCP peer → `:137`; M7 `close()` no-op → `:161`, `:180`, `:205`. 7/7 caught.
  - No Rust, Python, add-on or `testdata/` change, so cargo, pytest, `gen_testdata --check` and the Blender scripts weren't re-run.
- **Not verified:** the controller path in the running app (the simulator has no `ARWorldTrackingConfiguration`, and nothing stores a pairing before 1.4.3b); a device over Wi-Fi.
- **Blocked:** none new.
- **Next task:** 1.4.3b (host selection from the discovery list, pairing UI with the 6-digit code, Keychain storage of `VCPHostPairing`), then 1.4.2c. No second task started.
- **Owner actions:** none for PR #10 (auto-merge). Still pending: `mdns-sd`/`getrandom` reviews; whether the 60 Hz poll needs speeding up (SRS §13.4); optional `BN_mod_exp` note (iteration 50).

## 2026-09-25 — Iteration 52 — 1.4.3b (FR-UX-001/002, C-4) — done

- **Orientation:** no LOOP_STOP; prior PR #10 completed all checks in run 36114828722 and merged as 04ffc3b. Fast-forwarded main; branch `loop/1.4.3b`, draft PR https://github.com/0xkr4t0s/Sightline/pull/11.
- **Change:** discovered compatible hosts are selectable; the chosen DNS-SD service is remembered and connected by `NWEndpoint.service` (not the TXT display name). Manual host:port remains selectable. Settings accepts the six-digit Blender N-panel code; the app performs SRP pairing and starts a session on the same TCP connection, then closes it. Pairing host ID + key is stored in ThisDeviceOnly Keychain per service or manual address, loaded on selection/startup; session setup still checks the challenge's host ID. Pairing and connection errors reach the status UI. Pairing instructions explain iOS/macOS local-network and Windows firewall prompts. Files: `SettingsView.swift:25-87`, `TrackingSessionController.swift:12-21,87-164,175-209`, `TrackingSettings.swift:30-36`, `VCP/VCPSessionClient.swift:80-83,330-355`, new `PairingStore.swift:1-56`, `Keychain.entitlements`, `project.pbxproj` (app-hosted Keychain tests), and two iOS tests.
- **API checked:** iOS 27 Network.swiftinterface has `NWEndpoint.service(name:type:domain:interface:)` (:391), `NWConnection(to:using:)` (:2112), and `Bonjour.Endpoint.nwEndpoint` (:2369). The live simulator Bonjour test confirms that a selected service connects and yields a TCP peer address usable for UDP.
- **Verification:** `xcodebuild test` on iPhone 17 iOS 27 simulator: xcresult summary `Passed`, 49 passed, 3 skipped, 0 failed, 52 total (full suite). Keychain test stores, reloads, replaces and isolates destination keys; it initially failed with OSStatus -34018 in a standalone unsigned test runner, then passed when tests were hosted in the signed app with a Keychain entitlement. Live `NWListener` advertisement → browser selection → `NWConnection` → peer address passed. Installed and launched the app in the simulator; status screen showed `Idle` / `Not paired` with no crash. No Rust/Blender/Python or vector files changed, so their suites were not rerun.
- **Not verified:** settings sheet visuals or a complete pairing to a physical Blender host over Wi-Fi; simulator ARKit does not support world tracking. Owner device verification remains.
- **Blocked:** none new.
- **Next task:** 1.4.2c (device liveness and reconnect), then 1.3.6. No second task started.
- **Owner actions:** verify Wi-Fi pairing on physical device when available; existing `mdns-sd` / `getrandom` reviews and optional BN timing note remain.
- **Release gate:** `xcodebuild test -configuration Release -only-testing:SightlineIOSTests/TrackingPipelineTests/testPoseSendPathAllocatesNothing` passed (exit 0) with app-hosted tests. Existing Swift 6 captured-transform warnings in `VCPSessionClientTests.swift:325` remain; no production compile errors.


## 2026-09-25 — Iteration 53 — 1.4.2c1 (NET-003/004) — heartbeat/liveness sub-step done

- **Orientation:** no LOOP_STOP; clean tree. PR #11's ready run 36117125503 passed all 15 jobs, including ci-ok; the initial ci-ok failure belonged to its earlier draft run. Reissued the already-armed squash auto-merge and observed MERGED; fast-forwarded main and removed the old local branch. This iteration's branch: loop/1.4.2c1; PR https://github.com/0xkr4t0s/Sightline/pull/12.
- **Split of 1.4.2c (loop §2):** 1.4.2c1 completes authenticated host heartbeat handling and three-second loss detection. **1.4.2c2 is next:** automatic HELLO(mode 1) reconnect using the stored pairing, retries at least every 500 ms while the network is up, foreground recovery, cancellation of outstanding starts/reconnects on explicit stop, and the NET-004 three-second reconnect measurement. No reconnect implementation started here.
- **Changes:** TrackingPipeline.swift:11-12 tags snapshots with the authenticated session and loss state; :203-222 guards queued UDP callbacks with the run generation; :379-403 expires silence independently of frames/control retransmits and cancels UDP/controls; :407-430 authenticates and validates traffic before renewing the deadline, replies to CLOCK, and keeps STATUS freshness separate from liveness. TrackingSessionController.swift:300-308 ignores old-session snapshots, closes TCP/AR tracking on loss, and reports the reason. TrackingPipelineTests.swift:463-546 adds real-loopback regressions for valid heartbeats, forged tags, stale STATUS acknowledgements, initial silence, no sends after expiry, and timer cancellation on replacement/stop/unpaired use. IMPLEMENTATION_PROGRESS.md updates NET-003/004 evidence; both remain Partial.
- **Clock limitation:** replies use CLOCK_UPTIME_RAW, already used by the pipeline's send-leg meter. This is the candidate ARFrame timestamp basis, not proven on hardware. O-1 remains **BLOCKED (needs owner)**: compare it with ARFrame.timestamp on a physical iPhone before accepting pose-leg latency results. No protocol or SRS requirement changed; no new API/dependency introduced.
- **Verification (this iteration):**
  - Focused simulator suite: xcodebuild test -quiet -project SightlineIOS/SightlineIOS.xcodeproj -scheme SightlineIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SightlineIOSTests/TrackingPipelineTests. Output: XCODEBUILD_EXIT=0. xcresult summary: result Passed, passedTests 16, skippedTests 1, failedTests 0, totalTestCount 17.
  - Full simulator suite: same command without -only-testing. Output: XCODEBUILD_FULL_EXIT=0. xcresult summary: result Passed, passedTests 52, skippedTests 3, failedTests 0, totalTestCount 55. Existing skips: optimized allocation test in Debug and two opt-in live-host cases (discovery and session interop). The focused build repeated the existing VCPSessionClientTests.swift:323/325 captured-transform warnings and Xcode's “command failed with exit code 0” diagnostic; the command and test result both passed.
  - Release gate: same command with -configuration Release -only-testing:SightlineIOSTests/TrackingPipelineTests/testPoseSendPathAllocatesNothing. Output: XCODEBUILD_RELEASE_EXIT=0. xcresult summary: result Passed, passedTests 1, skippedTests 0, failedTests 0. Existing zero-allocation assertion over 600 poses passed.
  - Every Xcode/xcrun command used DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer. Result bundles: /tmp/sightline-heartbeat-{focused,full,release}.xcresult.
  - Rust/vector consumers: cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test in native/. Exit 0; output: cargo test: 60 passed (14 suites, 0.00s).
  - Python/vector consumers: .venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests. Output: 24 passed in 0.03s.
  - **Runtime smoke outside XCTest:** compiled the actual TrackingPipeline, UDPSender and VCP codec/coordinate files with xcrun swiftc -swift-version 6 -O into a throwaway macOS CLI. An independent Python UDP host checked the device-key HMAC and decoded the echoed request: HEARTBEAT_SMOKE authenticated_reply mode=1 t1=5000000000 t2=13851442440916 t3=13851442449708. After host silence: DEVICE_SESSION_LOST session=42; HEARTBEAT_SMOKE_PASS real Swift pipeline / Python UDP host; reply authenticated; silence expired. Removed the throwaway source/binary afterward.
- **Not verified:** physical-device clock alignment, Wi-Fi roaming/sleep, or the session-lost screen on device (simulator cannot run AR world tracking). No Blender/native-module code changed, so no Blender build/smoke was run. PR #12 CI is deferred until ready and will be checked next iteration.
- **Next task:** 1.4.2c2, then 1.3.6. No second task started. Owner actions: O-1 device clock check plus the existing physical-device/Windows/Linux checklist and dependency reviews.

## 2026-09-25 — Iteration 54 — 1.4.2c2 (NET-004) — done (device reconnect; real-network check owner-blocked)

- **Orientation:** no LOOP_STOP; clean tree. PR #12's ready run 36118907382 passed all 15 jobs (ci-ok pass). The earlier ci-ok failure (run 36118684461) was its draft run: all jobs `skipped`. The PR was still OPEN/CLEAN after the run, so I reissued `gh pr merge 12 --auto --squash --delete-branch` and it showed MERGED as `74819eb`; main fast-forwarded. Branch `loop/1.4.2c2`, PR https://github.com/0xkr4t0s/Sightline/pull/13.
- **Git incident (repaired, flagged):** at 19:42:39, during a simulator test run, the working copy was switched from `loop/1.4.2c2` to `main` by a checkout I didn't run (reflog `checkout: moving from loop/1.4.2c2 to main`). My uncommitted edits came along, and my next commit (`c698366`) landed on local `main`. Its push was rejected by branch protection (GH006), so nothing reached `origin/main`. Repair: cherry-picked it onto `loop/1.4.2c2` as `1fef8db` and reset local `main` to `origin/main` (`74819eb`) with `git branch -f`. No other changes appeared. Owner: check whether another tool or session switches branches in this checkout.
- **Change:**
  - `VCPSessionClient.swift:345-367`: `connect` closes its TCP channel when the calling task is cancelled (`withTaskCancellationHandler`, confirmed typed-throws variant in the iOS 27 SDK `_Concurrency.swiftinterface:3191`, available iOS 13). A cancelled start ends at once with `.closed` instead of waiting for the 10 s deadline, and a session completed after cancellation is closed. `nonce` is a parameter so tests can replay `session.json`.
  - `VCPSessionClient.swift:370-423`: `VCPReconnect`. `run` retries an attempt until it returns a session. Attempts start ≤ 500 ms apart (vcp.md §8), each capped at `attemptTimeout` 2 s so a stalled SYN on a dead network is abandoned. Fatal errors stop the loop: `ERROR` notPaired/proofFailed, unknown host, pairing/proof failure. Everything else is retried: network, timeout, closed, unexpected, busy. Cancellation ends it with `.closed`.
  - `TrackingSessionController.swift`: `sessionLost` (`:300`) replaces the old stop on TCP close/`ERROR` (`watch`, `:286`) and on 3 s silence (`:407`). AR keeps running; the pipeline gets a no-endpoint destination (poses shown, nothing sent); status "Reconnecting to Blender". `reconnected` (`:333`) binds the new session (`pipeline.start` restarts seq/state_seq and sends the full CONTROL_STATE, §8) and records `lastReconnectSeconds`. A fatal error stops with "Pairing no longer accepted". `stopTracking` (`:354`) bumps `runGeneration` and cancels the pending start and reconnect. A start checks the generation after the camera prompt and the handshake (`:196`). `handleScenePhase` (`:380`): leaving the foreground mid-run (or mid-start) stops it and sets `resumeWhenActive`; `.active` starts it again. An explicit stop clears the flag. `SessionTarget` (`:472`) remembers the Bonjour service or the typed address for reconnects. AR tracking-state events don't overwrite the reconnect status.
  - `ContentView.swift:85,141`: the rail button is Stop while a start is pending (so an explicit stop can cancel it); connection label "Reconnecting". `SettingsView.swift:109-111`: "Last reconnect" row.
  - Tests (`SightlineIOSTests/VCPSessionClientTests.swift`): `ScriptedHost` can bind a given port (SO_REUSEADDR), plus a `freePort()` helper. `:340` host down 1.2 s then back on the same port, replaying `session.json`: session < 3 s after listening, ≥ 3 attempts, gaps < 650 ms. `:382` `ERROR` 3 stops after 1 attempt, plus the fatal/transient classification. `:417` cancel mid-handshake → `.closed` in < 1 s and the host sees EOF. `:534` opt-in live Rust host restart (`TEST_RUNNER_VCAM_RESTART_TCP`/`_CODE`).
- **Swift toolchain note:** `Task { () async throws(VCPLinkError) -> T in … }` crashed the Xcode 27 compiler in IR emission ("While emitting IR SIL function …testCancellingAReconnect…"). Tasks that return `Result<T, VCPLinkError>` compile; the controller and the tests use that.
- **Verification (this iteration; all Xcode commands with `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer`):**
  - Focused `-only-testing:SightlineIOSTests/VCPSessionClientTests`: result Passed, passedTests 11, skippedTests 2 (the two opt-in live-host tests), failedTests 0.
  - Reconnect tests with stdout: `NET004_RECONNECT host_back_to_session_ms=301 attempts=4`; `Executed 3 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`.
  - **Live Rust host (NET-004 measurement):** wheel rebuilt (`maturin build --release -i …/5.2/python/bin/python3.13`: `Built wheel for CPython 3.13`). A throwaway host on Blender's python3.13 (`Session.start(0, tmp, host_id, "127.0.0.1")`, `enable_pairing()`, `update_status` acknowledging each new `state_seq`) stopped after 10 applied poses, stayed down 1 s, and restarted with the same port, `config_dir` and `host_id`, i.e. a Blender reload with pairings kept. Host: `HOST_DOWN at=1790329566.066`, `HOST_BACK at=1790329567.077 port=51885`. Device: `VCAM_RESTART end=closed lost_at=1790329566.242 accepted_at=1790329567.303 loss_to_session_ms=1061 attempts=3 session=3725046352 ack=1`, `** TEST SUCCEEDED **`. **Host listening again → new session: 226 ms** (NET-004 ≤ 3 s), no re-pairing, and the new session's first CONTROL_STATE was acknowledged.
  - **Mutation check** (sequential, one snapshot, restored and `cmp`-verified identical): M1 `ERROR` notPaired treated as transient → `** TEST FAILED **`. M2 retry every 1 s instead of 500 ms → `** TEST FAILED **`. M3 no channel close on cancel → cancel test `XCTAssertLessThan failed` (failedTests 1). 3/3 caught.
  - Full simulator suite: FULL_EXIT=0; result Passed, passedTests 55, skippedTests 4, failedTests 0, totalTestCount 59. No build warnings in the log.
  - Release gate `-configuration Release -only-testing:SightlineIOSTests/TrackingPipelineTests/testPoseSendPathAllocatesNothing`: RELEASE_EXIT=0, passedTests 1, failedTests 0.
  - `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` (native/, no Rust change): cargo test: 60 passed, 0 failed (14 suites). `pytest BlenderAddOn/tests`: `24 passed in 0.02s`. `gen_testdata.py --check`: `testdata/ up to date (21 files)`.
- **Not verified:** the controller path in the running app. The simulator has no `ARWorldTrackingConfiguration`, so `startTracking` stops at "Unsupported", and the controller wiring (session loss → reconnect → rebind, foreground resume) was only compiled and checked for types; the loop it drives is what the tests exercise. Also not verified: real Wi-Fi roaming, sleep/wake and backgrounding on a device. Added to Blocked items.
- **No protocol, SRS or dependency change.** No Blender/add-on code changed, so the Blender scripts weren't run.
- **Next task:** 1.3.6, hold last good pose (FR-TRK-002, Blender side). No second task started.
- **Owner actions:** the NET-004 device check (Blocked items) together with O-1 and 1.5.1c; look into the unexpected branch switch in this checkout.

## 2026-09-25 — Iteration 55 — 1.4.2c2 CI fix (NET-004) — iOS job failed on PR #13, fixed on the same branch

- **Orientation:** no LOOP_STOP; clean tree on `loop/1.4.2c2`. PR #13 is ready and auto-merge is armed. The ci-ok failure in run 36120619332 came from the draft run (every job `skipped`). The ready run 36120638206 failed its `ios` job (Xcode 26.6, iOS 26.5 SDK): `VCPSessionClient.swift:348:34: error: thrown expression type 'any Error' cannot be converted to error type 'VCPLinkError'`, `** TEST FAILED **`. Fixing it on this branch is this iteration's task (§1b).
- **Cause:** the `withTaskCancellationHandler<Return, Failure>` typed-throws overload is only in the Xcode 27 SDK (`_Concurrency.swiftinterface:3191`). The Xcode 26 SDK has only the `rethrows` form, so the thrown `VCPLinkError` became `any Error`. Iteration 54 checked the signature only in the iOS 27 SDK, so it wrongly treated the overload as available on CI's toolchain.
- **Change:** `SightlineIOS/SightlineIOS/VCP/VCPSessionClient.swift:348-364`: the cancellation-handler operation is now non-throwing and returns `Result<VCPLiveSession, VCPLinkError>`; `outcome.get()` (typed `throws(Failure)`) rethrows it as `VCPLinkError`. Behaviour is unchanged: cancelling still closes the channel, and so does any error. `IMPLEMENTATION_PROGRESS.md` NET-004: updated the shifted citations (`VCPReconnect` `:381-430`, cancel handler `:361`).
- **Verification (Xcode 27 is the only Xcode installed locally, so the Xcode 26 build is checked only by CI):**
  - Throwaway `swiftc -typecheck -swift-version 6` with a `rethrows`-only function that has the Xcode 26 signature: the old closure form reproduces the CI error (`error: thrown expression type 'any Error' cannot be converted to error type 'E'`), and the new `Result` form typechecks with no error. The file was deleted afterwards.
  - Full simulator suite (`xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'`, `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer`): `Executed 59 tests, with 4 tests skipped and 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`. This includes the cancel-mid-handshake and reconnect tests in `VCPSessionClientTests`.
  - Only Swift changed, so Rust, pytest and Blender were not rerun.
- **Next task:** check that PR #13 merges (§1b), then 1.3.6 (hold last good pose, FR-TRK-002). No second task started.
- **Owner actions:** unchanged from iteration 54.

## 2026-09-25 — Iteration 56 — 1.4.2c2 CI check (NET-004) — STOPPED: CI failed on PR #13 in two consecutive iterations

- **Orientation:** no LOOP_STOP; clean tree on `loop/1.4.2c2` (HEAD `f0eeba8`, in sync with origin). PR #13 is ready and auto-merge is armed. `gh pr checks 13 --watch` ran until run 36121029972 finished (about 5 min).
- **Result:** 14 jobs passed: rust-fmt, rust ×3, wheels ×3, python, fuzz, extension and blender-smoke ×3. `ios` failed (Xcode 26.6 / iOS 26.5 SDK): `VCPSessionClientTests.swift:437:31: error: pattern that the region-based isolation checker does not understand how to check. Please file a bug`, `** TEST FAILED **`. `ci-ok` failed as a result; `gh pr view 13` → `{"mergeStateStatus":"BLOCKED","state":"OPEN"}`.
- **Cause [INFERENCE]:** in `testCancellingAReconnectClosesTheHandshakeAtOnce` (tests only), line 437 is `await Task.detached { Self.block(on: helloSeen, seconds: 5) }.value`, which captures a `DispatchSemaphore` in a detached task. The Xcode 26 region-isolation checker rejects this; Xcode 27 accepts it (iteration 55 ran 59 tests with 0 failures). Production code in `VCPSessionClient.swift` compiled on CI because the error is in the test target.
- **Stop (§6):** CI failed on the same PR in consecutive iterations (55: `VCPSessionClient.swift:348` typed-throws; 56: this one). Created `docs/LOOP_STOP` (not committed) and commented on PR #13. No code changed and no tests were run locally: nothing changed on the branch.
- **Next task:** after the owner deletes LOOP_STOP, fix `VCPSessionClientTests.swift:437` for Xcode 26 on `loop/1.4.2c2` (§1b), then 1.3.6.
- **Owner actions:** decide on #13 (see LOOP_STOP); the existing NET-004 and O-1 device checks.
- **Resolution (owner, same day):** the owner pointed to PR #14 (`ci/xcode-27-runner`, merged to main as `1cbb748`), which moves the `ios` job to the `xcode-27` preview runner (Xcode 27, `iPhone 17`, the same as local builds). Merged `origin/main` into `loop/1.4.2c2` (merge commit, no history rewrite; only `.github/workflows/ci.yml` changed). Removed `docs/LOOP_STOP`. No Swift code changed, so the iteration-55 local Xcode 27 result (59 tests, 0 failures) still applies. CI on the new runner decides the merge.
