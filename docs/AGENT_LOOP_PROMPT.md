You are working autonomously on Sightline (formerly VCam for Blender; the repo and code identifiers still say vcam) at "/Users/owner/iCloud Drive (Archive)/My Projects/VCamBlender". The path contains spaces, so always quote it. The product is an iPhone virtual camera for Blender: the iPhone pose drives a Blender camera, and Blender streams its camera view back to the iPhone. Each iteration, finish exactly ONE task from the plan, verify it, record it, then stop.

## 0. Stop file
- If `docs/LOOP_STOP` exists, do nothing else: print its contents and end the iteration. The owner deletes it to resume.
- Whenever a stop condition in section 6 is met, create `docs/LOOP_STOP` with the date, the reason, and what the owner needs to do. Don't commit it. Also post the same text on GitHub so the owner sees it: `gh pr comment <n>` on the open PR, or, if none is open, `gh issue create --title "Loop stopped: <reason>"`.

## 1. Orient (every iteration)
- Read `AGENTS.md`, `IMPLEMENTATION_PROGRESS.md`, and `docs/IMPLEMENTATION_PLAN.md`. Open `docs/SRS.md` only for the requirement IDs your task cites.
- Read `docs/LOOP_LOG.md` (create it if missing) for earlier iterations and blocked items.
- If git exists, run `git status` and `git log --oneline -5`. If there are uncommitted changes you didn't make, stop and report them.

## 1b. Sync with GitHub (every iteration, before picking a task)
All work is published on GitHub as it happens: one `loop/<task ID>` branch and one PR per task. GitHub merges the PR by itself (auto-merge, squash) once the required `ci-ok` check passes; `main` is protected, so nothing reaches it any other way. Only one loop PR is open at a time. Run `git fetch origin` and `gh pr list --state open --json number,title,isDraft,headRefName`, then handle the first case that applies:
- **Local `main` is ahead of `origin/main`** (commits made before this flow): `git push origin main:refs/heads/loop/sync-<date>`, open a PR from it (not a draft), and run `gh pr merge <n> --auto --merge` (a merge commit, so the task commits keep their messages). Then treat it as a ready PR below.
- **An open loop PR is still a draft** (an earlier iteration was interrupted): `git switch` to its branch and continue that task. It is this iteration's task.
- **An open loop PR is ready:** wait with `gh pr checks <n> --watch` (cap 10 minutes), then look at `gh pr view <n> --json state,mergeStateStatus`.
  - Merged: `git switch main && git pull --ff-only`, delete the local branch, and continue to §2.
  - A check failed: read `gh run view <id> --log-failed`. Fixing it on the same branch and PR is this iteration's task (auto-merge stays armed and fires once CI is green). Record the failure in the log.
  - Still running after 10 minutes: log "waiting on CI for #<n>" and end the iteration. Don't start new work.
- **No open loop PR:** make sure `main` is up to date (`git switch main && git pull --ff-only`) and continue to §2.

Never push to `main`, force-push, rewrite pushed history, merge with `--admin`, or change branch protection or repository settings. Don't touch PRs the loop didn't open.

## 2. Pick the task
- Use the current phase: the earliest phase whose exit gate isn't met. Follow "Immediate next steps" order first, then the table order. Skip anything marked done or blocked in the log.
- **Tasks you must NOT do. Mark them `BLOCKED (needs owner)` in the log and move on:**
  - anything needing a physical iPhone or a human in front of the Blender UI: device testing, real-Wi-Fi latency (S-4), thermal runs, and the manual checklists in exit gates;
  - Apple Developer signing, notarization, TestFlight/App Store, or any credentials;
  - pushing to `main`, force-pushing, creating remote repos, changing repository settings, branch protection or secrets, or publishing an extension repository. Pushing `loop/*` branches and opening, updating and auto-merging their PRs as §1b, §3 and §5 describe is allowed; so are writing CI workflow files and reading CI results. Don't weaken the `ci-ok` job in `.github/workflows/ci.yml` to get a PR merged;
  - licence decisions (spike S-5): write up the options in the log instead;
  - installing global tools other than `cargo install cargo-fuzz` / `rustup component add` (ask first for anything else, for example Homebrew packages). Python packages go only into the project venv `.venv.nosync/` (pytest and maturin are already there).
- If a task is bigger than one iteration, split it into sub-steps in the log and do only the first.

## 3. Do the work
- **Publish first.** From an up-to-date `main`: `git switch -c loop/<task ID>` (for example `loop/1.5.2a`), `git commit --allow-empty -m "<task ID>: start"`, `git push -u origin HEAD`, then `gh pr create --draft --title "<task ID> <requirement IDs>: <short summary>" --body "<goal, cited IDs, and a checklist of the planned sub-steps>"`. Skip this if §1b already put you on a draft PR's branch.
- **Push as you go.** After each meaningful step (a sub-step done, a test suite passing, a spike measurement taken), commit and `git push`, and tick the checklist with `gh pr edit <n> --body`. Stage files by name after checking `git status`; never commit anything ignored by `.gitignore`, credentials, or large binaries. CI doesn't run on drafts, so work-in-progress pushes cost no Actions minutes.
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
  - Rust build output goes to `native/target.nosync/` (set in `.cargo/config.toml`). Don't change this or use `target/`.
  - Xcode: prefix every `xcodebuild`/`xcrun` command with `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer` (the system default points at Command Line Tools).
  - Blender's bundled Python is 3.13 (`/Applications/Blender.app/Contents/Resources/*/python/bin/python3.13`); build wheels for it (for example `maturin build -i <that path>`), not for the venv's 3.14.
- Rust (once `native/` exists): `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` in `native/`.
- Blender: `"/Applications/Blender.app/Contents/MacOS/Blender" --background --factory-startup --python <test script>` for anything touching the add-on or the native module. Build the wheel with maturin first.
- Python unit tests: `.venv.nosync/bin/pytest -q -p no:cacheprovider BlenderAddOn/tests`.
- iOS: `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer xcodebuild test -project SightlineIOS/SightlineIOS.xcodeproj -scheme SightlineIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (iOS 27.0 simulator runtime is installed; the shared scheme includes `SightlineIOSTests`). Unit tests only; ARKit can't run in the simulator.
- CI (GitHub Actions: Windows, Linux, macOS, iOS) runs once the PR is marked ready. It covers the other OSes; it doesn't replace the local runs above.
- Run every suite your change touches, plus every suite that reads `testdata/`. Only report a result you got from a command run in this iteration, and copy the pass/fail line from its output into the log. If something fails and you can't fix it within this iteration, revert your change, log the failure with its output, and stop.

## 5. Record
- Update `IMPLEMENTATION_PROGRESS.md` for every requirement ID whose status changed, citing evidence file and line.
- Spike results go into SRS §13 (dated), with the numbers. If you find something that contradicts the SRS or plan, don't silently change requirements: add a dated note under SRS §13 and flag it in the log.
- Append to `docs/LOOP_LOG.md`: date, task ID, files changed, commands run with pass/fail counts, anything blocked, and the next task.
- Commit and push the final state, including the log and progress updates. Set the PR title to `<task ID> <requirement IDs>: <summary>` (it becomes the squash commit's subject on `main`, so it follows the commit convention) and the body to: what changed, the pass/fail lines copied from the log, anything blocked, and owner actions. Then `gh pr ready <n>` and `gh pr merge <n> --auto --squash --delete-branch`. Don't wait for CI; the next iteration checks the result (§1b).
- If you reverted a failed task (§4), still push the log entry, leave the PR as a draft, and comment on it with the reason.

## 6. Stop conditions: create `docs/LOOP_STOP`, then report
- A phase exit gate is met, apart from items that need the owner. Summarise and wait.
- Every remaining task in the phase is blocked on the owner.
- The same task has failed in two consecutive iterations, or CI has failed on the same PR in two consecutive iterations.
- GitHub is unreachable, `gh` isn't authenticated, or Actions can't run (for example the minutes quota is used up).
- You're about to do something from the "must NOT do" list.

End each iteration with 3–5 lines: task done, tests run and result, the PR link, next task, and any owner action needed.
