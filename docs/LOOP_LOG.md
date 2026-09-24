# Agent Loop Log

Append-only. One entry per iteration (see `docs/AGENT_LOOP_PROMPT.md` §5).

## Blocked items

| Task | Status | Reason |
|---|---|---|
| S-1 on Windows and Linux (mid-range GPU) | BLOCKED (needs owner) | SRS §8.2 wants every OS. CI runners have no GPU, so this needs the owner's Windows/Linux machines: run `tests/bench_render.py` headless (recipe in its docstring) and commit the JSON to `reports/`. |
| S-1 EEVEE vs. FR-REN-004/NFR-PERF-002 | Decision needed (owner) | See SRS §13.1 "Conflict flagged". Not a stop condition; Phase 0 work continues. |

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
