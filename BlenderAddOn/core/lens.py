# SPDX-License-Identifier: GPL-3.0-or-later
"""The virtual lens: device requests, sensor presets and the applied lens in STATUS (task 2.4).

FR-BL-005, FR-CTL-001/003/009, LNS-001/002, vcp.md §6.2/§6.4. Pure: `core/apply.py` reads and
writes the target camera on the main thread.

**Requests** (`LensControls`): the device's lens, focus distance, f-stop and DoF flag are
absolute state. `rig.Controls` merges a `CONTROL_STATE` only if its `state_seq` is newer, then
hands it here. An absent field keeps the previous request. A field is written to the camera
only when the device's request for it changes (or is first seen in the session), so a later
complete state that repeats the same lens doesn't undo an edit made in Blender. An invalid
value (Rust already rejects these) drops the lens part of that message as a whole.

**Presets** (LNS-002): Super 35, Full Frame, ARRI Alexa 35 Open Gate and a custom width set the
camera's `sensor_width` and `sensor_fit` = HORIZONTAL. "Camera" leaves the camera's own sensor.

**Applied lens** (STATUS): what the camera has, not what was requested. Blender allows values
outside the wire ranges (for example a focus distance of 0 or a 5000 mm lens); then no lens
block is sent, rather than a clamped value the camera doesn't have. Blender's default fit AUTO
is reported as the fit Blender actually uses: AUTO fits `sensor_width` to the longer side of the
picture, so it is HORIZONTAL when `resolution_x × pixel_aspect_x ≥ resolution_y ×
pixel_aspect_y` (verified against `calc_matrix_camera` in Blender 5.2.2), and the device can
show the FOV and 35 mm equivalent. A portrait AUTO camera is reported as VERTICAL, for which
the device shows them as unavailable (vcp.md §6.4).
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any

# Inclusive vcp.md §6.4 ranges.
LENS_MM = (1.0, 2500.0)
DISTANCE_M = (0.01, 100_000.0)
FSTOP = (0.1, 128.0)
SENSOR_WIDTH_MM = (1.0, 1000.0)
RENDER_ASPECT = (0.1, 10.0)
# Blender's `Camera.sensor_fit` → the STATUS enum.
SENSOR_FIT_CODES = {"HORIZONTAL": 0, "VERTICAL": 1, "AUTO": 2}
# The device's float requests (vcp.md §6.2 bits 4-6) and their ranges; `dof_on` (bit 7) is a bool.
REQUEST_RANGES = {"lens_mm": LENS_MM, "focus_distance_m": DISTANCE_M, "fstop": FSTOP}
REQUEST_KEYS = (*REQUEST_RANGES, "dof_on")
# Scene preset key → (label, sensor width in mm); None: the camera's own ("CAMERA") or the custom width.
SENSOR_PRESETS: dict[str, tuple[str, float | None]] = {
    "CAMERA": ("Camera", None),
    "SUPER_35": ("Super 35", 24.89),
    "FULL_FRAME": ("Full Frame", 36.0),
    "ALEXA_35_OG": ("ARRI Alexa 35 Open Gate", 27.99),
    "CUSTOM": ("Custom", None),
}
PRESET_FIT = "HORIZONTAL"
# The 36 × 24 mm diagonal, rounded as in vcp.md §6.4.
FULL_FRAME_DIAGONAL_MM = 43.27

Lens = dict[str, float | bool]


def render_aspect(resolution_x: int, resolution_y: int, pixel_aspect_x: float, pixel_aspect_y: float) -> float:
    """Picture width / height: `resolution_x × pixel_aspect_x / (resolution_y × pixel_aspect_y)`."""
    return resolution_x * pixel_aspect_x / (resolution_y * pixel_aspect_y)


def _within(value: float, bounds: tuple[float, float]) -> bool:
    return math.isfinite(value) and bounds[0] <= value <= bounds[1]


def effective_fit(sensor_fit: str, aspect: float) -> str:
    """The fit Blender uses for `sensor_width`: AUTO resolves by the picture's longer side."""
    if sensor_fit == "AUTO":
        return "HORIZONTAL" if aspect >= 1.0 else "VERTICAL"
    return sensor_fit


def fov_and_equivalent(
    lens_mm: float, sensor_width_mm: float, sensor_fit: str, aspect: float
) -> tuple[float, float] | None:
    """(horizontal FOV in degrees, 35 mm-equivalent focal length in mm), vcp.md §6.4.

    None unless `sensor_width` spans the picture's width: the other fits depend on the camera's
    `sensor_height`, which STATUS doesn't carry.
    """
    if effective_fit(sensor_fit, aspect) != "HORIZONTAL":
        return None
    fov = math.degrees(2.0 * math.atan(sensor_width_mm / (2.0 * lens_mm)))
    diagonal = math.hypot(sensor_width_mm, sensor_width_mm / aspect)
    return fov, lens_mm * FULL_FRAME_DIAGONAL_MM / diagonal


def preset_sensor(preset: str, custom_width_mm: float) -> tuple[float, str] | None:
    """(sensor_width, sensor_fit) to set on the camera, or None to leave it alone."""
    if preset not in SENSOR_PRESETS or preset == "CAMERA":
        return None
    width = SENSOR_PRESETS[preset][1]
    if width is None:
        if not _within(custom_width_mm, SENSOR_WIDTH_MM):
            return None
        width = custom_width_mm
    return width, PRESET_FIT


def status_lens(
    lens_mm: float,
    focus_distance_m: float,
    fstop: float,
    dof_on: bool,
    sensor_width_mm: float,
    sensor_fit: str,
    aspect: float,
) -> Lens | None:
    """Keyword arguments for `Session.update_status`, or None if a value is outside its range."""
    fit = SENSOR_FIT_CODES.get(effective_fit(sensor_fit, aspect))
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


def _valid_request(key: str, value: Any) -> bool:
    if key == "dof_on":
        return isinstance(value, bool)
    return isinstance(value, float | int) and not isinstance(value, bool) and _within(value, REQUEST_RANGES[key])


class LensControls:
    """The device's merged lens request of one session, and the changes not yet on the camera."""

    def __init__(self) -> None:
        self.requested: Lens = {}
        self.pending: Lens = {}

    def merge(self, control: Mapping[str, Any]) -> bool:
        """Merges the lens keys of an accepted `latest_control()` dict; True if a request changed."""
        present = {key: control[key] for key in REQUEST_KEYS if control.get(key) is not None}
        if not all(_valid_request(key, value) for key, value in present.items()):
            return False
        changed = {key: value for key, value in present.items() if self.requested.get(key) != value}
        self.requested.update(changed)
        self.pending.update(changed)
        return bool(changed)

    def take(self) -> Lens:
        """The changed requests to write to the camera, once."""
        pending, self.pending = self.pending, {}
        return pending
