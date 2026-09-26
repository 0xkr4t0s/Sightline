# SPDX-License-Identifier: GPL-3.0-or-later
"""The stream skips GPU work when draw or readback exhausts the main-thread budget."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.render import FramePacer, adapted_resolution, resolution_steps  # noqa: E402

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
    assert [adapted_resolution('1080p', d) for d in range(4)] == [
        (1920, 1080), (1280, 720), (960, 540), (640, 360)]
    # A drop left over from a larger user size (the adapter is capped straight after) never
    # goes below the list.
    assert adapted_resolution('540p', 3) == (640, 360)
