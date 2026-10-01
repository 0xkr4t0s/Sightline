# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel status formatting (task 1.3.3; FR-BL-004)."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.status import (  # noqa: E402
    code_label,
    frame_label,
    lens_labels,
    locks_label,
    m2p_label,
    pose_latency_ms,
    scale_label,
    thermal_label,
    tracking_label,
    video_labels,
)


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


def test_thermal_status_uses_actual_selected_stream_level():
    assert thermal_label(None, (960, 540), 30) == "Device thermal: unknown"
    assert thermal_label(0, (960, 540), 30) == "Device thermal: nominal"
    assert thermal_label(1, (960, 540), 30) == "Device thermal: fair"
    assert thermal_label(2, (640, 360), 24) == "Device thermal: serious — stream reduced to 640×360 @ 24 fps"
    assert thermal_label(3, (960, 540), 24) == "Device thermal: critical — stream reduced to 960×540 @ 24 fps"


def test_frame_label_shows_the_fitted_frame_and_render_aspect():
    assert frame_label((960, 402), 2048 / 858) == "Frame: 960×402 (render 2.39:1)"
    assert frame_label((304, 540), 1080 / 1920) == "Frame: 304×540 (render 0.56:1)"


def test_video_counters_show_the_last_frame_and_only_real_failures():
    stats = {
        "sent": 40,
        "encoded_skipped": 2,
        "quality": 80,
        "user_quality": 80,
        "send_failed": 0,
        "encode_failed": 0,
        "last_error": None,
        "last_sent": None,
        "unsent": 5,
        "adapt": None,
    }
    assert video_labels(None, '540p') == ["Video: not streaming"]
    assert video_labels(stats, '540p') == ["Video: 40 sent, 2 skipped, q80"]  # unsent (no device) is not a failure
    stats["last_sent"] = {"width": 960, "height": 540, "jpeg_bytes": 52099, "encode_ns": 890_000, "send_ns": 320_000}
    stats.update(send_failed=1, last_error="timed out")
    assert video_labels(stats, '540p')[1:] == [
        "Last: 960×540, 51 KB, encode 0.9 ms, send 0.3 ms",
        "Video failures: 1 (timed out)",
    ]


def test_adaptation_shows_the_level_as_a_size_below_the_users_and_why_it_changed():
    adapt = {"quality": 80, "resolution_drop": 0, "expected": 0, "lost": 0, "report": None, "last_change": None}
    stats = {
        "sent": 3,
        "encoded_skipped": 0,
        "quality": 80,
        "user_quality": 80,
        "send_failed": 0,
        "encode_failed": 0,
        "last_error": None,
        "last_sent": None,
        "adapt": adapt,
    }
    assert video_labels(stats, '720p')[1:] == [
        "Adaptive: full, q80 1280×720",
        "Link: 0 of 0 frames lost",
        "Device M2P: no report yet",
    ]
    # At the user's quality but one size down is still lowered.
    adapt.update(
        quality=50,
        resolution_drop=1,
        expected=300,
        lost=40,
        report={"m2p_p95_ms": 0},
        last_change={
            "reason": "loss",
            "lost": 5,
            "expected": 15,
            "m2p_p95_ms": None,
            "from_quality": 50,
            "from_resolution_drop": 0,
            "to_quality": 50,
            "to_resolution_drop": 1,
        },
    )
    stats["user_quality"] = 50
    assert video_labels(stats, '720p')[1:] == [
        "Adaptive: lowered to q50 960×540",
        "Link: 40 of 300 frames lost",
        "Device M2P: not measured yet",
        "Last change: q50 1280×720 → q50 960×540 (5/15 lost)",
    ]
    adapt["report"] = {"m2p_p95_ms": 140}
    adapt["last_change"].update(reason="m2p", lost=None, expected=None, m2p_p95_ms=140)
    assert video_labels(stats, '720p')[2:] == [
        "Link: 40 of 300 frames lost",
        "Device M2P p95: 140 ms (over 120 ms)",
        "Last change: q50 1280×720 → q50 960×540 (M2P 140 ms)",
    ]
    adapt["last_change"].update(reason="recovered", m2p_p95_ms=None, from_resolution_drop=2, to_resolution_drop=1)
    assert video_labels(stats, '720p')[4] == "Last change: q50 640×360 → q50 960×540 (link clear)"
    # The newest report replaces the value (no stale M2P).
    adapt["report"] = {"m2p_p95_ms": 62}
    # LNS-003: the levels are the frame sizes actually streamed at the render aspect (2.39:1).
    assert video_labels(stats, '720p', 2048 / 858)[1:] == [
        "Adaptive: lowered to q50 960×402",
        "Link: 40 of 300 frames lost",
        "Device M2P p95: 62 ms",
        "Last change: q50 640×268 → q50 960×402 (link clear)",
    ]


@pytest.mark.parametrize(
    ("report", "expected"),
    [
        (None, "Device M2P: no report yet"),
        ({"m2p_p95_ms": 0}, "Device M2P: not measured yet"),
        ({"m2p_p95_ms": 1}, "Device M2P p95: 1 ms"),
        ({"m2p_p95_ms": 120}, "Device M2P p95: 120 ms"),
        ({"m2p_p95_ms": 121}, "Device M2P p95: 121 ms (over 120 ms)"),
        ({"m2p_p95_ms": 65535}, "Device M2P p95: ≥ 65535 ms (saturated)"),
    ],
)
def test_device_m2p_line_follows_the_newest_video_report(report, expected):
    assert m2p_label(report) == expected


def test_lens_labels_show_the_camera_values_and_derived_fov():
    # Blender stores floats as binary32: 2.8 arrives as 2.799999952316284.
    assert lens_labels(85.0, 2.0, 2.799999952316284, True, 24.889999389648438, 'HORIZONTAL', 16 / 9) == [
        "Focal length: 85 mm",
        "Focus distance: 2.00 m",
        "Aperture: f/2.8",
        "Depth of field: on",
        "Sensor: 24.89 mm, horizontal fit",
        "FOV 16.7°, 35 mm equivalent 129 mm",
    ]


def test_lens_labels_resolve_auto_fit_and_mark_unavailable_fov():
    labels = lens_labels(24.0, 10.0, 1.4, False, 36.0, 'AUTO', 16 / 9)
    assert labels[3:] == [
        "Depth of field: off",
        "Sensor: 36 mm, auto fit (horizontal)",
        "FOV 73.7°, 35 mm equivalent 25 mm",
    ]
    assert lens_labels(24.0, 10.0, 1.4, False, 36.0, 'AUTO', 9 / 16)[4:] == [
        "Sensor: 36 mm, auto fit (vertical)",
        "FOV: unavailable (vertical fit)",
    ]
    assert lens_labels(24.0, 10.0, 1.4, False, 36.0, 'VERTICAL', 16 / 9)[4:] == [
        "Sensor: 36 mm, vertical fit",
        "FOV: unavailable (vertical fit)",
    ]
