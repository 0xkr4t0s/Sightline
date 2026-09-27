# SPDX-License-Identifier: GPL-3.0-or-later
"""Tap-to-focus rays, the A/B rack and their request identities (task 2.4; FR-CTL-002, vcp.md §6.2).

Pure maths from `core/lens.py`; the Applier's tap/rack rules with a stand-in camera (the ray cast
itself is replaced, the Blender side is `tests/blender/addon_focus.py`).
"""

import math
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import apply  # noqa: E402
from core.lens import (  # noqa: E402
    RACK_A,
    RACK_B,
    RACK_NONE,
    FocusRack,
    LensControls,
    axial_distance,
    clamp_distance,
    frame_point,
    smoothstep,
    tap_ray,
)
from core.status import focus_labels  # noqa: E402

# `Camera.view_frame(scene=…)` of the factory camera (50 mm, 36 mm sensor, 1920×1080), verified in
# Blender 5.2.2: top right, bottom right, bottom left, top left.
DEPTH = 50 / 36
FRAME = ((0.5, 0.28125, -DEPTH), (0.5, -0.28125, -DEPTH), (-0.5, -0.28125, -DEPTH), (-0.5, 0.28125, -DEPTH))
# The same camera with shift_x 0.1 (also verified): the picture is off the view axis.
SHIFTED = ((0.6, 0.28125, -DEPTH), (0.6, -0.28125, -DEPTH), (-0.4, -0.28125, -DEPTH), (-0.4, 0.28125, -DEPTH))


def close(a: tuple[float, ...], b: tuple[float, ...]) -> bool:
    return all(x == pytest.approx(y, abs=1e-9) for x, y in zip(a, b, strict=True))


def test_frame_point_measures_u_from_the_left_and_v_from_the_top() -> None:
    assert close(frame_point(FRAME, 0.0, 0.0), (-0.5, 0.28125, -DEPTH))  # top left
    assert close(frame_point(FRAME, 1.0, 0.0), (0.5, 0.28125, -DEPTH))
    assert close(frame_point(FRAME, 1.0, 1.0), (0.5, -0.28125, -DEPTH))  # bottom right
    assert close(frame_point(FRAME, 0.5, 0.5), (0.0, 0.0, -DEPTH))
    # v = 0.25 is above the centre (+y), v = 0.75 below it.
    assert close(frame_point(FRAME, 0.75, 0.25), (0.25, 0.140625, -DEPTH))
    assert close(frame_point(FRAME, 0.25, 0.75), (-0.25, -0.140625, -DEPTH))
    assert close(frame_point(SHIFTED, 0.5, 0.5), (0.1, 0.0, -DEPTH))


def test_perspective_ray_runs_from_the_near_to_the_far_clip_plane() -> None:
    start, direction, length = tap_ray(FRAME, 0.75, 0.25, 0.1, 100.0)
    assert math.hypot(*direction) == pytest.approx(1.0)
    point = frame_point(FRAME, 0.75, 0.25)
    assert close(tuple(d / direction[2] for d in direction), tuple(p / point[2] for p in point))  # through the point
    assert start[2] == pytest.approx(-0.1)
    end = tuple(s + d * length for s, d in zip(start, direction, strict=True))
    assert end[2] == pytest.approx(-100.0)
    centre_start, centre_direction, centre_length = tap_ray(FRAME, 0.5, 0.5, 0.1, 100.0)
    assert close(centre_direction, (0.0, 0.0, -1.0)) and close(centre_start, (0.0, 0.0, -0.1))
    assert centre_length == pytest.approx(99.9)


def test_orthographic_ray_is_parallel_to_the_view_axis() -> None:
    corners = ((3.0, 1.6875, -1.0), (3.0, -1.6875, -1.0), (-3.0, -1.6875, -1.0), (-3.0, 1.6875, -1.0))
    start, direction, length = tap_ray(corners, 0.75, 0.25, 0.1, 100.0, orthographic=True)
    assert close(start, (1.5, 0.84375, -0.1)) and direction == (0.0, 0.0, -1.0)
    assert length == pytest.approx(99.9)


def test_focus_distance_is_along_the_view_axis_not_euclidean() -> None:
    assert axial_distance((0.0, 0.0, 0.0), (0.0, 0.0, -2.0), (3.0, 4.0, -10.0)) == pytest.approx(10.0)
    # A camera at (0, 0, 1.6) looking along +Y; a hit 4.6 m deep through (0.75, 0.25): 4.70 m away.
    _, (x, y, z), _ = tap_ray(FRAME, 0.75, 0.25, 0.1, 100.0)
    scale = 4.6 / -z
    hit = (x * scale, 4.6, 1.6 + y * scale)  # camera-local (x, y, z) → world (x, −z, y)
    assert axial_distance((0.0, 0.0, 1.6), (0.0, 1.0, 0.0), hit) == pytest.approx(4.6)
    assert math.dist((0.0, 0.0, 1.6), hit) == pytest.approx(4.697, abs=1e-3)


def test_clamp_distance_keeps_the_wire_range() -> None:
    assert clamp_distance(0.001) == 0.01
    assert clamp_distance(3.5) == 3.5
    assert clamp_distance(1e9) == 100_000.0


def test_smoothstep_eases_in_and_out_and_clamps() -> None:
    assert [smoothstep(t) for t in (-1.0, 0.0, 0.25, 0.5, 0.75, 1.0, 2.0)] == pytest.approx(
        [0.0, 0.0, 0.15625, 0.5, 0.84375, 1.0, 1.0]
    )


def test_rack_moves_monotonically_from_the_start_to_the_mark_over_its_duration() -> None:
    rack = FocusRack(RACK_B, 1.0, 6.0, 2.0, started_at=10.0)
    assert rack.value(10.0) == 1.0 and not rack.finished(10.0)
    assert rack.value(11.0) == pytest.approx(3.5)  # half way at t = 0.5
    assert rack.value(10.5) == pytest.approx(1.0 + 5.0 * 0.15625)
    assert rack.value(12.0) == 6.0 and rack.finished(12.0)
    assert rack.value(20.0) == 6.0
    samples = [rack.value(10.0 + i * 0.05) for i in range(45)]
    assert all(b >= a for a, b in zip(samples, samples[1:], strict=False)) and samples[-1] == 6.0
    assert len(set(samples)) > 30  # moves, doesn't jump
    back = FocusRack(RACK_A, 6.0, 2.0, 1.0, started_at=0.0)
    assert back.value(0.5) == pytest.approx(4.0) and back.value(1.0) == 2.0


def test_zero_duration_rack_jumps_to_the_mark() -> None:
    rack = FocusRack(RACK_A, 5.0, 2.0, 0.0, started_at=3.0)
    assert rack.value(3.0) == 2.0 and rack.finished(3.0)


def control(**fields: Any) -> dict[str, Any]:
    keys = (
        "lens_mm",
        "focus_distance_m",
        "fstop",
        "dof_on",
        "tap_u",
        "tap_v",
        "tap_seq",
        "rack_a_m",
        "rack_b_m",
        "rack_target",
        "rack_duration_ms",
        "rack_seq",
    )
    return {key: fields.get(key) for key in keys}


def tap(u: float, v: float, seq: int) -> dict[str, Any]:
    return {"tap_u": u, "tap_v": v, "tap_seq": seq}


def rack(a: float, b: float, target: int, ms: int, seq: int) -> dict[str, Any]:
    return {"rack_a_m": a, "rack_b_m": b, "rack_target": target, "rack_duration_ms": ms, "rack_seq": seq}


def test_first_tap_seq_is_a_baseline_and_each_change_starts_one_tap() -> None:
    lens = LensControls()
    assert not lens.merge(control(**tap(0.5, 0.5, 7)))
    assert lens.take_tap() is None and not lens.waiting()
    assert lens.merge(control(**tap(0.25, 0.75, 8)))
    assert lens.waiting() and lens.take_tap() == (0.25, 0.75)
    assert lens.take_tap() is None
    # A resend of the same tap_seq (in a newer state) never repeats the tap.
    assert not lens.merge(control(**tap(0.25, 0.75, 8)))
    assert not lens.merge(control(**tap(0.9, 0.1, 8)))
    assert lens.take_tap() is None
    # Wrap-around is a change like any other.
    lens.tap_seq = 65535
    assert lens.merge(control(**tap(0.1, 0.2, 0)))
    assert lens.take_tap() == (0.1, 0.2)


def test_first_rack_seq_is_a_baseline_and_each_change_starts_one_rack() -> None:
    lens = LensControls()
    assert not lens.merge(control(**rack(1.0, 6.0, RACK_B, 2000, 0)))  # baseline, even with a target
    assert lens.take_rack() is None
    assert lens.merge(control(**rack(1.0, 6.0, RACK_B, 2000, 1)))
    assert lens.take_rack() == (RACK_B, 6.0, 2.0)
    assert not lens.merge(control(**rack(1.0, 6.0, RACK_B, 2000, 1)))  # same rack_seq resent
    assert lens.take_rack() is None
    assert lens.merge(control(**rack(1.5, 6.0, RACK_A, 0, 2)))
    assert lens.take_rack() == (RACK_A, 1.5, 0.0)
    # A new rack_seq without a target starts nothing, but is the new identity.
    assert not lens.merge(control(**rack(1.5, 6.0, RACK_NONE, 500, 3)))
    assert lens.take_rack() is None and lens.rack_seq == 3


def test_absent_groups_keep_the_request_identities() -> None:
    lens = LensControls()
    lens.merge(control(**tap(0.5, 0.5, 1), **rack(1.0, 2.0, RACK_A, 100, 4)))
    assert not lens.merge(control(focus_distance_m=None))
    assert (lens.tap_seq, lens.rack_seq) == (1, 4)
    assert lens.merge(control(**tap(0.5, 0.5, 2)))
    assert lens.take_tap() == (0.5, 0.5) and lens.rack_seq == 4


@pytest.mark.parametrize(
    "bad",
    [
        tap(1.5, 0.5, 2),
        tap(0.5, math.nan, 2),
        tap(0.5, -0.1, 2),
        tap(0.5, 0.5, 70_000),
        {**tap(0.5, 0.5, 2), "tap_u": None},
        rack(0.0, 6.0, RACK_B, 2000, 2),
        rack(1.0, math.inf, RACK_B, 2000, 2),
        rack(1.0, 6.0, 3, 2000, 2),
        rack(1.0, 6.0, RACK_B, 60_001, 2),
        rack(1.0, 6.0, RACK_B, -1, 2),
        rack(1.0, 6.0, RACK_B, 2000, -1),
    ],
)
def test_an_invalid_tap_or_rack_drops_the_whole_lens_part(bad: dict[str, Any]) -> None:
    lens = LensControls()
    lens.merge(control(**tap(0.5, 0.5, 1), **rack(1.0, 6.0, RACK_NONE, 2000, 1)))
    assert not lens.merge(control(focus_distance_m=3.0, **bad))
    assert not lens.waiting() and lens.requested == {}
    assert (lens.tap_seq, lens.rack_seq) == (1, 1)


def test_focus_labels_report_a_hit_a_miss_and_a_running_rack() -> None:
    assert focus_labels(None, None) == []
    assert focus_labels((1.3, "QA Totem 2"), None) == ["Tap focus: 1.30 m (QA Totem 2)"]
    assert focus_labels((None, None), FocusRack(RACK_B, 1.0, 6.0, 2.0, 0.0)) == [
        "Tap focus: nothing hit, focus kept",
        "Rack to B: 6.00 m over 2.0 s",
    ]


# -- the Applier's rules, with a stand-in camera ---------------------------------------------------


class Scene:
    def __init__(self, camera: Any) -> None:
        self.camera = camera
        self.objects = {camera.name: camera}
        self.render = SimpleNamespace(resolution_x=1920, resolution_y=1080, pixel_aspect_x=1.0, pixel_aspect_y=1.0)


class Session:
    def __init__(self) -> None:
        self.control: dict[str, Any] | None = None
        self.status: list[dict[str, Any]] = []

    def latest_pose(self) -> None:
        return None

    def latest_control(self) -> dict[str, Any] | None:
        return self.control

    def update_status(self, *_args: Any, **lens: Any) -> None:
        self.status.append(lens)


class Host:
    """An Applier on a stand-in camera; `taps` answers ray casts in order (None = miss)."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch, taps: list[float | None] | None = None) -> None:
        dof = SimpleNamespace(focus_distance=3.0, use_dof=False, aperture_fstop=2.8)
        data = SimpleNamespace(lens=24.0, sensor_width=36.0, sensor_fit="AUTO", dof=dof)
        self.camera = SimpleNamespace(name="Camera", type="CAMERA", data=data)
        self.scene = Scene(self.camera)
        self.session = Session()
        self.applier = apply.Applier()
        self.state_seq = 0
        self.casts: list[tuple[float, float]] = []
        self.log: list[str] = []
        answers = list(taps or [])
        log = SimpleNamespace(info=lambda message, *args: self.log.append(message % args))
        monkeypatch.setattr(apply, "_log", log)

        def tap_hit(_scene: Any, _camera: Any, u: float, v: float) -> tuple[float, str] | None:
            self.casts.append((u, v))
            distance = answers.pop(0)
            return None if distance is None else (distance, "Thing")

        monkeypatch.setattr(apply, "tap_hit", tap_hit)

    @property
    def focus(self) -> float:
        return float(self.camera.data.dof.focus_distance)

    def send(self, now: float, **fields: Any) -> None:
        self.state_seq += 1
        self.session.control = {
            "state_seq": self.state_seq,
            "motion_scale": None,
            "lock_flags": None,
            "origin_epoch": None,
            **control(**fields),
        }
        self.tick(now)

    def tick(self, now: float) -> None:
        self.applier.tick(self.session, 1, self.scene, now)


BASE = {**tap(0.5, 0.5, 0), **rack(1.0, 6.0, RACK_NONE, 2000, 0)}


def test_tap_sets_focus_on_a_hit_and_keeps_it_on_a_miss(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch, [1.3, None])
    host.send(0.0, focus_distance_m=3.0, dof_on=False, **BASE)
    assert host.casts == [] and host.focus == 3.0  # the baseline tap_seq isn't replayed
    host.send(0.1, focus_distance_m=3.0, dof_on=False, **{**BASE, **tap(0.5, 0.5, 1)})
    assert host.focus == 1.3 and host.applier.last_tap == (1.3, "Thing")
    assert host.camera.data.dof.use_dof is False  # a tap never turns DoF on
    host.send(0.2, focus_distance_m=3.0, dof_on=False, **{**BASE, **tap(0.05, 0.95, 2)})
    assert host.focus == 1.3 and host.applier.last_tap == (None, None)
    assert host.log[-1] == "tap focus u=0.050 v=0.950: nothing hit, focus kept at 1.300 m"
    assert host.casts == [(0.5, 0.5), (0.05, 0.95)]
    # The same tap_seq again (a newer state_seq, the camera moved or not): no new ray cast.
    host.send(0.3, focus_distance_m=3.0, dof_on=False, **{**BASE, **tap(0.05, 0.95, 2)})
    assert host.casts == [(0.5, 0.5), (0.05, 0.95)] and host.focus == 1.3


def test_tap_keeps_dof_on_when_the_device_has_it_on(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch, [4.6])
    host.send(0.0, dof_on=True, **BASE)
    host.send(0.1, dof_on=True, **{**BASE, **tap(0.75, 0.25, 1)})
    assert host.focus == 4.6 and host.camera.data.dof.use_dof is True


def test_rack_runs_once_over_its_duration_and_ignores_resends(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch)
    host.send(0.0, focus_distance_m=1.0, **BASE)
    assert host.focus == 1.0
    host.send(1.0, focus_distance_m=1.0, **{**BASE, **rack(1.0, 6.0, RACK_B, 2000, 1)})
    assert host.focus == 1.0 and host.applier.rack is not None
    samples = []
    for i in range(1, 25):
        now = 1.0 + i * 0.1
        if i % 5 == 0:  # the device's 500 ms resend (same state_seq), and a newer state repeating it
            host.session.control = dict(host.session.control or {})
            host.tick(now)
            host.send(now, focus_distance_m=1.0, **{**BASE, **rack(1.0, 6.0, RACK_B, 2000, 1)})
        else:
            host.tick(now)
        samples.append(host.focus)
    assert samples[9] == pytest.approx(3.5)  # t = 1 s of 2 s
    assert all(b >= a for a, b in zip(samples, samples[1:], strict=False)), samples
    assert samples[-1] == 6.0 and host.applier.rack is None
    assert len(set(samples)) > 15
    assert host.session.status[-1]["focus_distance_m"] == 6.0  # STATUS reports the rack's value


def test_manual_focus_or_a_tap_cancels_a_running_rack(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch, [2.2])
    host.send(0.0, focus_distance_m=1.0, **BASE)
    host.send(1.0, focus_distance_m=1.0, **{**BASE, **rack(1.0, 6.0, RACK_B, 2000, 1)})
    host.tick(1.5)
    assert 1.0 < host.focus < 6.0
    host.send(1.6, focus_distance_m=4.0, **{**BASE, **rack(1.0, 6.0, RACK_B, 2000, 1)})
    assert host.applier.rack is None and host.focus == 4.0
    assert host.log[-1] == "rack to B cancelled: manual focus", host.log
    for now in (2.0, 2.5, 4.0):
        host.tick(now)
    assert host.focus == 4.0
    # A new rack, then a tap.
    host.send(5.0, focus_distance_m=4.0, **{**BASE, **rack(1.0, 6.0, RACK_A, 2000, 2)})
    host.tick(5.5)
    assert 1.0 < host.focus < 4.0
    host.send(5.6, focus_distance_m=4.0, **{**BASE, **tap(0.5, 0.5, 1), **rack(1.0, 6.0, RACK_A, 2000, 2)})
    assert host.applier.rack is None and host.focus == 2.2
    assert host.log[-2:] == ["rack to A cancelled: tap", "tap focus u=0.500 v=0.500: hit 'Thing', focus 2.200 m"]
    host.tick(8.0)
    assert host.focus == 2.2


def test_a_focus_edit_in_blender_cancels_a_running_rack(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch)
    host.send(0.0, focus_distance_m=1.0, **BASE)
    host.send(1.0, focus_distance_m=1.0, **{**BASE, **rack(1.0, 6.0, RACK_B, 2000, 1)})
    host.tick(1.5)
    host.camera.data.dof.focus_distance = 9.0
    host.tick(1.6)
    assert host.applier.rack is None and host.focus == 9.0
    assert host.log[-1] == "rack to B cancelled: focus changed in Blender", host.log


def test_zero_duration_rack_jumps_in_one_tick(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch)
    host.send(0.0, focus_distance_m=5.0, **BASE)
    host.send(1.0, focus_distance_m=5.0, **{**BASE, **rack(1.5, 6.0, RACK_A, 0, 1)})
    assert host.focus == 1.5 and host.applier.rack is None


def test_requests_wait_for_a_camera(monkeypatch: pytest.MonkeyPatch) -> None:
    host = Host(monkeypatch, [2.5])
    host.send(0.0, **BASE)
    host.scene.camera, host.scene.objects = None, {}
    host.send(0.1, **{**BASE, **tap(0.5, 0.5, 1)})
    assert host.casts == [] and host.focus == 3.0
    host.scene.camera, host.scene.objects = host.camera, {host.camera.name: host.camera}
    host.tick(0.2)
    assert host.casts == [(0.5, 0.5)] and host.focus == 2.5
