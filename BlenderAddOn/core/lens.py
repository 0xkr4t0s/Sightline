# SPDX-License-Identifier: GPL-3.0-or-later
"""The applied lens the host reports in STATUS (task 2.4; FR-CTL-009, vcp.md §6.4).

Pure: the caller reads the values from the target camera and the scene on the main thread.
Blender allows values outside the wire ranges (for example a focus distance of 0 or a 5000 mm
lens); then no lens block is sent, rather than a clamped value the camera doesn't have.
"""

from __future__ import annotations

import math

# Inclusive vcp.md §6.4 ranges.
LENS_MM = (1.0, 2500.0)
DISTANCE_M = (0.01, 100_000.0)
FSTOP = (0.1, 128.0)
SENSOR_WIDTH_MM = (1.0, 1000.0)
RENDER_ASPECT = (0.1, 10.0)
# Blender's `Camera.sensor_fit` → the STATUS enum.
SENSOR_FIT_CODES = {"HORIZONTAL": 0, "VERTICAL": 1, "AUTO": 2}


def render_aspect(resolution_x: int, resolution_y: int, pixel_aspect_x: float, pixel_aspect_y: float) -> float:
    """Picture width / height: `resolution_x × pixel_aspect_x / (resolution_y × pixel_aspect_y)`."""
    return resolution_x * pixel_aspect_x / (resolution_y * pixel_aspect_y)


def _within(value: float, bounds: tuple[float, float]) -> bool:
    return math.isfinite(value) and bounds[0] <= value <= bounds[1]


def status_lens(
    lens_mm: float,
    focus_distance_m: float,
    fstop: float,
    dof_on: bool,
    sensor_width_mm: float,
    sensor_fit: str,
    aspect: float,
) -> dict[str, float | int | bool] | None:
    """Keyword arguments for `Session.update_status`, or None if a value is outside its range."""
    fit = SENSOR_FIT_CODES.get(sensor_fit)
    checks = (
        (lens_mm, LENS_MM),
        (focus_distance_m, DISTANCE_M),
        (fstop, FSTOP),
        (sensor_width_mm, SENSOR_WIDTH_MM),
        (aspect, RENDER_ASPECT),
    )
    if fit is None or not all(_within(value, bounds) for value, bounds in checks):
        return None
    return {
        "lens_mm": lens_mm,
        "focus_distance_m": focus_distance_m,
        "fstop": fstop,
        "dof_on": bool(dof_on),
        "sensor_width_mm": sensor_width_mm,
        "sensor_fit": fit,
        "render_aspect": aspect,
    }
