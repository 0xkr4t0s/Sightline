# SPDX-License-Identifier: GPL-3.0-or-later
"""Lens merge, sensor presets, FOV maths and STATUS arguments (task 2.4; core/lens.py, vcp.md §6.2/§6.4)."""

import json
import math
import struct
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.lens import (  # noqa: E402
    SENSOR_FIT_CODES,
    SENSOR_PRESETS,
    LensControls,
    effective_fit,
    fov_and_equivalent,
    preset_sensor,
    render_aspect,
    status_lens,
)

DATA = Path(__file__).resolve().parents[2] / "testdata"
LENS_CASES = json.loads((DATA / "rig/lens_cases.json").read_text())


def f32(value: float) -> float:
    return float(struct.unpack("<f", struct.pack("<f", value))[0])


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


def test_auto_fit_is_reported_as_the_fit_blender_uses() -> None:
    # Blender's AUTO fits sensor_width to the longer side: horizontal unless the picture is portrait.
    assert SENSOR_FIT_CODES == {"HORIZONTAL": 0, "VERTICAL": 1, "AUTO": 2}
    assert effective_fit("AUTO", 16 / 9) == "HORIZONTAL"
    assert effective_fit("AUTO", 1.0) == "HORIZONTAL"
    assert effective_fit("AUTO", 9 / 16) == "VERTICAL"
    assert effective_fit("VERTICAL", 16 / 9) == "VERTICAL"
    assert effective_fit("HORIZONTAL", 0.5) == "HORIZONTAL"
    landscape = status_lens(24.0, 10.0, 2.8, False, 36.0, "AUTO", 16 / 9)
    assert landscape is not None and landscape["sensor_fit"] == 0 and landscape["dof_on"] is False
    portrait = status_lens(24.0, 10.0, 2.8, False, 36.0, "AUTO", 9 / 16)
    assert portrait is not None and portrait["sensor_fit"] == 1


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


@pytest.mark.parametrize("case", LENS_CASES["cases"], ids=[c["name"] for c in LENS_CASES["cases"]])
def test_fov_and_equivalent_match_the_lens_vectors(case: dict) -> None:
    fit = {0: "HORIZONTAL", 1: "VERTICAL", 2: "AUTO"}[case["sensor_fit"]]
    result = fov_and_equivalent(case["lens_mm"], case["sensor_width_mm"], fit, case["render_aspect"])
    assert result is not None
    tolerance = LENS_CASES["tolerance"]
    assert result[0] == pytest.approx(case["horizontal_fov_deg"], abs=tolerance)
    assert result[1] == pytest.approx(case["equivalent_35mm_focal_mm"], abs=tolerance)
    # The default camera's AUTO fit gives the same numbers for a landscape picture.
    assert fov_and_equivalent(case["lens_mm"], case["sensor_width_mm"], "AUTO", case["render_aspect"]) == result


def test_fov_is_unavailable_when_sensor_width_is_not_horizontal() -> None:
    assert fov_and_equivalent(50.0, 36.0, "VERTICAL", 16 / 9) is None
    assert fov_and_equivalent(50.0, 36.0, "AUTO", 9 / 16) is None
    assert fov_and_equivalent(50.0, 36.0, "SIDEWAYS", 16 / 9) is None


@pytest.mark.parametrize("case", LENS_CASES["cases"], ids=[c["name"] for c in LENS_CASES["cases"]])
def test_sensor_presets_match_the_lens_vectors(case: dict) -> None:
    preset = {
        "super_35": "SUPER_35",
        "full_frame": "FULL_FRAME",
        "arri_alexa_35_open_gate": "ALEXA_35_OG",
        "custom": "CUSTOM",
    }[case["name"]]
    width, fit = preset_sensor(preset, case["preset_sensor_width_mm"]) or (None, None)
    assert f32(width or 0.0) == case["sensor_width_mm"]
    assert fit == "HORIZONTAL" and SENSOR_FIT_CODES[fit] == case["sensor_fit"]


def test_sensor_preset_widths_and_keep_camera() -> None:
    assert {key: width for key, (_, width) in SENSOR_PRESETS.items()} == {
        "CAMERA": None,
        "SUPER_35": 24.89,
        "FULL_FRAME": 36.0,
        "ALEXA_35_OG": 27.99,
        "CUSTOM": None,
    }
    assert preset_sensor("CAMERA", 30.0) is None  # the camera keeps its own sensor
    assert preset_sensor("FULL_FRAME", 30.0) == (36.0, "HORIZONTAL")  # custom width only for CUSTOM
    assert preset_sensor("CUSTOM", 30.0) == (30.0, "HORIZONTAL")
    assert preset_sensor("CUSTOM", 0.5) is None
    assert preset_sensor("CUSTOM", math.nan) is None
    assert preset_sensor("IMAX", 30.0) is None


def control(**lens: object) -> dict[str, object]:
    keys = ("lens_mm", "focus_distance_m", "fstop", "dof_on")
    return {key: lens.get(key) for key in keys}


def test_lens_merge_keeps_absent_fields_and_applies_only_changed_requests() -> None:
    lens = LensControls()
    assert lens.merge(control(lens_mm=50.0, focus_distance_m=2.0, fstop=1.4, dof_on=True))
    assert lens.take() == {"lens_mm": 50.0, "focus_distance_m": 2.0, "fstop": 1.4, "dof_on": True}
    assert lens.take() == {}
    # Bits clear: nothing to apply, the request is kept.
    assert not lens.merge(control())
    assert lens.requested == {"lens_mm": 50.0, "focus_distance_m": 2.0, "fstop": 1.4, "dof_on": True}
    # A complete state that repeats the same lens doesn't rewrite the camera (host edits survive).
    assert not lens.merge(control(lens_mm=50.0, focus_distance_m=2.0, fstop=1.4, dof_on=True))
    assert lens.take() == {}
    # DoF off leaves the f-stop alone.
    assert lens.merge(control(lens_mm=50.0, focus_distance_m=2.0, fstop=1.4, dof_on=False))
    assert lens.take() == {"dof_on": False}
    assert lens.requested["fstop"] == 1.4


def test_lens_merge_rejects_the_whole_lens_part_on_any_invalid_value() -> None:
    lens = LensControls()
    lens.merge(control(lens_mm=24.0, focus_distance_m=2.0))
    lens.take()
    for bad in (
        control(lens_mm=math.nan, focus_distance_m=5.0),
        control(lens_mm=-35.0),
        control(lens_mm=85.0, focus_distance_m=0.0),
        control(fstop=math.inf),
        control(fstop=200.0),
        control(dof_on=1),
    ):
        assert not lens.merge(bad), bad
        assert lens.take() == {}
    assert lens.requested == {"lens_mm": 24.0, "focus_distance_m": 2.0}


def test_pending_changes_accumulate_until_taken() -> None:
    lens = LensControls()
    lens.merge(control(lens_mm=24.0))
    lens.merge(control(lens_mm=35.0, fstop=4.0))
    assert lens.take() == {"lens_mm": 35.0, "fstop": 4.0}
