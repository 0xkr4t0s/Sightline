# Runbook

How to diagnose and recover from the failures that recur in this repository. It's for
maintainers and coding agents. Sightline has no deployed service: "production" is `main`, and
a bad change is recovered by reverting it.

Before pasting any log below into an issue, PR or `docs/LOOP_LOG.md`, redact personal data
(`<host>`, `<path>`, `<team>`), as AGENTS.md requires.

## CI (`.github/workflows/ci.yml`)

CI runs on pull requests once they are ready for review, and on `workflow_dispatch`. There is
no push run on `main`. Read a failed run with `gh pr checks <n>`, then
`gh run view <run-id> --log-failed`.

| Job | What usually breaks | What to do |
| --- | --- | --- |
| `rust-fmt` | Unformatted Rust, or `cargo machete` found a dependency no crate uses. | `cd native && cargo fmt`, commit. The pre-commit hook catches formatting locally. For machete, remove the dependency (or, if it's used only through a macro, add it to `[package.metadata.cargo-machete] ignored` with a comment). |
| `rust-coverage` | Line coverage of the Rust tests fell below 80 %. | `tools/mission/check.sh coverage` prints per-file coverage. Add tests for the new code; don't lower the gate. The `rust-coverage` artifact has `lcov.info`. |
| `rust` (ubuntu, windows, macos) | Clippy with `-D warnings`: a new stable Rust adds lints (Rust 1.98 added `chunks_exact_to_as_chunks`). NASM missing for `turbojpeg-sys`. Windows-only test failures. | Reproduce with `cargo clippy --all-targets -- -D warnings` after `rustup update stable`. For Windows, see "Recurring Windows failures" below. |
| `fuzz` | A crash or timeout in one of `udp_open`, `control_decode`, `pairing_inputs`, `video_reassembly`. | Download the `fuzz-artifacts` artifact and replay the input: `cd native && cargo +nightly fuzz run <target> <artifact-file>`. Fix the parser, then add the input as a regression test or golden vector. |
| `wheels` | NASM missing (Windows uses Chocolatey, manylinux uses `dnf` in `before-script-linux`), or a maturin version change. | Check the "Install NASM" step output and the `nasm -v` line in the maturin log. `MATURIN_VERSION` is pinned in `ci.yml`. |
| `extension` | `tools/set_manifest_wheels.py` can't match a wheel, or `blender --command extension build` rejects the manifest. | Run both commands locally against the downloaded `wheel-*` artifacts. |
| `blender-smoke` (per OS) | A `tests/blender/*.py` script exits non-zero. Each script prints a `VCAM_*_OK` line on success. | Find the last `::group::` before the failure and reproduce locally with `BLENDER_TESTS="<script>" tools/mission/check.sh blender`. Only the platform zip for that OS is installed (`vcam_blender-*-<platform>.zip`). |
| `python` | ruff lint or format, mypy (strict, on the files listed in `pyproject.toml`), `BlenderAddOn/tests` failures (random order: the run prints `Using --randomly-seed=N`), coverage under `fail_under`, or golden vectors that are out of date. | `tools/mission/check.sh python` runs the same steps; `.venv.nosync/bin/ruff format .` fixes formatting. Rerun an order-dependent failure with `.venv.nosync/bin/pytest --randomly-seed=N`. For vectors: `python tools/gen_testdata.py --check`. If it reports drift, regenerate with the same script and review the vector diff: `testdata/` is the source of truth for Rust, Swift and Python. |
| `ios` | swift-format lint (fix with `xcrun swift-format -i --configuration .swift-format -r SightlineIOS`), app line coverage under 75 % (`SightlineIOS/scripts/coverage_check.sh <xcresult>` lists files), a UI test in `SightlineIOSUITests` (the Blender-host test skips in CI; reproduce with `tools/mission/qa_ios.sh uitest`), or unit test failures on the `xcode-27` runner. Timing tests are sensitive: on the CI simulator, Network sometimes reports a refused connection only after the 2 s attempt timeout (the NET-004 reconnect test). | Download the `ios-xcresult` artifact and open it in Xcode (`open xcresult/debug.xcresult`). Crash logs of a test process that died exist only there. Collecting simulator diagnostics can take about 10 minutes after a failure. |
| `ci-ok` | Fails whenever any job didn't succeed, including skipped jobs. | A failed `ci-ok` on a **draft** run is expected: every job is skipped. Mark the PR ready (`gh pr ready`) and look at the new run. Draft and ready runs are in separate concurrency groups, so the draft run doesn't cancel the real one. |

`codeql.yml` runs CodeQL for Actions, Python and Rust on ready PRs and weekly. It isn't part
of `ci-ok`; findings appear under Security → Code scanning.

### Recurring Windows failures

- **Connection reset (os error 10054) instead of EOF.** Windows answers a close with unread
  input by sending RST instead of FIN. The control server therefore lingers after writing
  `ERROR` (`vcam-net/src/control.rs`, `linger_close`). A new "connection reset" in a test
  usually means a path closes a socket before reading everything the peer sent.
- **Lost UDP datagrams under load.** A blocking `recv` with `SO_RCVTIMEO` dropped datagrams on
  a busy Windows host. The UDP receiver uses `mio` readiness and drains until `WouldBlock`
  (`vcam-net/src/udp.rs`). Don't go back to read timeouts for the hot path.
- **Races that only show on slow runners.** Counters published after the data they describe
  (the JPEG worker's `encoded` count) make a waiting consumer read stale stats. Update stats
  before publishing the result.

Reproduce concurrency-sensitive failures by running several copies of the test binary at once;
a single run rarely fails.

## Local checks (`tools/mission/`)

- `tools/mission/setup.sh` prepares the checkout; `tools/mission/check.sh [rust|python|blender|ios|coverage]`
  prints one PASS/FAIL line per suite and writes the full output to `.mission/logs/<suite>.log`.
  Read the end of that log first.
- **Blender suite says "No installed extension" or "No fake iPhone":** run `setup.sh` again. It
  is also needed after any change in `native/` or `BlenderAddOn/`, because the tests use the
  installed copy in `.mission/blender-user`, not the source tree.
- **`vcam_native` fails to import in Blender on macOS with "mis-aligned LINKEDIT string pool":**
  the local linker produced a release `.so` that dyld rejects. `setup.sh` builds a debug wheel
  for this reason. Use the debug wheel locally; CI builds the release wheels. Encode timings from
  a debug wheel aren't representative.
- **`xcodebuild: error: tool 'xcodebuild' requires Xcode`:** the active developer directory is
  Command Line Tools. `tools/mission/env.sh` sets `DEVELOPER_DIR` to Xcode 27; outside the
  scripts, export `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer`.
- **`Unable to find a device matching the provided destination specifier`:** the simulator
  named in the destination isn't installed. The project uses `iPhone 17`
  (`IOS_DESTINATION` in `env.sh`).
- **Git hooks fail:** see `tools/hooks/README.md`. Fix the reported problem rather than
  bypassing the hook.

## Reproducing user-facing problems (QA harness)

`tools/mission/qa_blender.sh` drives headless Blender with the fake iPhone, and
`tools/mission/qa_ios.sh` drives the iOS app in the simulator. Use them to reproduce a
reported problem before fixing it and to confirm the fix afterwards. Their logs go to
`.mission/logs/`. Anything that needs a real iPhone, ARKit, Wi-Fi or Apple signing can't be
reproduced this way: record it as "not verified" for the owner.

## Dependency updates (Dependabot)

`.github/dependabot.yml` proposes weekly updates for Cargo (`native/`, `native/fuzz/`),
GitHub Actions and the dev container image. New releases wait 7 days (majors 14) before they
are proposed; security updates are not delayed. Minor and patch updates are grouped into one
PR per ecosystem.

To verify an update PR:

1. Read the changelog of each updated crate or action, especially for anything in the
   pairing, crypto or networking path (`crypto-bigint`, `hkdf`, `hmac`, `sha2`, `getrandom`,
   `mio`, `mdns-sd`, `turbojpeg`, `pyo3`).
2. Let CI run in full (mark the PR ready). Every job must pass; `fuzz` and `blender-smoke`
   cover the parsers and the packaged extension.
3. For licence changes, check that the iOS side stays free of GPL code and that the
   extension's notices are still complete.
4. Merge with squash like any other PR. A major update of a GitHub Action may change inputs;
   compare with the action's release notes before merging.

## Security incidents

- **Vulnerability reports** go through GitHub private vulnerability reporting, as described in
  `.github/SECURITY.md`. Don't discuss details in public issues or PRs until a fix is on `main`.
- **Personal data pushed to GitHub** (a local path with the user name, a host name, the Team
  ID, an email address, a device name): stop and tell the owner. Don't rewrite history or
  force-push yourself; the owner decides how to scrub it.
- **Secret committed** (a token or key): tell the owner at once so it can be revoked. Removing
  it from the tree doesn't make it safe again.

## Rolling back a change

Every change reaches `main` as a squash-merged PR, so a rollback is one revert commit:

```bash
gh pr revert <pr-number>            # opens a PR that reverts the merged PR
# or, on a branch from main:
git revert <squash-commit-sha>
```

The revert goes through CI and `ci-ok` like any other PR. There are no releases or deployed
services to roll back. If the reverted change updated `IMPLEMENTATION_PROGRESS.md`, check that
the reverted status is still correct.
