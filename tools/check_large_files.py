#!/usr/bin/env python3
"""Fail if a tracked file (or one of the given files) is larger than the limit.

Usage (from the repository root):
    python3 tools/check_large_files.py                 # every tracked file
    python3 tools/check_large_files.py --files a b     # only these files
    python3 tools/check_large_files.py --staged --files a b   # their staged versions (pre-commit)
    python3 tools/check_large_files.py --limit-kib 512

Large binaries bloat the public history for good; build outputs belong in CI artifacts.
Add a path to ALLOWLIST only for a file that has to be versioned, with the reason.
"""

from __future__ import annotations

import argparse
import fnmatch
import subprocess
import sys
from pathlib import Path

DEFAULT_LIMIT_KIB = 1024

# Glob patterns (repo-relative, POSIX separators) exempt from the size limit.
ALLOWLIST: dict[str, str] = {
    "docs/media/viewfinder.gif": "README media GIF; IMPLEMENTATION_PLAN.md 'README media' caps it at 3 MB",
}


def repo_root() -> Path:
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True)
    return Path(out.stdout.strip())


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True)
    return [p for p in out.stdout.decode("utf-8", "surrogateescape").split("\0") if p]


def allow_reason(path: str) -> str | None:
    for pattern, reason in ALLOWLIST.items():
        if fnmatch.fnmatchcase(path, pattern):
            return reason
    return None


def human(size: int) -> str:
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.2f} MiB"
    return f"{size / 1024:.1f} KiB"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--files", nargs="*", help="check only these paths (repo-relative)")
    parser.add_argument("--staged", action="store_true", help="measure the staged (index) version of --files")
    parser.add_argument("--limit-kib", type=int, default=DEFAULT_LIMIT_KIB)
    parser.add_argument("--top", type=int, default=5, help="list the N largest files checked")
    args = parser.parse_args(argv)

    root = repo_root()
    limit = args.limit_kib * 1024
    paths = args.files if args.files is not None else tracked_files(root)

    sizes: list[tuple[int, str]] = []
    if args.staged:
        for rel in paths:
            out = subprocess.run(["git", "cat-file", "-s", f":{rel}"], cwd=root, capture_output=True, text=True)
            if out.returncode == 0:
                sizes.append((int(out.stdout.strip()), Path(rel).as_posix()))
        paths = []
    for rel in paths:
        path = (root / rel) if not Path(rel).is_absolute() else Path(rel)
        if not path.is_file():
            continue  # deleted in the working tree or a submodule
        try:
            rel_posix = path.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            rel_posix = Path(rel).as_posix()
        sizes.append((path.stat().st_size, rel_posix))

    too_big = [(s, p) for s, p in sizes if s > limit and allow_reason(p) is None]
    allowed_big = [(s, p) for s, p in sizes if s > limit and allow_reason(p) is not None]

    if args.files is None:
        print(f"check_large_files: {len(sizes)} tracked files, limit {human(limit)}")
        for size, rel in sorted(sizes, reverse=True)[: args.top]:
            print(f"  {human(size):>10}  {rel}")
    for size, rel in allowed_big:
        print(f"  allowed: {human(size):>10}  {rel} ({allow_reason(rel)})")

    if too_big:
        print(f"check_large_files: FAIL, {len(too_big)} file(s) over {human(limit)}:", file=sys.stderr)
        for size, rel in sorted(too_big, reverse=True):
            print(f"  {human(size):>10}  {rel}", file=sys.stderr)
        print(
            "Keep build outputs out of git (CI artifacts), or add the path to ALLOWLIST in "
            "tools/check_large_files.py with the reason.",
            file=sys.stderr,
        )
        return 1
    print(f"check_large_files: OK ({len(sizes)} file(s) within {human(limit)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
