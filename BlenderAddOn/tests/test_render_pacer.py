# SPDX-License-Identifier: GPL-3.0-or-later
"""The stream skips GPU work when draw or readback exhausts the main-thread budget."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.render import FramePacer  # noqa: E402

TICK = 1_000_000_000 // 30


def test_draw_and_readback_cost_reduce_rate_and_recover():
    pacer = FramePacer()
    now = 5_000_000_000
    assert pacer.due(now, 12)
    pacer.record(now, 2_000_000, 3_000_000)
    assert not pacer.due(now + TICK - 1, 12)
    assert pacer.due(now + TICK, 12)

    now += TICK
    pacer.record(now, 28_000_000, 2_000_000)  # a GPU-stalled readback
    assert not pacer.due(now + 2 * TICK, 12)
    assert pacer.due(now + 3 * TICK, 12)

    now += 3 * TICK
    pacer.record(now, 1_000_000, 1_000_000)
    assert not pacer.due(now + TICK, 12)  # slow recovery prevents oscillation
    assert pacer.due(now + 2 * TICK, 12)
    for _ in range(4):
        now = pacer.next_due_ns
        pacer.record(now, 1_000_000, 1_000_000)
    assert pacer.next_due_ns == now + TICK


def test_slow_draw_skips_without_catchup_and_budget_change_is_immediate():
    pacer = FramePacer()
    now = 1_000_000_000
    pacer.record(now, 0, 48_000_000)
    assert not pacer.due(now + 3 * TICK, 12)
    assert pacer.due(now + 4 * TICK, 12)

    late = now + 20 * TICK
    assert pacer.due(late, 12)
    pacer.record(late, 0, 900_000_000)
    assert pacer.next_due_ns == late + 30 * TICK  # at most one second of skipping
    assert pacer.due(late + TICK, 24)  # operator raised the budget; no stale wait
    pacer.record(late + TICK, 0, 1_000_000)
    assert not pacer.due(late + TICK + 1, 24)  # no catch-up burst
