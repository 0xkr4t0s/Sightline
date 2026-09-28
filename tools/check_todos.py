#!/usr/bin/env python3
"""Report tech-debt markers and fail on ones not linked to an issue or plan task.

A marker is TODO, FIXME, XXX or HACK in a tracked source file (*.rs, *.py, *.swift, *.sh;
legacy/ and testdata/ are skipped). It is linked when it names where the work is tracked:

    TODO(#123): ...      a GitHub issue or PR
    FIXME(2.3f): ...     a task ID from docs/IMPLEMENTATION_PLAN.md

Usage (from the repository root):
    python3 tools/check_todos.py                # every tracked source file
    python3 tools/check_todos.py --files a b    # only these (the pre-commit hook)
    python3 tools/check_todos.py --quiet        # print only the unlinked markers
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SOURCE_SUFFIXES = {".rs", ".py", ".swift", ".sh"}
EXCLUDED_PREFIXES = ("legacy/", "testdata/")
# This file names the markers in its own documentation.
EXCLUDED_FILES = {"tools/check_todos.py"}

MARKER = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b(?:\(([^)]*)\))?")
# `#123` (issue/PR) or a plan task ID such as 2.3f, 1.1.3c or 2.2d2b. A letter must start the
# suffix, so each digit belongs to one group only (no exponential backtracking; CodeQL alert 1).
LINK = re.compile(r"^(#\d+|\d+(?:\.\d+(?:[a-z][a-z0-9]*)?)+)$")

# Unlinked markers that predate this check, as (path, line text stripped). Remove an entry when
# its marker is linked or resolved; never add new ones.
BASELINE: set[tuple[str, str]] = set()


def repo_root() -> Path:
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True)
    return Path(out.stdout.strip())


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True)
    return [p for p in out.stdout.decode("utf-8", "surrogateescape").split("\0") if p]


def in_scope(rel: str) -> bool:
    return Path(rel).suffix in SOURCE_SUFFIXES and not rel.startswith(EXCLUDED_PREFIXES) and rel not in EXCLUDED_FILES


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--files", nargs="*", help="check only these paths (repo-relative)")
    parser.add_argument("--quiet", action="store_true", help="don't list linked markers")
    args = parser.parse_args(argv)

    root = repo_root()
    candidates = args.files if args.files is not None else tracked_files(root)
    files = sorted({Path(p).as_posix() for p in candidates if in_scope(Path(p).as_posix())})

    linked: list[str] = []
    baselined: list[str] = []
    unlinked: list[str] = []
    for rel in files:
        path = root / rel
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), start=1):
            for match in MARKER.finditer(line):
                where = f"{rel}:{lineno}: {line.strip()}"
                link = match.group(2)
                if link is not None and LINK.match(link.strip()):
                    linked.append(where)
                elif (rel, line.strip()) in BASELINE:
                    baselined.append(where)
                else:
                    unlinked.append(where)

    total = len(linked) + len(baselined) + len(unlinked)
    print(
        f"check_todos: {len(files)} source file(s), {total} marker(s): "
        f"{len(linked)} linked, {len(baselined)} baselined, {len(unlinked)} unlinked"
    )
    if not args.quiet:
        for where in linked:
            print(f"  linked     {where}")
        for where in baselined:
            print(f"  baselined  {where}")
    if unlinked:
        for where in unlinked:
            print(f"  UNLINKED   {where}", file=sys.stderr)
        print(
            "check_todos: FAIL. Link each marker to where the work is tracked, e.g. "
            "TODO(#123) or TODO(2.3f), or resolve it.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
