# SPDX-License-Identifier: GPL-3.0-or-later
"""Add-on logging: the `vcam_blender` logger tree, with redaction, off-disk by default.

By default only warnings reach Blender's console and nothing is written to a file. File logging
turns on when `SIGHTLINE_LOG_FILE` names a file when the add-on registers, or when a caller (the
QA host, `tools/mission/qa_host.py`) calls `log_to_file`. Every handler added here redacts the
home directory (to `~`) and this machine's host name (to `<host>`), so a log can be shared.
Pairing codes and keys are never logged.

Pure Python (no `bpy`), tested outside Blender.
"""

from __future__ import annotations

import logging
import os
import platform
import re
import socket
import sys
from collections.abc import Mapping

ROOT = "vcam_blender"
ENV_LOG_FILE = "SIGHTLINE_LOG_FILE"
FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"
# Marks handlers this module owns: the logging tree outlives an add-on reload.
_OWNED = "_sightline_handler"


def get_logger(name: str) -> logging.Logger:
    """The child of `vcam_blender` for a module `__name__`, whatever package it's installed as."""
    parts = name.split(".")
    if ROOT in parts:
        parts = parts[parts.index(ROOT) + 1 :]
    return logging.getLogger(".".join([ROOT, *parts]))


def _host_names() -> list[str]:
    names = set()
    for name in (socket.gethostname(), platform.node()):
        name = (name or "").strip()
        if not name:
            continue
        short = name.split(".")[0]
        names.update({name, short, f"{short}.local"})
    names.discard("localhost")
    return sorted((n for n in names if n), key=len, reverse=True)


def _redaction_patterns() -> list[tuple[re.Pattern[str], str]]:
    patterns = []
    home = os.path.expanduser("~")
    if home and home not in ("/", "~"):
        for path in sorted({home, os.path.realpath(home)}, key=len, reverse=True):
            patterns.append((re.compile(re.escape(path) + r"(?![^/\\\s'\"),:;\]])"), "~"))
    for name in _host_names():
        patterns.append((re.compile(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", re.IGNORECASE), "<host>"))
    return patterns


class RedactFilter(logging.Filter):
    """Replaces the home directory with `~` and the host name with `<host>` in each record."""

    def __init__(self) -> None:
        super().__init__()
        self.patterns = _redaction_patterns()

    def redact(self, text: str) -> str:
        for pattern, replacement in self.patterns:
            text = pattern.sub(replacement, text)
        return text

    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = self.redact(record.getMessage())
        record.args = None
        if record.exc_info and not record.exc_text:
            record.exc_text = logging.Formatter().formatException(record.exc_info)
        if record.exc_text:
            record.exc_text = self.redact(record.exc_text)
        if record.stack_info:
            record.stack_info = self.redact(record.stack_info)
        return True


_redactor: RedactFilter | None = None


def redact(text: str) -> str:
    """`text` with the home directory and host name replaced, as in the log."""
    global _redactor
    if _redactor is None:
        _redactor = RedactFilter()
    return _redactor.redact(text)


def _own(handler: logging.Handler, level: int) -> logging.Handler:
    handler.setLevel(level)
    handler.setFormatter(logging.Formatter(FORMAT))
    handler.addFilter(RedactFilter())
    setattr(handler, _OWNED, True)
    return handler


def _root() -> logging.Logger:
    root = logging.getLogger(ROOT)
    if not any(getattr(h, _OWNED, False) for h in root.handlers):
        root.propagate = False  # Blender's root logger isn't ours to configure
        root.setLevel(logging.WARNING)
        root.addHandler(_own(logging.StreamHandler(sys.stderr), logging.WARNING))
    return root


def log_to_file(path: str, level: int = logging.INFO, mode: str = "a") -> logging.Handler:
    """Also write records at `level` and above to `path`, one flushed line each. Idempotent per path."""
    root = _root()
    path = os.path.abspath(path)
    for handler in root.handlers:
        if isinstance(handler, logging.FileHandler) and handler.baseFilename == path:
            return handler
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handler = _own(logging.FileHandler(path, mode=mode, encoding="utf-8"), level)
    root.addHandler(handler)
    root.setLevel(min(root.level, level))
    return handler


def configure_from_env(environ: Mapping[str, str] = os.environ) -> logging.Handler | None:
    """Called at register: file logging only when `SIGHTLINE_LOG_FILE` is set."""
    _root()
    path = environ.get(ENV_LOG_FILE)
    return log_to_file(path) if path else None


def close_files() -> None:
    """Closes the file handlers (at unregister); console warnings stay."""
    root = logging.getLogger(ROOT)
    for handler in list(root.handlers):
        if isinstance(handler, logging.FileHandler) and getattr(handler, _OWNED, False):
            root.removeHandler(handler)
            handler.close()
    root.setLevel(logging.WARNING)
