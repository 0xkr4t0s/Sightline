# Git hooks

Fast local checks that run before a commit is recorded. They catch the problems that are
expensive to fix after a push to this public repository: personal data in the history, large
files, and formatting that CI would reject anyway.

## Install

From the repository root (`tools/mission/setup.sh` does this for you):

```bash
git config core.hooksPath tools/hooks
```

The setting is per clone and per worktree checkout of the same repository. To remove it:
`git config --unset core.hooksPath`.

## What runs

`pre-commit` checks only the staged files, usually in a few seconds:

| Check | Tool | Runs when |
| --- | --- | --- |
| Files over 1 MiB (staged size) | `tools/check_large_files.py --staged` | always |
| Commit email is the project's noreply address | `git config user.email` | always |
| Personal data in added lines: home path, `/Users/<name>`, host names, Team ID, other email addresses, `DEVELOPMENT_TEAM` in `project.pbxproj`, `xcuserdata/` | `tools/hooks/privacy_scan.py --staged` | always |
| Rust formatting | `cargo fmt --check` (whole workspace) | a `native/**/*.rs` file is staged |
| Python lint and format | `ruff check`, `ruff format --check` from `.venv.nosync/bin` or `PATH` | a `.py` file is staged and ruff is installed |
| Swift lint | `xcrun swift-format lint --strict` | a `.swift` file is staged, `.swift-format` exists and swift-format is available |
| Unlinked `TODO`/`FIXME`/`XXX`/`HACK` | `tools/check_todos.py` | always |
| Paths in `AGENTS.md` and `README.md` exist | `tools/check_agents_md.py` | either file is staged |

`commit-msg` runs the same privacy scan on the message and prints a warning (without
failing) when the message cites no requirement ID such as `FR-VF-004` or plan task such as
`2.3f`. Merge, revert, fixup and squash messages are exempt from the warning.

Clippy, the test suites and the Blender and iOS checks are too slow for a hook; run
`tools/mission/check.sh` before opening a PR. CI runs everything on the PR.

The hook prints this machine's values only as placeholders (`~`, `<user>`, `<host>`,
`<team>`), so its output is safe to paste. Checks for tools that aren't installed are skipped
with a notice rather than failing.

## When a check fails

Fix the problem, `git add` again and commit. Don't bypass the hooks with `--no-verify`. If a
check is wrong, fix the check in the same PR and say why in the description.

The standalone checks also run on the whole tree:

```bash
python3 tools/check_large_files.py
python3 tools/check_todos.py
python3 tools/check_agents_md.py
```
