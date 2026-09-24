# SPDX-License-Identifier: GPL-3.0-or-later
"""Host ID persistence (task 1.2.5b; vcp.md §9.3): paired devices depend on it never changing."""

import os
import sys
from pathlib import Path

import pytest

# Allow running tests standalone outside Blender
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.session import HOST_ID_FILE, load_or_create_host_id  # noqa: E402


def test_host_id_is_created_once_privately_and_then_reused(tmp_path):
    first = load_or_create_host_id(str(tmp_path))
    assert len(first) == 16
    assert load_or_create_host_id(str(tmp_path)) == first
    if os.name == "posix":
        assert (tmp_path / HOST_ID_FILE).stat().st_mode & 0o777 == 0o600
    assert sorted(p.name for p in tmp_path.iterdir()) == [HOST_ID_FILE]  # no temp file left


def test_damaged_host_id_is_rejected_not_replaced(tmp_path):
    (tmp_path / HOST_ID_FILE).write_bytes(b"short")
    with pytest.raises(ValueError, match="damaged"):
        load_or_create_host_id(str(tmp_path))
    assert (tmp_path / HOST_ID_FILE).read_bytes() == b"short"
