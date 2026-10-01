## Summary

<!-- What changes for the user or the code, and why. One short paragraph. -->

## Requirements and plan task

<!-- Requirement IDs from docs/SRS.md (v3), e.g. FR-VF-004, NET-004, NFR-QA-002,
     and the task ID from docs/IMPLEMENTATION_PLAN.md, e.g. 2.3f. Write "none" for pure maintenance. -->

- Requirement IDs:
- Plan task:

## Changes

<!-- The main files or modules touched and what changed in each. -->

-

## Tests run

<!-- Paste the commands you ran and the result lines you saw. -->

- [ ] Rust (`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` in `native/`)
- [ ] Python (`python -m pytest -q BlenderAddOn/tests`, `python tools/gen_testdata.py --check`)
- [ ] Blender headless scripts with the fake iPhone (`tools/mission/check.sh blender`)
- [ ] iOS unit tests (iPhone 17 simulator, `tools/mission/check.sh ios`)
- [ ] QA harness for user-facing changes (`tools/mission/qa_blender.sh`, `tools/mission/qa_ios.sh`)

```text
<commands and results>
```

## Not verified / owner-only

<!-- Anything that needs a real iPhone, ARKit, Wi-Fi, a GPU, Windows/Linux hardware or
     Apple signing, and was therefore not checked. Write "nothing" if everything was verified. -->

-

## Checklist

- [ ] `IMPLEMENTATION_PROGRESS.md` updated if a requirement's status changed
- [ ] Commit messages cite the requirement IDs

### Privacy (public repository, see AGENTS.md)

- [ ] No personal data in commits, files or this description: no real name, no local `/Users/<name>` paths, no host name, IP/MAC addresses, device names/UDIDs, team IDs or tokens
- [ ] Commit author email is the `users.noreply.github.com` address
- [ ] No `DEVELOPMENT_TEAM` in `project.pbxproj` and no `xcuserdata/`
- [ ] Logs and test output pasted here are redacted (`<host>`, `<path>`, `<team>`)
