# Project Memory

## What this product is

An iPhone/iPad **virtual camera for Blender**. The iPhone's ARKit pose drives a Blender camera. Blender renders that camera's view and **streams the video back to the iPhone**, which acts as the viewfinder and control surface (lens, focus, record). Video flows Blender → iPhone only. There is **no** system virtual webcam (no CMIO extension, no Zoom/OBS output), and the iPhone camera image is only a tracking sensor.

The product is called **Sightline** (renamed from "VCam for Blender" on 2026-09-25) and is fully open source. Use "Sightline" in anything users see: UI text, the manifest, App Store strings and docs. Keep the internal identifiers: the repo name, the extension `id` `vcam_blender`, `vcam_native`, the `vcam-*` crates, `VCam_Origin`, `_vcam-ctl._tcp` and VCP. The iOS app's folder, Xcode project and bundle ID (`kr8t0s.Sightline`) were renamed on 2026-09-25, before any TestFlight or App Store release. Changing those would break installs, pairings or saved files.

## Startup Checklist

- Read `IMPLEMENTATION_PROGRESS.md` (status by requirement ID), then the relevant part of `docs/SRS.md` (v3.0) and `docs/IMPLEMENTATION_PLAN.md` (v3.0).
- The superseded v1 PDF SRS was removed from the tree on 2026-09-25 (it's still in git history). Don't implement from it.
- Cite requirement IDs in commits. After changing a requirement's status, update `IMPLEMENTATION_PROGRESS.md`.

## Architecture (v3)

- `SightlineIOS/`: Swift 6, iOS 26+. ARKit tracking, viewfinder display, controls.
- `BlenderAddOn/`: Blender 5.2 LTS extension (Python 3.13) that bundles a **Rust** native module (`native/`, PyO3/maturin, per-platform wheels) for networking, protocol, clock sync, and video encoding. Runs on Windows, Linux, and macOS.
- Protocol: the project's own versioned protocol "VCP" (`docs/protocol/vcp.md`), not FreeD. FreeD/OpenTrackIO are optional T4 exports only.
- `DesktopReceiver/` (C++, CMIO) is being retired. Don't extend it.

## Rules

- Never touch `bpy`/`gpu` off Blender's main thread. Rust does I/O and encoding on its own threads and releases the GIL.
- The Blender extension is GPL. The iOS app must not contain GPL code; share only test vectors (or MIT/Apache crates).
- Golden vectors in `testdata/` are the source of truth across Rust, Swift, and Python.
- Local tools: Blender 5.2.2 at `/Applications/Blender.app`; Rust 1.97.1. Paths contain spaces, so quote them.

## Privacy (public repository)

The repository is public and its history was scrubbed on 2026-09-25. Never put the owner's personal data into anything that gets published: commits (messages, author, files), branch names, PR titles/bodies, PR or issue comments, `docs/LOOP_LOG.md`, `reports/`, or test output pasted anywhere. Personal data means:

- the owner's real name, or any email address other than `10257520+0xkr4t0s@users.noreply.github.com` (the GitHub handle `0xKr4t0s` is fine);
- local paths containing the macOS user name (`/Users/<name>/…`) and the Mac's host name (including `<name>s-MacBook-Pro.local` in Bonjour/`dns-sd` output). Write repo-relative paths, and `<host>` or `~` for anything local. CI runner paths (`/Users/runner`, `/home/runner`, `D:\a\…`) are fine;
- the Apple Team ID, signing identities, provisioning profiles, device names/UDIDs, IP or MAC addresses on the owner's network, and any credentials or tokens.

Rules:

- The Team ID lives only in the git-ignored `SightlineIOS/Signing.local.xcconfig`. Never write `DEVELOPMENT_TEAM` into `project.pbxproj` (Xcode adds it when a team is picked in the UI; remove it before committing). Don't commit `xcuserdata/`.
- Don't add `Created by <name>` headers to new Swift files.
- Before every commit, check that `git config user.email` is the noreply address above and read the staged diff (`git diff --cached`) for the items listed. Before `gh pr create/edit/comment` or `gh issue create`, check the text the same way.
- Redact rather than drop evidence: replace the value with `<host>`, `<path>` or `<team>` and keep the rest of the output line.
- If private data has already been pushed, stop and tell the owner. Don't rewrite history yourself.
