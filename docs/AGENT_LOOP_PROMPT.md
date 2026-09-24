You are working autonomously on VCam for Blender at "/Users/owner/iCloud Drive (Archive)/My Projects/VCamBlender". The path contains spaces, so always quote it. The product is an iPhone virtual camera for Blender: the iPhone pose drives a Blender camera, and Blender streams its camera view back to the iPhone. Each iteration, finish exactly ONE task from the plan, verify it, record it, then stop.

## 0. Stop file
- If `docs/LOOP_STOP` exists, do nothing else: print its contents and end the iteration. The owner deletes it to resume.
- Whenever a stop condition in section 6 is met, create `docs/LOOP_STOP` with the date, the reason, and what the owner needs to do.

## 1. Orient (every iteration)
- Read `AGENTS.md`, `IMPLEMENTATION_PROGRESS.md`, and `docs/IMPLEMENTATION_PLAN.md`. Open `docs/SRS.md` only for the requirement IDs your task cites.
- Read `docs/LOOP_LOG.md` (create it if missing) for earlier iterations and blocked items.
- If git exists, run `git status` and `git log --oneline -5`. If there are uncommitted changes you didn't make, stop and report them.

## 2. Pick the task
- Use the current phase: the earliest phase whose exit gate isn't met. Follow "Immediate next steps" order first, then the table order. Skip anything marked done or blocked in the log.
- **Tasks you must NOT do. Mark them `BLOCKED (needs owner)` in the log and move on:**
  - anything needing a physical iPhone or a human in front of the Blender UI: device testing, real-Wi-Fi latency (S-4), thermal runs, and the manual checklists in exit gates;
  - Apple Developer signing, notarization, TestFlight/App Store, or any credentials;
  - `git push`, creating remote repos or PRs, or publishing an extension repository. You MAY write CI workflow files, but can't run them remotely;
  - moving the repo out of iCloud;
  - licence decisions (spike S-5): write up the options in the log instead;
  - installing global tools other than `cargo install cargo-fuzz` / `rustup component add` (ask first for anything else, for example Homebrew packages). Python packages go only into the project venv `.venv.nosync/` (pytest and maturin are already there).
- If a task is bigger than one iteration, split it into sub-steps in the log and do only the first.

## 3. Do the work
- Follow the cited SRS IDs and the target layout in the plan. Match the surrounding style. Keep changes scoped to the task.
- Protocol and coordinate work goes through golden vectors in `testdata/`, consumed by the Rust, Swift, and Python tests.
- Rust: no `unwrap`/`expect` on network data; `unsafe` only in FFI/encoder modules, with `// SAFETY:` comments; release the GIL for blocking work.
- Blender: never touch `bpy`/`gpu` off the main thread.
- Don't guess APIs. Before using a PyO3, Blender `bpy`/`gpu`, Network framework, or VideoToolbox call you haven't already seen working in this repo, confirm it exists: read the crate source under `~/.cargo/registry`, run a one-line check in headless Blender, or check the Apple SDK headers/docs.
- Keep the diff small. Don't refactor, rename, or reformat code your task doesn't need. Add a dependency only if the plan names it, pin its version, and note it in the log.
- Don't edit `AGENTS.md`, this file, or requirement text in `docs/SRS.md` (only §13 notes are allowed).
- Kill any command that runs longer than 10 minutes and treat it as a failure.
- Never edit or delete `Software Requirements Specification (SRS) .pdf`. For task 0.1.1, archive `VCamIOS/.git` to `~/VCamIOS-git-backup-<date>.tar.gz` before importing its history. Move `DesktopReceiver/` to `legacy/` rather than deleting it until the plan says so.

## 4. Verify (required before recording success)
- Toolchain is already set up; don't reconfigure it:
  - Python: use `.venv.nosync/bin/python`, `.venv.nosync/bin/pytest`, `.venv.nosync/bin/maturin`. Never `pip install` outside that venv.
  - Rust build output goes to `native/target.nosync/` (set in `.cargo/config.toml` so iCloud doesn't sync it). Don't change this or use `target/`.
  - Xcode: prefix every `xcodebuild`/`xcrun` command with `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer` (the system default points at Command Line Tools).
  - Blender's bundled Python is 3.13 (`/Applications/Blender.app/Contents/Resources/*/python/bin/python3.13`); build wheels for it (for example `maturin build -i <that path>`), not for the venv's 3.14.
- Rust (once `native/` exists): `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` in `native/`.
- Blender: `"/Applications/Blender.app/Contents/MacOS/Blender" --background --factory-startup --python <test script>` for anything touching the add-on or the native module. Build the wheel with maturin first.
- Python unit tests: `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`.
- iOS: `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer xcodebuild test -project VCamIOS/VCamIOS.xcodeproj -scheme VCamIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (iOS 27.0 simulator runtime is installed; the shared scheme includes `VCamIOSTests`). Unit tests only; ARKit can't run in the simulator.
- Run every suite your change touches, plus every suite that reads `testdata/`. Only report a result you got from a command run in this iteration, and copy the pass/fail line from its output into the log. If something fails and you can't fix it within this iteration, revert your change, log the failure with its output, and stop.

## 5. Record
- Update `IMPLEMENTATION_PROGRESS.md` for every requirement ID whose status changed, citing evidence file and line.
- Spike results go into SRS §13 (dated), with the numbers. If you find something that contradicts the SRS or plan, don't silently change requirements: add a dated note under SRS §13 and flag it in the log.
- Append to `docs/LOOP_LOG.md`: date, task ID, files changed, commands run with pass/fail counts, anything blocked, and the next task.
- Once git exists, commit locally: `<task ID> <requirement IDs>: <summary>`. Never push.

## 6. Stop conditions: create `docs/LOOP_STOP`, then report
- A phase exit gate is met, apart from items that need the owner. Summarise and wait.
- Every remaining task in the phase is blocked on the owner.
- The same task has failed in two consecutive iterations.
- You're about to do something from the "must NOT do" list.

End each iteration with 3–5 lines: task done, tests run and result, next task, and any owner action needed.
