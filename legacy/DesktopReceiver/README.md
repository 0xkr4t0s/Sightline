# DesktopReceiver (legacy, being retired)

This C++ desktop receiver and its macOS CMIO camera extension belong to the v1 design, where the iPhone fed a system virtual webcam. The v3 product doesn't include that (`docs/SRS.md` ARC-006, §2 out-of-scope). The Blender extension's Rust module (`native/`) replaces it.

- **Don't extend this code.** It's kept here only until the parts worth keeping are ported to Rust (ARC-006): the parsers and their tests, and the test-pattern generator. Once they're ported, this directory is deleted.
- The FreeD layout used here (`src/protocol/FreeDParser.cpp`) is non-standard (SRS §6.3, PR-FD-001). Don't use it as a reference.

## Building the old tests (reference only)

```sh
B=$(mktemp -d)
cmake -S legacy/DesktopReceiver -B "$B"
cmake --build "$B" -j 8
ctest --test-dir "$B"
```

The build directory lives outside the repo. The `build/` directory that used to be here was stale (configured from `~/Downloads`) and was deleted in task 0.1.2.
