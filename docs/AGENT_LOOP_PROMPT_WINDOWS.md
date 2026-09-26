This is a **second, parallel** loop, run on the owner's Windows machine, alongside the main loop from `docs/AGENT_LOOP_PROMPT.md` (which normally runs on the owner's Mac). Don't edit that file, and don't do its tasks — this file exists only so the two loops can run at the same time without colliding on the same branches, PRs or task IDs. Read `docs/AGENT_LOOP_PROMPT.md` once for full context (product description, privacy rules, verify/record conventions) — everything there applies here too, except where this file overrides it. Each iteration, finish exactly ONE task from the list in §2, verify it, record it, then stop.

## 0. Stop files
- If `docs/LOOP_STOP` exists (the shared, global stop file): stop immediately, print its contents, and end the iteration. This file is shared with the Mac loop — don't delete it; the owner does.
- If `docs/LOOP_STOP_WINDOWS` exists: same — stop, print, end. This is this loop's own stop file, so a Windows-only problem doesn't halt the Mac loop.
- When a stop condition in §6 is met, create `docs/LOOP_STOP_WINDOWS` (not the shared one, unless §6 says otherwise) with the date, the reason, and what the owner needs to do. Don't commit it. Also post the same text on GitHub: `gh pr comment <n>` on this loop's open PR, or `gh issue create --title "Windows loop stopped: <reason>"` if none is open.
- This runs under `/loop` in self-paced (dynamic) mode: after each iteration you decide whether to schedule another one. Finding either stop file at the top of an iteration means stopping the loop itself, not just ending that turn — don't schedule another wakeup.

## 1. Orient (every iteration)
- Read `AGENTS.md`, `IMPLEMENTATION_PROGRESS.md`, `docs/IMPLEMENTATION_PLAN.md`, and this file.
- Read `docs/LOOP_LOG.md`'s "Blocked items" table (shared with the Mac loop) for the Windows-only rows and their current status.
- Run `git status` and `git log --oneline -5`. If there are uncommitted changes you didn't make, stop and report them.
- Run `git fetch origin` before doing anything else — the Mac loop may have merged into `main` since you last looked.

## 1b. Sync with GitHub (every iteration, before picking a task)
Same mechanics as `docs/AGENT_LOOP_PROMPT.md` §1b, with one difference: **this loop's branches and PRs use the prefix `loop-win/`, never `loop/`.** Run `gh pr list --state open --author @me --json number,title,isDraft,headRefName` and keep only PRs whose `headRefName` starts with `loop-win/`. PRs starting with `loop/` belong to the Mac loop — never read, wait on, comment on, or touch them.
- **Local `main` is ahead of `origin/main`:** same recipe as the main prompt, but push to `loop-win/sync-<date>`.
- **An open `loop-win/*` PR is still a draft:** switch to its branch and continue that task.
- **An open `loop-win/*` PR is ready:** wait with `gh pr checks <n> --watch` (cap 10 minutes), then check state; merged → sync `main` and continue; check failed → fix on the same branch/PR; still running after 10 minutes → log and end the iteration.
- **No open `loop-win/*` PR:** `git switch main && git pull --ff-only`, then continue to §2.

Never push to `main`, force-push anything but your own `loop-win/*` branch, rewrite pushed history, merge with `--admin`, or change branch protection/repository settings.

## 2. Pick the task
This loop exists specifically to clear the items in `docs/LOOP_LOG.md`'s "Blocked items" table that say **"needs owner"** because they need a Windows machine — the Mac loop physically cannot do them. Do the earliest one below that isn't already resolved (re-check `IMPLEMENTATION_PROGRESS.md` and the blocked table first — the owner or the Mac loop may have updated it since you last looked):

1. **S-1 on Windows** (SRS §13.1, `NFR-PERF-002`): run `tests/bench_render.py` headless on this machine's GPU, following the recipe in its docstring; commit the JSON to `reports/` and add the numbers to SRS §13.1 under a new dated "Windows" subsection (don't edit existing macOS numbers).
2. **S-2d/e on Windows** (SRS §13.2, `NET-VID-002/003`): JPEG timing via `cargo run --release -p vcam-video --example s2_jpeg -- <frames>` (x86-64 needs NASM on PATH for `turbojpeg-sys`; install it locally if missing, same as CI does) and, if a Media Foundation H.264 example already exists in `vcam-video` (check before assuming it doesn't — if it doesn't exist yet, that's a separate, bigger task; log it as still blocked and move to the next item rather than building the MFT backend in one iteration), its timing too. Record results in SRS §13.2 under a new dated "Windows" subsection.
3. **S-3c: Windows SmartScreen / Mark-of-the-Web for the `.pyd`** (SRS §13.3, `XP-004`): there's no Windows harness yet. Read `tests/s3_macos_loading.sh` for the shape of the macOS one (fresh extension install, quarantine/no-quarantine scenarios, headless + GUI, raw output saved to `reports/`) and write an analogous `tests/s3_windows_loading.ps1`: apply/remove the `Zone.Identifier` alternate data stream (`Unblock-File`, or `Set-Content -Path <file> -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3"`) on the downloaded zip vs. the extracted `.pyd`, install via `blender --command extension install-file`, import via `tests/blender/smoke_native.py` headless and in the GUI, and check Windows Defender SmartScreen / Event Viewer (Microsoft-Windows-AppLocker or SmartScreen event sources) for a block. Record results in SRS §13.3 under a new dated "Windows" subsection, same table shape as the macOS one.
4. **NET-001 Windows verification** (`IMPLEMENTATION_PROGRESS.md` NET-001 row: "Windows/Linux runtime verification" still open): run a real DNS-SD advertise/discover smoke test on this machine (the pure-Rust `mdns-sd` path, no Bonjour service needed) — confirm the service advertises, a discovery client on the same machine or LAN sees it, and note whether the first listening socket triggers the Windows Firewall prompt that C-4 in the SRS describes. Record in the NET-001 row.
5. Only once 1–4 are all resolved: ask the owner (via a PR/issue comment, not silently) what Windows-only work to do next, and stop.

**Do not** pick a task from the main phase list (any `0.x`/`1.x`/`2.x`/`3.x` task ID, or any requirement not in the list above) — that's the Mac loop's job, and touching the same source files risks a merge conflict with it. **Tasks you must NOT do**, same as the main prompt: anything needing a physical iPhone or a human at the Blender UI beyond the one-time SmartScreen dialog in item 3, Apple Developer signing/notarization/TestFlight, pushing to `main`, force-pushing, changing repo/branch-protection settings, or installing global tools beyond what a task above names (ask first for anything else).

## 3. Do the work
- **Publish first.** From an up-to-date `main`: `git switch -c loop-win/<task ID>` (for example `loop-win/s1-windows`), `git commit --allow-empty -m "<task ID> Windows: start"`, `git push -u origin HEAD`, then `gh pr create --draft --title "<task ID> Windows: <short summary>" --body "<goal, cited IDs, and a checklist>"`. Skip this if §1b already put you on a draft PR's branch.
- **Push as you go**, same as the main prompt.
- First iteration only: confirm and record this machine's toolchain paths (Blender install path, `rustc --version`, the venv's `python.exe`/`pytest.exe` under `.venv.nosync\Scripts\`) as a new "Environment on the owner's Windows machine (<date>)" line in `IMPLEMENTATION_PROGRESS.md`, next to the existing macOS one. Don't overwrite the macOS line.
- **No personal data (public repo).** Same rules as `AGENTS.md`, with the Windows-specific cases: no `C:\Users\<name>\...` paths (write repo-relative paths, or `<path>`), no machine/computer name, no Windows Firewall/Defender log lines that include a local IP or MAC address (redact with `<host>`). CI runner paths (`D:\a\...`) are fine.
- Keep the diff small: a report file under `reports/`, a dated SRS §13 subsection, an `IMPLEMENTATION_PROGRESS.md` line, a `docs/LOOP_LOG.md` entry, and the matching row in the "Blocked items" table (change its status to "Resolved <date>" with a one-line pointer, don't delete the row). Don't touch source files the phase task list owns (`native/`, `BlenderAddOn/`, `SightlineIOS/`) unless a task above explicitly names a file there (for example the new `tests/s3_windows_loading.ps1`).

## 4. Verify
- `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` in `native/` — same commands as the main prompt, they're cross-platform.
- Blender: `& "<Blender install path>\blender.exe" --background --factory-startup --python <test script>`.
- Python: `.venv.nosync\Scripts\python.exe`, `.venv.nosync\Scripts\pytest.exe` (Windows venvs use `Scripts\`, not `bin/`). Never `pip install` outside that venv.
- No Xcode/iOS steps — this loop never touches `SightlineIOS/`.
- GitHub Actions CI still runs on the PR once marked ready; it's a cross-check, not a replacement for the local runs above.
- Only report a result you got from a command you actually ran this iteration.

## 5. Record
- Update `IMPLEMENTATION_PROGRESS.md` and the "Blocked items" table row for whichever task you did, citing the report file and SRS section.
- Add the dated, OS-tagged subsection to SRS §13 (don't touch other OSes' existing numbers).
- Append to `docs/LOOP_LOG.md`: date, task ID, files changed, commands run with pass/fail, anything blocked, next task. Head the entry `## <date> — Windows Iteration N — <task ID>` so it's clearly this loop's entry, not the Mac loop's, when read later.
- Commit and push. PR title `<task ID> Windows: <summary>`; body has what changed, the pass/fail lines, anything blocked, owner actions. Then `gh pr ready <n>` and `gh pr merge <n> --auto --squash --delete-branch`.
- **If the push or PR shows a conflict with `main`** (likely if the Mac loop merged into `IMPLEMENTATION_PROGRESS.md` or `docs/LOOP_LOG.md` around the same time): don't force a merge. Run `git fetch origin && git rebase origin/main` on your `loop-win/*` branch; if the rebase applies cleanly, `git push --force-with-lease` (only ever on your own `loop-win/*` branch, never `main`). If it doesn't apply cleanly, re-add just your own small edit against the new file contents by hand and re-push — don't try to reconcile the Mac loop's content beyond keeping it intact. If you're not confident the result is correct, stop and create `docs/LOOP_STOP_WINDOWS` instead of guessing.

## 6. Stop conditions
- All four tasks in §2 are resolved. Summarize and wait for the owner to assign more Windows-only work.
- The same task has failed in two consecutive iterations, or CI has failed on the same PR in two consecutive iterations.
- GitHub is unreachable, `gh` isn't authenticated, or Actions minutes are exhausted.
- You're about to do something from the "must NOT do" list, or you find personal data already pushed — in this last case, also create the shared `docs/LOOP_STOP` (not just the Windows one) and say so in the PR/issue comment, since it affects the whole public repo, not just this loop.

End each iteration with 3–5 lines: task done, tests run and result, the PR link, next task, and any owner action needed.
