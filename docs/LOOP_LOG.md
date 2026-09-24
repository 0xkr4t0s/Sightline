# Agent Loop Log

Append-only. One entry per iteration (see `docs/AGENT_LOOP_PROMPT.md` §5).

## Blocked items

| Task | Status | Reason |
|---|---|---|
| S-1 on Windows and Linux (mid-range GPU) | BLOCKED (needs owner) | SRS §8.2 wants every OS. CI runners have no GPU, so this needs the owner's Windows/Linux machines: run `tests/bench_render.py` headless (recipe in its docstring) and commit the JSON to `reports/`. |
| S-1 EEVEE vs. FR-REN-004/NFR-PERF-002 | Resolved 2026-09-24 | EEVEE exempt with a warning; SRS updated. |
| 0.1.5 CI green on GitHub (P0 exit gate) | Needs owner push | First run `35958600428`: only `cargo clippy` failed (3 OSes); fixed locally in iteration 15. Push, then the loop reads the next run. |
| S-2d Media Foundation H.264 and S-2e JPEG on Windows/Linux x86-64 | BLOCKED (needs owner) | Needs Windows/Linux machines or a CI remote. Run `cargo run --release -p vcam-video --example s2_jpeg -- <frames>` there (x86-64 needs `nasm`). |
| S-2 H.264 software-fallback licensing | Resolved 2026-09-24 | Option A: hardware H.264, JPEG fallback; NET-VID-003 updated. |
| S-3b Developer ID signing + notarization of the macOS wheel | BLOCKED (needs owner) | Needs an Apple Developer account and credentials. Re-run `tests/s3_macos_loading.sh --gui` with a signed and notarized `.so`. |
| S-3c Windows SmartScreen / Mark-of-the-Web | BLOCKED (needs owner) | Needs a Windows machine. |

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
