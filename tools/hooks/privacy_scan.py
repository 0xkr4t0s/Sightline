#!/usr/bin/env python3
"""Block personal data from entering the public history (AGENTS.md, "Privacy").

    python3 tools/hooks/privacy_scan.py --staged          # lines added by the staged diff
    python3 tools/hooks/privacy_scan.py --message FILE    # a commit message

Looks for this machine's home path, user name in /Users/ or /home/ paths, host names, the
Apple Team ID from the git-ignored SightlineIOS/Signing.local.xcconfig, a non-empty
DEVELOPMENT_TEAM in project.pbxproj, staged xcuserdata/ paths, and email addresses other than
GitHub noreply addresses. The values are read at run time and printed only as placeholders,
so the hook's own output is safe to paste.
"""

from __future__ import annotations

import argparse
import getpass
import os
import re
import socket
import subprocess
import sys
from pathlib import Path

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ALLOWED_EMAIL = re.compile(
    r"(?i)^([A-Za-z0-9._%+-]+@users\.noreply\.github\.com"
    r"|noreply@anthropic\.com"
    r"|git@github\.com"
    r"|[A-Za-z0-9._%+-]+@example\.(com|org|net))$"
)
TEAM_IN_PBXPROJ = re.compile(r"DEVELOPMENT_TEAM\s*=\s*\"?[A-Za-z0-9]")
# User names that are generic CI or system accounts, not personal data.
GENERIC_USERS = {"runner", "root", "user", "admin", "vscode", "ubuntu"}


def run(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        return ""


def repo_root() -> Path:
    return Path(run("git", "rev-parse", "--show-toplevel") or ".")


def secrets(root: Path) -> list[tuple[str, str]]:
    """(value, placeholder) pairs, longest first so the home path wins over the user name."""
    found: dict[str, str] = {}
    home = os.path.expanduser("~")
    if len(home) > 4 and home not in {"/root", "/home"}:
        found[home] = "~"
    user = getpass.getuser()
    if len(user) >= 3 and user.lower() not in GENERIC_USERS:
        for prefix in ("/Users/", "/home/", "C:\\Users\\", "C:/Users/"):
            found[prefix + user] = prefix + "<user>"
    hosts = {socket.gethostname(), socket.gethostname().split(".")[0]}
    if sys.platform == "darwin":
        hosts |= {run("scutil", "--get", "LocalHostName"), run("scutil", "--get", "ComputerName")}
    for host in hosts:
        if len(host) >= 4 and host.lower() not in {"localhost", "local"}:
            found[host] = "<host>"
    local_signing = root / "SightlineIOS" / "Signing.local.xcconfig"
    if local_signing.is_file():
        match = re.search(r"DEVELOPMENT_TEAM\s*=\s*([A-Za-z0-9]+)", local_signing.read_text(errors="replace"))
        if match and len(match.group(1)) >= 4:
            found[match.group(1)] = "<team>"
    return sorted(found.items(), key=lambda kv: len(kv[0]), reverse=True)


def redact(text: str, values: list[tuple[str, str]]) -> str:
    for value, placeholder in values:

        def literal(_m: re.Match[str], p: str = placeholder) -> str:
            return p

        text = re.sub(re.escape(value), literal, text, flags=re.IGNORECASE)
    return text


def scan_line(line: str, values: list[tuple[str, str]]) -> list[str]:
    problems: list[str] = []
    lowered = line.lower()
    for value, placeholder in values:
        if value.lower() in lowered:
            problems.append(f"contains {placeholder} (this machine's value)")
    for email in EMAIL.findall(line):
        if not ALLOWED_EMAIL.match(email):
            problems.append("contains an email address that isn't a GitHub noreply address")
    return problems


def added_lines(root: Path) -> list[tuple[str, int, str]]:
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--diff-filter=ACMR"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8", "replace")
    out: list[tuple[str, int, str]] = []
    path, lineno = "", 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else raw[4:]
        elif raw.startswith("@@"):
            match = re.search(r"\+(\d+)", raw)
            lineno = int(match.group(1)) if match else 0
        elif raw.startswith("+"):
            out.append((path, lineno, raw[1:]))
            lineno += 1
    return out


def staged_paths(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8", "replace")
    return [p for p in out.split("\0") if p]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--staged", action="store_true")
    group.add_argument("--message", metavar="FILE")
    args = parser.parse_args(argv)

    root = repo_root()
    values = secrets(root)
    problems: list[str] = []

    if args.message:
        text = Path(args.message).read_text(encoding="utf-8", errors="replace")
        for n, line in enumerate(text.splitlines(), start=1):
            if line.startswith("#"):
                continue
            for problem in scan_line(line, values):
                problems.append(f"commit message line {n}: {problem}: {redact(line, values)}")
    else:
        for path in staged_paths(root):
            if "xcuserdata/" in path or path.endswith(".xcuserstate"):
                problems.append(f"{redact(path, values)}: per-user Xcode state must not be committed")
            if path.endswith("Signing.local.xcconfig"):
                problems.append(f"{path}: the local signing file holds the Team ID; it stays untracked")
        for path, n, line in added_lines(root):
            where = f"{redact(path, values)}:{n}"
            if path.endswith(".pbxproj") and TEAM_IN_PBXPROJ.search(line):
                problems.append(f"{where}: DEVELOPMENT_TEAM set in project.pbxproj (keep it in Signing.local.xcconfig)")
            for problem in scan_line(line, values):
                problems.append(f"{where}: {problem}: {redact(line.strip(), values)[:160]}")

    if problems:
        for problem in problems:
            print(f"  privacy: {problem}", file=sys.stderr)
        print(
            "privacy_scan: FAIL. Replace the values with <path>, <host>, <team> or ~ (see AGENTS.md, Privacy).",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
