# SPDX-License-Identifier: GPL-3.0-or-later
"""STATUS applied-lens arguments from Blender camera values (task 2.4; core/lens.py, vcp.md §6.4)."""

import json
import math
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.lens import SENSOR_FIT_CODES, render_aspect, status_lens  # noqa: E402

DATA = Path(__file__).resolve().parents[2] / "testdata"


def test_status_vector_values_become_update_status_arguments() -> None:
    status = next(
        c for c in json.loads((DATA / "vcp/messages.json").read_text())["cases"] if c["name"] == "status_applied_lens"
    )
    want = status["fields"]["applied_lens"]
    args = status_lens(50.0, 4.0, 2.8, True, 36.0, "HORIZONTAL", render_aspect(1920, 1280, 1.0, 1.0))
    assert args == {
        "lens_mm": want["lens_mm"],
        "focus_distance_m": want["focus_distance_m"],
        "fstop": want["fstop"],
        "dof_on": True,
        "sensor_width_mm": want["sensor_width_mm"],
        "sensor_fit": want["sensor_fit"],
        "render_aspect": want["render_aspect"],
    }


def test_render_aspect_includes_pixel_aspect() -> None:
    assert render_aspect(1920, 1080, 1.0, 1.0) == pytest.approx(16 / 9)
    assert render_aspect(1440, 1080, 4.0, 3.0) == pytest.approx(16 / 9)
    assert render_aspect(1080, 1920, 1.0, 1.0) == pytest.approx(9 / 16)


def test_every_blender_sensor_fit_has_a_wire_code() -> None:
    assert SENSOR_FIT_CODES == {"HORIZONTAL": 0, "VERTICAL": 1, "AUTO": 2}
    args = status_lens(24.0, 10.0, 2.8, False, 36.0, "AUTO", 16 / 9)
    assert args is not None and args["sensor_fit"] == 2 and args["dof_on"] is False


@pytest.mark.parametrize(
    ("index", "value"),
    [
        (0, 0.5),  # lens below 1 mm
        (0, 2500.5),
        (1, 0.0),  # Blender's focus distance may be 0; the wire's minimum is 0.01 m
        (1, 100_001.0),
        (2, 0.0),  # f-stop
        (2, 128.5),
        (4, 0.5),  # sensor width
        (4, 1000.5),
        (6, 0.05),  # render aspect
        (6, math.inf),
        (0, math.nan),
    ],
)
def test_out_of_range_values_leave_the_lens_block_out(index: int, value: float) -> None:
    args: list[float | bool | str] = [50.0, 4.0, 2.8, True, 36.0, "HORIZONTAL", 1.5]
    assert status_lens(*args) is not None
    args[index] = value
    assert status_lens(*args) is None


def test_range_edges_are_inclusive_and_unknown_fit_is_rejected() -> None:
    assert status_lens(1.0, 0.01, 0.1, True, 1.0, "VERTICAL", 0.1) is not None
    assert status_lens(2500.0, 100_000.0, 128.0, True, 1000.0, "HORIZONTAL", 10.0) is not None
    assert status_lens(50.0, 4.0, 2.8, True, 36.0, "MILLIMETERS", 1.5) is None
