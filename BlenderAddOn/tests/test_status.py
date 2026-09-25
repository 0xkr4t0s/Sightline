# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel status formatting (task 1.3.3; FR-BL-004)."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.status import code_label, locks_label, pose_latency_ms, scale_label, tracking_label  # noqa: E402


def test_scale_reads_device_to_host_as_in_the_protocol():
    # vcp.md §6.2: 1:10 is sent as 10.0 host metres per device metre.
    assert scale_label(10.0) == "1:10"
    assert scale_label(1.0) == "1:1"
    assert scale_label(0.5) == "2:1"


def test_latency_maps_capture_time_through_the_clock_offset():
    # Device clock 1000 s ahead; captured at host time 5.000 s, now 5.012 s -> 12 ms.
    offset = 1_000_000_000_000
    assert pose_latency_ms(5_000_000_000 + offset, offset, 5_012_000_000) == pytest.approx(12.0)


def test_tracking_and_locks_labels():
    assert tracking_label(5) == "Normal"
    assert tracking_label(4) == "Relocalizing"
    assert tracking_label(99) == "Limited"  # future reasons are "limited" (vcp.md §6.1)
    assert tracking_label(None) == "No pose yet"
    assert locks_label(0) == "None"
    assert locks_label(0b111) == "Pan only, Height, Roll"


def test_pairing_code_is_grouped():
    assert code_label("042917") == "042 917"
