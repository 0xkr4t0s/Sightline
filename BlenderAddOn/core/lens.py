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

**Tap-to-focus and A/B rack** (FR-CTL-002, vcp.md §6.2 bits 8-9): `tap_seq` and `rack_seq` are
request identities. The first value seen in a session is the baseline and starts nothing; each
later change starts exactly one tap or rack, and a resend of the same sequence never repeats it.
A tap is a ray from the camera through (u, v) of the streamed picture, u from the left edge and
v from the **top** edge, interpolated on `Camera.view_frame` (`tap_ray`). The focus distance it
sets is the hit's distance **along the camera's view axis** (the depth of the focal plane, as
Blender uses `dof.focus_distance`), not the euclidean length of the ray (`axial_distance`).

A rack (`FocusRack`) moves the focus distance from the camera's value when it starts to the
selected mark over `rack_duration_ms`, eased with smoothstep 3t² − 2t³ (monotonic, starts and
ends at rest); a duration of 0 jumps. Requests of one message are handled in the order manual
focus, tap, rack. A changed manual focus request or a new tap cancels a running rack.

A tap or a rack moves the focus away from the manual request, so it ends that request: the next
manual focus is written (and cancels a running rack) even if it repeats the earlier distance.
The device leaves bit 5 clear after a tap or a rack until the operator sets a focus again
(vcp.md §6.2), so a later unrelated change doesn't undo the tap or the rack.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
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
# vcp.md §6.2 `rack_target`.
RACK_NONE, RACK_A, RACK_B = 0, 1, 2
RACK_DURATION_MS = (0, 60_000)
SEQ_MAX = 0xFFFF
TAP_KEYS = ("tap_u", "tap_v", "tap_seq")
RACK_KEYS = ("rack_a_m", "rack_b_m", "rack_target", "rack_duration_ms", "rack_seq")

Lens = dict[str, float | bool]
Vec3 = tuple[float, float, float]
# A new tap: (u, v). A new rack: (target, mark distance in m, duration in s).
Tap = tuple[float, float]
Rack = tuple[int, float, float]


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


def _lerp(a: Sequence[float], b: Sequence[float], t: float) -> Vec3:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


def frame_point(corners: Sequence[Sequence[float]], u: float, v: float) -> Vec3:
    """The camera-local point at (u, v) of the picture, on the `Camera.view_frame` corners.

    `corners` in `view_frame` order: top right (+x, +y), bottom right, bottom left, top left.
    u runs from the left edge, v from the top edge.
    """
    top_right, bottom_right, bottom_left, top_left = corners
    return _lerp(_lerp(top_left, top_right, u), _lerp(bottom_left, bottom_right, u), v)


def tap_ray(
    corners: Sequence[Sequence[float]],
    u: float,
    v: float,
    clip_start: float,
    clip_end: float,
    orthographic: bool = False,
) -> tuple[Vec3, Vec3, float]:
    """Camera-local ray through (u, v) between the clip planes: (start, unit direction, length).

    Only what the stream can show is hit: the ray starts on the near clip plane and ends on the
    far one. A perspective ray leaves the camera's origin; an orthographic one runs along −Z
    from the picture point.
    """
    x, y, z = frame_point(corners, u, v)
    if orthographic:
        return (x, y, -clip_start), (0.0, 0.0, -1.0), clip_end - clip_start
    length = math.sqrt(x * x + y * y + z * z)
    direction = (x / length, y / length, z / length)
    per_depth = length / -z  # ray length per metre along the view axis
    start = clip_start * per_depth
    return (
        (direction[0] * start, direction[1] * start, direction[2] * start),
        direction,
        (clip_end - clip_start) * per_depth,
    )


def axial_distance(origin: Sequence[float], axis: Sequence[float], point: Sequence[float]) -> float:
    """Distance from `origin` to `point` measured along `axis` (the camera's view axis)."""
    norm = math.sqrt(sum(a * a for a in axis))
    return sum((p - o) * a for p, o, a in zip(point, origin, axis, strict=True)) / norm


def clamp_distance(distance_m: float) -> float:
    """A focus distance inside the wire range, so STATUS can still report it."""
    return min(max(distance_m, DISTANCE_M[0]), DISTANCE_M[1])


def smoothstep(t: float) -> float:
    """3t² − 2t³ on [0, 1], clamped outside it."""
    t = min(max(t, 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


class FocusRack:
    """A running A/B rack from `start_m` to `end_m`, started at `started_at` (seconds)."""

    def __init__(self, target: int, start_m: float, end_m: float, duration_s: float, started_at: float) -> None:
        self.target = target
        self.start_m = start_m
        self.end_m = end_m
        self.duration_s = duration_s
        self.started_at = started_at

    def progress(self, now: float) -> float:
        if self.duration_s <= 0.0:
            return 1.0
        return min(max((now - self.started_at) / self.duration_s, 0.0), 1.0)

    def value(self, now: float) -> float:
        """The focus distance at `now`; exactly `end_m` once the duration has passed."""
        t = self.progress(now)
        if t >= 1.0:
            return self.end_m
        return self.start_m + (self.end_m - self.start_m) * smoothstep(t)

    def finished(self, now: float) -> bool:
        return self.progress(now) >= 1.0


def _number(value: Any) -> bool:
    return isinstance(value, float | int) and not isinstance(value, bool)


def _valid_request(key: str, value: Any) -> bool:
    if key == "dof_on":
        return isinstance(value, bool)
    return _number(value) and _within(value, REQUEST_RANGES[key])


def _valid_seq(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= SEQ_MAX


def _group(control: Mapping[str, Any], keys: tuple[str, ...]) -> dict[str, Any] | None:
    """The request group if its sequence key (the last) is present; its other keys must be too."""
    if control.get(keys[-1]) is None:
        return None
    return {key: control.get(key) for key in keys}


def _valid_tap(tap: dict[str, Any] | None) -> bool:
    if tap is None:
        return True
    point = (tap["tap_u"], tap["tap_v"])
    return _valid_seq(tap["tap_seq"]) and all(_number(c) and _within(c, (0.0, 1.0)) for c in point)


def _valid_rack(rack: dict[str, Any] | None) -> bool:
    if rack is None:
        return True
    marks = (rack["rack_a_m"], rack["rack_b_m"])
    duration = rack["rack_duration_ms"]
    return (
        _valid_seq(rack["rack_seq"])
        and all(_number(m) and _within(m, DISTANCE_M) for m in marks)
        and rack["rack_target"] in (RACK_NONE, RACK_A, RACK_B)
        and _valid_seq(duration)
        and RACK_DURATION_MS[0] <= duration <= RACK_DURATION_MS[1]
    )


class LensControls:
    """The device's merged lens request of one session, and the changes not yet on the camera.

    `tap_seq`/`rack_seq` are the session's last seen request identities (None before the
    baseline); `tap`/`rack` hold a new request until the host carries it out.
    """

    def __init__(self) -> None:
        self.requested: Lens = {}
        self.pending: Lens = {}
        self.tap_seq: int | None = None
        self.rack_seq: int | None = None
        self.tap: Tap | None = None
        self.rack: Rack | None = None

    def merge(self, control: Mapping[str, Any]) -> bool:
        """Merges the lens keys of an accepted `latest_control()` dict; True if a request changed."""
        present = {key: control[key] for key in REQUEST_KEYS if control.get(key) is not None}
        tap, rack = _group(control, TAP_KEYS), _group(control, RACK_KEYS)
        if not all(_valid_request(key, value) for key, value in present.items()):
            return False
        if not (_valid_tap(tap) and _valid_rack(rack)):
            return False
        changed = {key: value for key, value in present.items() if self.requested.get(key) != value}
        self.requested.update(changed)
        self.pending.update(changed)
        started = False
        if tap is not None:
            if self.tap_seq is not None and tap["tap_seq"] != self.tap_seq:
                self.tap = (tap["tap_u"], tap["tap_v"])
                started = True
            self.tap_seq = tap["tap_seq"]
        if rack is not None:
            target = rack["rack_target"]
            if self.rack_seq is not None and rack["rack_seq"] != self.rack_seq and target != RACK_NONE:
                mark = rack["rack_a_m"] if target == RACK_A else rack["rack_b_m"]
                self.rack = (target, mark, rack["rack_duration_ms"] / 1000.0)
                started = True
            self.rack_seq = rack["rack_seq"]
        if started:
            self.requested.pop("focus_distance_m", None)
        return bool(changed) or started

    def waiting(self) -> bool:
        """True while a request still has to reach the camera."""
        return bool(self.pending) or self.tap is not None or self.rack is not None

    def take(self) -> Lens:
        """The changed requests to write to the camera, once."""
        pending, self.pending = self.pending, {}
        return pending

    def take_tap(self) -> Tap | None:
        """The new tap to carry out, once."""
        tap, self.tap = self.tap, None
        return tap

    def take_rack(self) -> Rack | None:
        """The new rack to start, once."""
        rack, self.rack = self.rack, None
        return rack
