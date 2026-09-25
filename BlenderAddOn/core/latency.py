# SPDX-License-Identifier: GPL-3.0-or-later
"""Pose-leg latency log (task 1.5.1; NFR-LAT-001). Pure Python, tested outside Blender.

For every newly applied pose the session poll records two host-side legs:

- `pose_leg`: host clock right after the apply minus the capture time mapped onto the host clock
  through the `CLOCK` offset (`status.pose_latency_ms`). That is ARFrame capture → pose applied
  to the Blender camera, including the network and the wait in the latest-sample slot.
- `apply`: main-thread cost of the apply step (`Applier.tick`).

`report()` gives p50/p95/p99, fixed-bin histograms and the NFR-LAT-001 verdict as a JSON-ready
dict; the save operator writes it as `latency-<date>.json` (the NFR-LAT-004 artefact name).
"""

from __future__ import annotations

import math
from collections import deque

# Histogram: 0.5 ms bins from 0 to 100 ms; values outside count as underflow/overflow.
BIN_MS = 0.5
BIN_COUNT = 200
# Samples kept per leg: 10 minutes at 60 Hz. The oldest are dropped first.
MAX_SAMPLES = 36_000
# NFR-LAT-001: pose leg p95 ≤ 20 ms on 5 GHz Wi-Fi; main-thread apply cost ≤ 1 ms (every apply).
POSE_LEG_P95_LIMIT_MS = 20.0
APPLY_LIMIT_MS = 1.0


def percentile(ordered: list[float], q: float) -> float:
    """Nearest-rank percentile of an ascending, non-empty list (q in (0, 100])."""
    rank = max(1, math.ceil(q / 100.0 * len(ordered)))
    return ordered[rank - 1]


def summarize(values) -> dict | None:
    """count/min/mean/p50/p95/p99/max in ms plus the fixed-bin histogram; None if empty."""
    ordered = sorted(values)
    if not ordered:
        return None
    counts = [0] * BIN_COUNT
    underflow = overflow = 0
    for v in ordered:
        if v < 0.0:
            underflow += 1
            continue
        i = int(v // BIN_MS)
        if i < BIN_COUNT:
            counts[i] += 1
        else:
            overflow += 1
    return {
        "count": len(ordered),
        "min": ordered[0],
        "mean": sum(ordered) / len(ordered),
        "p50": percentile(ordered, 50),
        "p95": percentile(ordered, 95),
        "p99": percentile(ordered, 99),
        "max": ordered[-1],
        "histogram": {"bin_ms": BIN_MS, "counts": counts, "underflow": underflow, "overflow": overflow},
    }


class LatencyLog:
    """Samples of one device session. A new `session_id` starts a fresh log."""

    def __init__(self, max_samples: int = MAX_SAMPLES) -> None:
        self.session_id: int | None = None
        self.last_seq: int | None = None
        self.pose_leg_ms: deque[float] = deque(maxlen=max_samples)
        self.apply_ms: deque[float] = deque(maxlen=max_samples)
        # Applied before the first CLOCK estimate: apply cost known, pose leg not.
        self.without_clock = 0
        # Seq gaps between applied poses: lost on the network, or superseded in the
        # latest-sample slot before a poll applied them (NET-002: the newest pose wins).
        self.not_applied = 0

    def record(self, session_id: int | None, seq: int, apply_ms: float, pose_leg_ms: float | None) -> bool:
        """Adds one applied pose; a re-apply of the same `seq` is not a new sample."""
        if session_id != self.session_id:
            self.__init__(self.pose_leg_ms.maxlen or MAX_SAMPLES)
            self.session_id = session_id
        if seq == self.last_seq:
            return False
        if self.last_seq is not None and seq > self.last_seq:
            self.not_applied += seq - self.last_seq - 1
        self.last_seq = seq
        self.apply_ms.append(apply_ms)
        if pose_leg_ms is None:
            self.without_clock += 1
        else:
            self.pose_leg_ms.append(pose_leg_ms)
        return True

    def report(self, **meta) -> dict:
        """The report artefact: `meta` (date, platform, device, clock, …) plus both legs."""
        pose_leg, apply = summarize(self.pose_leg_ms), summarize(self.apply_ms)
        return {
            "kind": "vcam-latency",
            "format": 1,
            **meta,
            "session_id": self.session_id,
            "poses_without_clock": self.without_clock,
            "poses_not_applied": self.not_applied,
            "legs": {"pose_leg_ms": pose_leg, "apply_ms": apply},
            "limits": {"pose_leg_p95_ms": POSE_LEG_P95_LIMIT_MS, "apply_max_ms": APPLY_LIMIT_MS},
            "meets": {
                "pose_leg_p95": None if pose_leg is None else pose_leg["p95"] <= POSE_LEG_P95_LIMIT_MS,
                "apply_max": None if apply is None else apply["max"] <= APPLY_LIMIT_MS,
            },
        }

    def summary_line(self) -> str:
        """One console line: counts and the p50/p95/p99 of both legs."""
        parts = [f"session={self.session_id}"]
        for name, values in (("pose_leg", self.pose_leg_ms), ("apply", self.apply_ms)):
            s = summarize(values)
            if s is None:
                parts.append(f"{name}=none")
            else:
                parts.append(f"{name}_ms n={s['count']} p50={s['p50']:.2f} p95={s['p95']:.2f} "
                             f"p99={s['p99']:.2f} max={s['max']:.2f}")
        return " ".join(parts)
