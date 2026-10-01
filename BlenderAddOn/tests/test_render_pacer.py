# SPDX-License-Identifier: GPL-3.0-or-later
"""The stream skips GPU work when draw or readback exhausts the main-thread budget."""

import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import render as stream_render  # noqa: E402
from core.lens import render_aspect  # noqa: E402
from core.render import (  # noqa: E402
    STREAM_RESOLUTIONS,
    FramePacer,
    adapted_resolution,
    fit_aspect,
    resolution_steps,
    thermal_stream_settings,
)

SCOPE = render_aspect(2048, 858, 1.0, 1.0)  # 2.39:1

TICK = 1_000_000_000 // 30


def test_draw_and_readback_cost_reduce_rate_and_recover():
    pacer = FramePacer()
    now = 5_000_000_000
    assert pacer.due(now, 12, 30)
    pacer.record(now, 2_000_000, 3_000_000)
    assert not pacer.due(now + TICK - 1, 12, 30)
    assert pacer.due(now + TICK, 12, 30)

    now += TICK
    pacer.record(now, 28_000_000, 2_000_000)  # a GPU-stalled readback
    assert not pacer.due(now + 2 * TICK, 12, 30)
    assert pacer.due(now + 3 * TICK, 12, 30)

    now += 3 * TICK
    pacer.record(now, 1_000_000, 1_000_000)
    assert not pacer.due(now + TICK, 12, 30)  # slow recovery prevents oscillation
    assert pacer.due(now + 2 * TICK, 12, 30)
    for _ in range(4):
        now = pacer.next_due_ns
        pacer.record(now, 1_000_000, 1_000_000)
    assert pacer.next_due_ns == now + TICK


def test_slow_draw_skips_without_catchup_and_budget_change_is_immediate():
    pacer = FramePacer()
    now = 1_000_000_000
    pacer.record(now, 0, 48_000_000)
    assert not pacer.due(now + 3 * TICK, 12, 30)
    assert pacer.due(now + 4 * TICK, 12, 30)

    late = now + 20 * TICK
    assert pacer.due(late, 12, 30)
    pacer.record(late, 0, 900_000_000)
    assert pacer.next_due_ns == late + 30 * TICK  # at most one second of skipping
    assert pacer.due(late + TICK, 24, 30)  # operator raised the budget; no stale wait
    pacer.record(late + TICK, 0, 1_000_000)
    assert not pacer.due(late + TICK + 1, 24, 30)  # no catch-up burst


def test_fps_cap_and_switch_under_load():
    now = 5_000_000_000
    for fps in (24, 30, 60):
        pacer = FramePacer()
        period = 1_000_000_000 // fps
        assert pacer.due(now, 12, fps)
        pacer.record(now, 0, 2_000_000)
        assert not pacer.due(now + period - 1, 12, fps)
        assert pacer.due(now + period, 12, fps)
        pacer.record(now + period, 30_000_000, 0)
        skipped = (30_000_000 + 12_000_000 - 1) // 12_000_000
        assert pacer.next_due_ns == now + period * (skipped + 1)
        pacer.record(now, 900_000_000, 0)
        assert pacer.next_due_ns == now + fps * period  # skip no more than one second

    pacer = FramePacer()
    assert pacer.due(now, 12, 30)
    pacer.record(now, 900_000_000, 0)
    assert pacer.due(now + 1, 12, 60)  # changed cap cancels the old one-second skip
    pacer.record(now + 1, 0, 2_000_000)
    assert pacer.next_due_ns > now + 1


def test_resolution_steps_go_down_the_stream_sizes_and_stop_at_the_smallest():
    assert [resolution_steps(k) for k in ('360p', '540p', '720p', '1080p')] == [0, 1, 2, 3]
    assert [adapted_resolution('1080p', d) for d in range(4)] == [(1920, 1080), (1280, 720), (960, 540), (640, 360)]
    # A drop left over from a larger user size (the adapter is capped straight after) never
    # goes below the list.
    assert adapted_resolution('540p', 3) == (640, 360)


@pytest.mark.parametrize(
    ("thermal", "expected"),
    [
        (None, ((960, 540), 30)),
        (0, ((960, 540), 30)),
        (1, ((960, 540), 30)),
        (2, ((640, 360), 24)),
        (3, ((640, 360), 24)),
    ],
)
def test_thermal_serious_steps_once_and_caps_fps(thermal, expected):
    assert thermal_stream_settings('540p', 30, 0, thermal) == expected
    assert thermal_stream_settings('720p', 60, 0, thermal) == (
        ((960, 540), 24) if thermal is not None and thermal >= 2 else ((1280, 720), 60)
    )


def test_thermal_stacks_with_adaptive_drop_floors_and_restores():
    assert thermal_stream_settings('1080p', 60, 1, 2) == ((960, 540), 24)
    assert thermal_stream_settings('540p', 60, 1, 3) == ((640, 360), 24)
    assert thermal_stream_settings('360p', 30, 1, 2) == ((640, 360), 24)
    assert thermal_stream_settings('1080p', 60, 1, 1) == ((1280, 720), 60)
    assert thermal_stream_settings('540p', 24, 0, 2) == ((640, 360), 24)


@pytest.mark.parametrize(
    ("render", "box", "expected"),
    [
        ((1920, 1080, 1.0, 1.0), (960, 540), (960, 540)),
        ((2048, 858, 1.0, 1.0), (960, 540), (960, 402)),  # 2.39: 402.19 → 402
        ((1080, 1920, 1.0, 1.0), (960, 540), (304, 540)),  # portrait: 303.75 → 304
        ((1440, 1080, 1.0, 1.0), (960, 540), (720, 540)),  # 4:3
        ((1440, 1080, 1.0, 1.0), (1920, 1080), (1440, 1080)),
        ((1440, 1080, 4.0, 3.0), (960, 540), (960, 540)),  # anamorphic pixels: 16:9 picture
        ((1000, 1000, 1.0, 1.0), (640, 360), (360, 360)),
        ((1001, 1000, 1.0, 1.0), (640, 360), (360, 360)),  # 360.36 → 360
        ((1000, 999, 1.0, 1.0), (640, 360), (360, 360)),
        ((1920, 817, 1.0, 1.0), (1280, 720), (1280, 544)),  # 544.69 → 544
        ((2048, 858, 1.0, 1.0), (640, 360), (640, 268)),
        ((2000, 200, 1.0, 1.0), (640, 360), (640, 64)),  # 10:1
        ((100, 1000, 1.0, 1.0), (640, 360), (36, 360)),  # 1:10
        ((1000, 1000, 1.0, 2.0), (640, 360), (180, 360)),  # pixel aspect y halves the width
    ],
)
def test_stream_frame_is_the_render_aspect_with_even_sides_inside_the_box(render, box, expected):
    aspect = render_aspect(*render)
    size = fit_aspect(box, aspect)
    assert size == expected
    width, height = size
    assert width % 2 == 0 and height % 2 == 0
    assert width <= box[0] and height <= box[1]
    assert width == box[0] or height == box[1], "the frame fills the box on one side"
    # Nearest even sides: within one pixel pair of the exact aspect on the rounded side.
    assert abs(width - height * aspect) <= 2 or abs(height - width / aspect) <= 2


def test_every_box_and_any_aspect_gives_even_sides_inside_the_box():
    for box in STREAM_RESOLUTIONS.values():
        for n in range(1, 400):
            aspect = 0.1 + n * 0.025  # 0.125 … 10.075
            width, height = fit_aspect(box, aspect)
            assert width % 2 == 0 and height % 2 == 0, (box, aspect)
            assert 2 <= width <= box[0] and 2 <= height <= box[1], (box, aspect)


def test_adaptive_steps_keep_the_render_aspect_through_the_boxes():
    assert adapted_resolution('540p', 0, SCOPE) == (960, 402)
    assert [adapted_resolution('1080p', d, SCOPE) for d in range(4)] == [
        (1920, 804),
        (1280, 536),
        (960, 402),
        (640, 268),
    ]
    assert adapted_resolution('540p', 3, SCOPE) == (640, 268)
    assert adapted_resolution('540p', 0, 9 / 16) == (304, 540)
    assert adapted_resolution('540p', 1, 9 / 16) == (202, 360)
    assert adapted_resolution('540p', 1) == (640, 360), "no aspect: the box itself"


@pytest.mark.parametrize(
    ("key", "drop", "thermal", "expected"),
    [
        ('540p', 0, 0, ((960, 402), 30)),
        ('540p', 0, 2, ((640, 268), 24)),
        ('540p', 1, 2, ((640, 268), 24)),
        ('1080p', 0, 3, ((1280, 536), 24)),
        ('1080p', 1, 2, ((960, 402), 24)),
        ('720p', 1, None, ((960, 402), 30)),
    ],
)
def test_thermal_step_keeps_the_render_aspect(key, drop, thermal, expected):
    assert thermal_stream_settings(key, 30, drop, thermal, SCOPE) == expected


class FakeOffScreen:
    def __init__(self, width, height, format):
        self.texture_color = types.SimpleNamespace(read=lambda: b"pixels")

    def free(self):
        pass


def test_render_readback_leg_is_the_submitted_frames_own_draw_plus_read(monkeypatch):
    """NFR-LAT-004: pipelined, a frame is drawn on one tick and read on the next; its leg adds both."""
    fake_gpu = types.SimpleNamespace(types=types.SimpleNamespace(GPUOffScreen=FakeOffScreen))
    monkeypatch.setitem(sys.modules, "gpu", fake_gpu)
    # perf_counter_ns readings in call order: draw 1 (4 ms); read 1 (1 ms), draw 2 (6 ms); read 2 (2 ms).
    clock = iter([0, 4_000_000, 10_000_000, 11_000_000, 11_000_000, 17_000_000, 20_000_000, 22_000_000])
    monkeypatch.setattr(stream_render.time, "perf_counter_ns", lambda: next(clock))
    slot = types.SimpleNamespace(submit=lambda pixels, seq, drawn_ns: seq * 10)
    renderer = stream_render.StreamRenderer(slot)
    monkeypatch.setattr(renderer, "_draw", lambda *args: None)
    camera = object()
    assert renderer.tick(None, None, None, camera, 1, 100) is None
    assert renderer.frame_render_ns is None  # drawn, nothing submitted yet
    assert renderer.tick(None, None, None, camera, 2, 200) == 10
    assert renderer.frame_render_ns == 4_000_000 + 1_000_000
    assert (renderer.draw_ns, renderer.read_ns) == (6_000_000, 1_000_000)  # this tick's cost, for the pacer
    assert renderer.tick(None, None, None, None, 0, 300) == 20
    assert renderer.frame_render_ns == 6_000_000 + 2_000_000
    assert renderer.tick(None, None, None, None, 0, 400) is None and renderer.frame_render_ns is None
