"""Resident memory and open handles of a process, without new dependencies (task 2.7; NFR-REL-003).

macOS: `ps -o rss= -p PID` (KiB) and `lsof -n -P -F f -p PID` (numbered file descriptors only, so
the binary, its libraries and memory-mapped files don't count). Linux: `/proc/PID/status` VmRSS
(kB) and the entries of `/proc/PID/fd`.
"""

from __future__ import annotations

import os
import platform
import re
import subprocess
from collections.abc import Callable
from pathlib import Path

Runner = Callable[[list[str]], str | None]

_VMRSS = re.compile(r"^VmRSS:\s+(\d+)\s+kB", re.MULTILINE)


class UnsupportedPlatformError(RuntimeError):
    """Sampling is implemented for macOS and Linux only."""


def run_text(cmd: list[str]) -> str | None:
    """stdout of `cmd`, or None if it fails (for example because the process is gone)."""
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def parse_ps_rss_kib(text: str) -> int | None:
    value = text.strip()
    return int(value) if value.isdigit() else None


def parse_lsof_fds(text: str) -> int:
    """Numbered descriptors in `lsof -F f` output (`f0`, `f17`; not `fcwd`, `ftxt`, `fmem`)."""
    return sum(1 for line in text.splitlines() if line.startswith("f") and line[1:].isdigit())


def parse_proc_status_rss_kib(text: str) -> int | None:
    match = _VMRSS.search(text)
    return int(match.group(1)) if match else None


def _sample_linux(pid: int, proc_root: Path) -> tuple[int | None, int | None]:
    proc = proc_root / str(pid)
    try:
        rss = parse_proc_status_rss_kib((proc / "status").read_text(encoding="utf-8"))
        handles: int | None = len(os.listdir(proc / "fd"))
    except OSError:
        return None, None
    return rss, handles


def _sample_macos(pid: int, run: Runner) -> tuple[int | None, int | None]:
    ps = run(["ps", "-o", "rss=", "-p", str(pid)])
    lsof = run(["lsof", "-n", "-P", "-F", "f", "-p", str(pid)])
    return (
        None if ps is None else parse_ps_rss_kib(ps),
        None if lsof is None else parse_lsof_fds(lsof),
    )


def sample_process(
    pid: int,
    system: str | None = None,
    run: Runner = run_text,
    proc_root: Path = Path("/proc"),
) -> tuple[int | None, int | None]:
    """(RSS in KiB, open handles) of `pid`; either is None if it couldn't be read."""
    system = system or platform.system()
    if system == "Darwin":
        return _sample_macos(pid, run)
    if system == "Linux":
        return _sample_linux(pid, proc_root)
    raise UnsupportedPlatformError(f"soak sampling supports macOS and Linux, not {system}")


def pid_alive(pid: int | None) -> bool:
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
