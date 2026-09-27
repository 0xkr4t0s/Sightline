#!/usr/bin/env python3
"""Check that the paths AGENTS.md and README.md point at exist.

Agents follow these files literally, so a renamed script or doc silently breaks them. Checked:

- every inline code span (and every word inside a multi-word span) that looks like a
  repo-relative path, e.g. `tools/mission/setup.sh`, `docs/SRS.md`, `testdata/`;
- every relative markdown link target, e.g. [SRS](docs/SRS.md);
- shell scripts referenced as paths are executable in git (mode 100755).

A path counts as present when git tracks it (including staged files) or when git ignores it
(documented local or generated paths such as `.mission/` or `.venv.nosync/`). Skipped:
fenced code blocks, absolute and home paths, URLs, placeholders containing `<`, globs, and
Cargo target directories.

Usage (from the repository root):
    python3 tools/check_agents_md.py                       # AGENTS.md and README.md
    python3 tools/check_agents_md.py --files AGENTS.md     # only these markdown files
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

DEFAULT_FILES = ["AGENTS.md", "README.md"]

# File name endings that make a slash-free word look like a path (e.g. `LOOP_LOG.md`).
PATH_SUFFIXES = (
    ".md", ".py", ".sh", ".rs", ".toml", ".json", ".yml", ".yaml", ".swift", ".bin",
    ".xcconfig", ".lock", ".txt",
)  # fmt: skip
PATH_TOKEN = re.compile(r"^[A-Za-z0-9._/-]+$")
INLINE_CODE = re.compile(r"(`+)(.+?)\1")
MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"^\s*(```|~~~)")

# Output directories that build commands create and whose contents git ignores.
GENERATED_DIRS = {"BlenderAddOn/wheels"}

# Scripts that are sourced, not run, so they don't need the executable bit.
SOURCED_SCRIPTS = {"tools/mission/env.sh"}

# References known to be stale, as (markdown file, path) with the reason. Every entry is
# printed on each run so it stays visible; fix the markdown file and delete the entry.
KNOWN_STALE: dict[tuple[str, str], str] = {}


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True).stdout


def repo_root() -> Path:
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True)
    return Path(out.stdout.strip())


class Tree:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.modes: dict[str, str] = {}
        for line in git(root, "ls-files", "-s").splitlines():
            meta, path = line.split("\t", 1)
            self.modes[path] = meta.split()[0]
        self.dirs = {str(p) for f in self.modes for p in PurePosixPath(f).parents}
        self.top_level = {PurePosixPath(f).parts[0] for f in self.modes}

    def tracked(self, rel: str) -> bool:
        rel = rel.rstrip("/")
        return rel in self.modes or rel in self.dirs

    def ignored(self, rel: str) -> bool:
        result = subprocess.run(["git", "check-ignore", "-q", "--no-index", rel], cwd=self.root, capture_output=True)
        return result.returncode == 0

    def exists_on_disk(self, rel: str) -> bool:
        return (self.root / rel).exists()


def looks_like_path(token: str, top_level: set[str]) -> bool:
    if not PATH_TOKEN.match(token) or token in {".", "..", "/"}:
        return False
    if token.startswith(("/", "~", "-")) or "*" in token:
        return False
    if "/" in token:
        # Words like `gh pr create/edit/comment` also contain slashes. A path ends in "/",
        # starts at a top-level entry or a dot directory, or ends in a name with an extension.
        if token.endswith("/"):
            return True
        first = token.split("/", 1)[0]
        last = token.rsplit("/", 1)[-1]
        return first in top_level or first.startswith(".") or "." in last
    return token.endswith(PATH_SUFFIXES) and not token.startswith(".")


def skip_path(rel: str) -> bool:
    parts = PurePosixPath(rel).parts
    return any(part.startswith("target") for part in parts) or rel.startswith("../")


def normalise(md_file: str, target: str) -> str:
    base = PurePosixPath(md_file).parent
    joined = PurePosixPath(base, target)
    parts: list[str] = []
    for part in joined.parts:
        if part == "..":
            if parts:
                parts.pop()
            else:
                return "../" + target
        elif part != ".":
            parts.append(part)
    rel = "/".join(parts)
    return rel + "/" if target.endswith("/") and rel else rel


def references(md_file: str, text: str, top_level: set[str]) -> list[tuple[int, str, str]]:
    """(line, kind, repo-relative path) for every path-like reference outside code fences."""
    found: list[tuple[int, str, str]] = []
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), start=1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in MD_LINK.finditer(line):
            target = match.group(1).split("#", 1)[0]
            if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target) or "<" in target:
                continue
            found.append((lineno, "link", normalise(md_file, target)))
        for match in INLINE_CODE.finditer(line):
            span = match.group(2).strip()
            if "<" in span:
                continue
            for token in span.split():
                token = token.rstrip(".,;:)")
                if looks_like_path(token, top_level):
                    found.append((lineno, "code", token))
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--files", nargs="*", help="markdown files to check (repo-relative)")
    args = parser.parse_args(argv)

    root = repo_root()
    tree = Tree(root)
    md_files = args.files if args.files else DEFAULT_FILES

    errors: list[str] = []
    warnings: list[str] = []
    checked = 0
    for md_file in md_files:
        md_file = PurePosixPath(md_file).as_posix()
        path = root / md_file
        if not path.is_file():
            errors.append(f"{md_file}: file not found")
            continue
        text = path.read_text(encoding="utf-8")
        for lineno, kind, rel in references(md_file, text, tree.top_level):
            if skip_path(rel):
                continue
            checked += 1
            where = f"{md_file}:{lineno}: `{rel}` ({kind})"
            stale = KNOWN_STALE.get((md_file, rel))
            if stale is not None:
                warnings.append(f"{where}: known stale reference, {stale}")
                continue
            if tree.tracked(rel):
                bare = rel.rstrip("/")
                if (
                    bare.endswith(".sh")
                    and bare not in SOURCED_SCRIPTS
                    and tree.modes.get(bare) not in (None, "100755")
                ):
                    errors.append(f"{where}: script is not executable in git (chmod +x, then git add)")
                continue
            if rel.rstrip("/") in GENERATED_DIRS or tree.ignored(rel):
                continue
            if tree.exists_on_disk(rel):
                warnings.append(f"{where}: exists but is not tracked by git yet")
                continue
            errors.append(f"{where}: no such file or directory in the repository")

    for message in warnings:
        print(f"  warning: {message}")
    if errors:
        for message in errors:
            print(f"  ERROR: {message}", file=sys.stderr)
        print(f"check_agents_md: FAIL, {len(errors)} broken reference(s)", file=sys.stderr)
        return 1
    print(f"check_agents_md: OK ({checked} reference(s) in {', '.join(md_files)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
