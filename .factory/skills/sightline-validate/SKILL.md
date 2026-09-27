---
name: sightline-validate
description: Pick and run the right checks for a Sightline change, then report the evidence. Maps changed paths (native/, BlenderAddOn/, SightlineIOS/, testdata/, docs/protocol/, tools/) to test suites, lint, coverage and user-facing QA flows, and runs the privacy check before committing. Use before finishing or committing any Sightline change, or when a mission validator needs to confirm a feature.
---

# Validate a Sightline change

## 1. See what changed

`git status --short` and `git diff --stat` (plus `git diff --cached --stat` if anything is
staged). Then run every row below that matches a changed path.

| Changed | Run |
|---|---|
| `native/**` | `tools/mission/check.sh rust` (fmt, clippy with complexity ceilings, tests). If `vcam-py`, `vcam-net`, `vcam-video` or the fake iPhone changed, also `tools/mission/setup.sh` and then `tools/mission/check.sh blender`. |
| `BlenderAddOn/**` | `tools/mission/setup.sh`, then `tools/mission/check.sh python blender`. For user-visible behaviour, also run the **sightline-qa-blender** skill. |
| `SightlineIOS/**` | `tools/mission/check.sh ios`. For anything on screen, also run the **sightline-qa-ios** skill. |
| `testdata/**`, `tools/gen_testdata.py`, `docs/protocol/**` | `tools/mission/check.sh python` (includes `gen_testdata.py --check`), plus `rust` and `ios`: the golden vectors are shared by all three. |
| `tests/blender/**` | `BLENDER_TESTS="<changed scripts>" tools/mission/check.sh blender` |
| `.github/workflows/**` | Parse the YAML (`ruby -ryaml -e 'YAML.load_file(ARGV[0])' <file>`). CI itself only runs on the owner's PRs, so note that it wasn't run. |
| `AGENTS.md`, `README.md` | `python3 tools/check_agents_md.py` |

- `check.sh` prints one PASS/FAIL line per suite. The details are in `.mission/logs/<suite>.log`
  (read the end of the log first).
- `BLENDER_TESTS="a b"` limits the Blender scripts.
- The suites mirror CI, plus two GPU-only render checks that CI can't run.

## 2. Quality gates that CI enforces

- Rust:
  - `cargo fmt --check`.
  - `cargo clippy --all-targets -- -D warnings`: no `unwrap`/`expect` outside tests, and
    cognitive complexity and function-length ceilings in `native/clippy.toml`.
  - `cargo machete`.
  - `cargo llvm-cov --fail-under-lines 80`.
- Python: the ruff lint and format, mypy strict and pytest coverage settings in the root
  `pyproject.toml`.
- Swift: `xcrun swift-format lint --strict --configuration .swift-format -r SightlineIOS`,
  plus the iOS coverage gate.
- `python3 tools/check_todos.py`: a TODO needs an issue or plan task, e.g. `TODO(#12)` or `TODO(2.3f)`.
- `python3 tools/check_large_files.py`.

Don't raise a threshold or silence a lint to get green. Fix the code, or stop and report it.

## 3. User-facing QA (missions)

Unit tests passing isn't enough for a feature a user sees. Drive it:

- **Blender side:** the sightline-qa-blender skill (headless host, fake iPhone, `state.json`, streamed frame).
- **iPhone side:** the sightline-qa-ios skill (simulator app in QA mode against the same host, UI
  tests and screenshots).

Anything that needs a real iPhone, ARKit, Wi-Fi or signing is owner-only. List it under
"Not verified" and don't try to fake it.

## 4. Before committing

- The Git hooks (`tools/hooks/`, installed by `setup.sh`) run the size, privacy, format and TODO
  checks on staged files. Never bypass them.
- Read `git diff --cached` for the AGENTS.md Privacy items. `git config user.email` must be the
  noreply address.
- Cite requirement IDs (e.g. FR-VF-004) and the plan task in the commit message. If a
  requirement's status changed, update `IMPLEMENTATION_PROGRESS.md`.

## 5. Report

List each command with its PASS/FAIL result and the key numbers (test counts, coverage). Then
list the QA evidence: the state fields checked and the screenshots or frames you viewed. End
with what wasn't verified and why.
