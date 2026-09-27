# SPDX-License-Identifier: GPL-3.0-or-later
"""Add-on logging: redaction of the home directory and host name, and file logging only on request."""

import logging
import os
import socket
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import log  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_logger():
    log.close_files()
    yield
    log.close_files()


def _record(msg, *args, exc_info=None):
    return logging.LogRecord("vcam_blender.test", logging.INFO, __file__, 1, msg, args, exc_info)


def test_child_loggers_hang_off_vcam_blender_whatever_the_install_package():
    assert log.get_logger("bl_ext.user_default.vcam_blender.core.session").name == "vcam_blender.core.session"
    assert log.get_logger("core.session").name == "vcam_blender.core.session"
    assert log.get_logger("bl_ext.user_default.vcam_blender").name == "vcam_blender"


def test_home_directory_becomes_tilde_but_a_longer_sibling_does_not():
    home = os.path.expanduser("~")
    record = _record("saved %s and %s", os.path.join(home, "scene.blend"), home + "x/other")
    assert log.RedactFilter().filter(record)
    assert record.getMessage() == f"saved {os.path.join('~', 'scene.blend')} and {home}x/other"
    assert log.redact(f'path="{home}"') == 'path="~"'


def test_host_name_and_its_local_variants_become_host(monkeypatch):
    monkeypatch.setattr(socket, "gethostname", lambda: "Studio-Mac.local")
    monkeypatch.setattr(log.platform, "node", lambda: "Studio-Mac.local")
    f = log.RedactFilter()
    assert f.redact("advertised as Studio-Mac.local.") == "advertised as <host>."
    assert f.redact("name studio-mac, fqdn Studio-Mac.local") == "name <host>, fqdn <host>"
    # Only whole names: a longer word that contains the host name is left alone.
    assert f.redact("Studio-Machine Studio-Mac2") == "Studio-Machine Studio-Mac2"
    assert f.redact("connect to localhost") == "connect to localhost"


def test_tracebacks_are_redacted_too():
    home = os.path.expanduser("~")
    try:
        raise OSError(f"cannot open {home}/secret.blend")
    except OSError:
        record = _record("failed", exc_info=sys.exc_info())
    log.RedactFilter().filter(record)
    assert "~/secret.blend" in record.exc_text and f"{home}/" not in record.exc_text


def test_no_file_unless_the_env_var_is_set(tmp_path):
    assert log.configure_from_env({}) is None
    root = logging.getLogger(log.ROOT)
    assert not any(isinstance(h, logging.FileHandler) for h in root.handlers)
    assert root.propagate is False and root.level == logging.WARNING
    log.get_logger("core.session").info("session started port=47000")
    assert list(tmp_path.iterdir()) == []


def test_env_var_writes_redacted_one_line_records(tmp_path):
    path = tmp_path / "logs" / "addon.log"
    handler = log.configure_from_env({log.ENV_LOG_FILE: str(path)})
    assert handler is not None
    assert log.log_to_file(str(path)) is handler  # idempotent per path
    home = os.path.expanduser("~")
    logger = log.get_logger("bl_ext.user_default.vcam_blender.core.session")
    logger.info("session started port=%d dir=%s", 47000, os.path.join(home, "cfg"))
    logger.debug("not at INFO")
    lines = path.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1, lines
    assert lines[0].endswith(
        f" INFO vcam_blender.core.session session started port=47000 dir={os.path.join('~', 'cfg')}"
    )
    log.close_files()
    logger.info("after close")
    assert len(path.read_text(encoding="utf-8").splitlines()) == 1
