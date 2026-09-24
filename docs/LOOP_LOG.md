# Agent Loop Log

Append-only. One entry per iteration (see `docs/AGENT_LOOP_PROMPT.md` §5).

## Blocked items

| Task | Status | Reason |
|---|---|---|
| — | — | — |

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
