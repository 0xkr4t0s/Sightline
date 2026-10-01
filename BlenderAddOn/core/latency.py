# SPDX-License-Identifier: GPL-3.0-or-later
"""Host latency log (tasks 1.5.1, 2.6; NFR-LAT-001, NFR-LAT-004). Pure Python, tested outside Blender.

For every newly applied pose the session poll records two host-side legs:

- `pose_leg`: host clock right after the apply minus the capture time mapped onto the host clock
  through the `CLOCK` offset (`status.pose_latency_ms`). That is ARFrame capture → pose applied
  to the Blender camera, including the network and the wait in the latest-sample slot.
- `apply`: main-thread cost of the apply step (`Applier.tick`).

For the viewfinder stream it records, per frame:

- `render_readback`: the main-thread draw of a frame plus its readback (texture read and
  `FrameSlot` copy) on the next tick (`StreamRenderer.frame_render_ns`).
- `encode` and `send`: the JPEG encode and the send of all its fragments, from
  `video_stats()["last_sent"]`. The poll sees only the newest sent frame, so frames sent between
  two polls aren't sampled; they're counted by their wire `frame_id` gap.
- the device's motion-to-photon p95 of each `VIDEO_REPORT` (vcp.md §6.6), one sample per report.

`report()` gives p50/p95/p99, fixed-bin histograms and the NFR-LAT-001 verdict as a JSON-ready
dict; the save operator writes it as `latency-<date>.json` (the NFR-LAT-004 artefact name).
"""

from __future__ import annotations

import math
from collections import deque
from collections.abc import Iterable, Mapping
from typing import Any

# Histogram: 0.5 ms bins from 0 to 100 ms; values outside count as underflow/overflow.
BIN_MS = 0.5
BIN_COUNT = 200
# Samples kept per leg: 10 minutes at 60 Hz. The oldest are dropped first.
MAX_SAMPLES = 36_000
# NFR-LAT-001: pose leg p95 ≤ 20 ms on 5 GHz Wi-Fi; main-thread apply cost ≤ 1 ms (every apply).
POSE_LEG_P95_LIMIT_MS = 20.0
APPLY_LIMIT_MS = 1.0
# NFR-LAT-003 Stage A: device motion-to-photon p95 ≤ 120 ms (the adapter's limit, vcam-net adapt.rs).
M2P_P95_LIMIT_MS = 120
# Report shape version: 2 added the stream legs, the device M2P and `methods`.
REPORT_FORMAT = 2
LEGS = ("pose_leg_ms", "apply_ms", "render_readback_ms", "encode_ms", "send_ms")
METHODS = {
    "pose_leg_ms": "host clock after the apply minus the device capture time mapped through the CLOCK offset",
    "apply_ms": "main-thread cost of applying the pose to the camera (perf_counter)",
    "render_readback_ms": "main-thread draw_view3d of a frame plus its texture read and FrameSlot copy "
    "on the next tick (perf_counter), per submitted frame",
    "encode_ms": "JPEG encode on the native encoder thread (last_sent.encode_ns), sampled once per poll",
    "send_ms": "VIDEO_FRAGMENT send of all the frame's fragments (last_sent.send_ns), sampled once per poll",
    "device_m2p_p95_ms": "VIDEO_REPORT.m2p_p95_ms: the device's own p95 over each ~500 ms report "
    "interval, one sample per report; 0 (not measured) is counted, not sampled",
}


def percentile(ordered: list[float], q: float) -> float:
    """Nearest-rank percentile of an ascending, non-empty list (q in (0, 100])."""
    rank = max(1, math.ceil(q / 100.0 * len(ordered)))
    return ordered[rank - 1]


def summarize(values: Iterable[float]) -> dict[str, Any] | None:
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
        self._reset(max_samples)

    def _reset(self, max_samples: int) -> None:
        self.session_id: int | None = None
        self.last_seq: int | None = None
        self.pose_leg_ms: deque[float] = deque(maxlen=max_samples)
        self.apply_ms: deque[float] = deque(maxlen=max_samples)
        # Applied before the first CLOCK estimate: apply cost known, pose leg not.
        self.without_clock = 0
        # Seq gaps between applied poses: lost on the network, or superseded in the
        # latest-sample slot before a poll applied them (NET-002: the newest pose wins).
        self.not_applied = 0
        self.render_readback_ms: deque[float] = deque(maxlen=max_samples)
        self.encode_ms: deque[float] = deque(maxlen=max_samples)
        self.send_ms: deque[float] = deque(maxlen=max_samples)
        self.last_frame_id: int | None = None
        self.frames_not_sampled = 0
        # Size and quality of the newest sampled frame.
        self.stream: dict[str, int] | None = None
        self.device_m2p_p95_ms: deque[float] = deque(maxlen=max_samples)
        self.last_report_seq: int | None = None
        self.reports_not_measured = 0

    def _session(self, session_id: int | None) -> None:
        if session_id != self.session_id:
            self._reset(self.pose_leg_ms.maxlen or MAX_SAMPLES)
            self.session_id = session_id

    def record(self, session_id: int | None, seq: int, apply_ms: float, pose_leg_ms: float | None) -> bool:
        """Adds one applied pose; a re-apply of the same `seq` is not a new sample."""
        self._session(session_id)
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

    def record_render(self, session_id: int | None, render_readback_ms: float) -> None:
        """Adds the draw + readback time of one frame submitted to the encoder."""
        self._session(session_id)
        self.render_readback_ms.append(render_readback_ms)

    def record_sent(self, session_id: int | None, sent: Mapping[str, Any]) -> bool:
        """Adds the encode and send time of the newest sent frame (`video_stats()["last_sent"]`)
        unless it's already sampled or belongs to another device session."""
        if sent["session_id"] != session_id:
            return False
        self._session(session_id)
        frame_id = sent["wire_frame_id"]
        if frame_id == self.last_frame_id:
            return False
        if self.last_frame_id is not None and frame_id > self.last_frame_id:
            self.frames_not_sampled += frame_id - self.last_frame_id - 1
        self.last_frame_id = frame_id
        self.encode_ms.append(sent["encode_ns"] / 1e6)
        self.send_ms.append(sent["send_ns"] / 1e6)
        self.stream = {key: sent[key] for key in ("width", "height", "quality")}
        return True

    def record_device_report(self, session_id: int | None, adapt: Mapping[str, Any]) -> bool:
        """Adds the M2P p95 of the device's newest `VIDEO_REPORT` (`video_stats()["adapt"]`) once."""
        report = adapt["report"]
        if report is None or adapt["session_id"] != session_id:
            return False
        self._session(session_id)
        if report["report_seq"] == self.last_report_seq:
            return False
        self.last_report_seq = report["report_seq"]
        if report["m2p_p95_ms"] == 0:
            self.reports_not_measured += 1
        else:
            self.device_m2p_p95_ms.append(float(report["m2p_p95_ms"]))
        return True

    def report(self, **meta: Any) -> dict[str, Any]:
        """The report artefact: `meta` (date, platform, device, clock, …) plus every leg."""
        legs = {name: summarize(getattr(self, name)) for name in LEGS}
        pose_leg, apply = legs["pose_leg_ms"], legs["apply_ms"]
        return {
            "kind": "vcam-latency",
            "format": REPORT_FORMAT,
            **meta,
            "session_id": self.session_id,
            "poses_without_clock": self.without_clock,
            "poses_not_applied": self.not_applied,
            "frames_not_sampled": self.frames_not_sampled,
            "stream": self.stream,
            "legs": legs,
            "device_m2p_p95_ms": summarize(self.device_m2p_p95_ms),
            "device_reports_not_measured": self.reports_not_measured,
            "methods": METHODS,
            "limits": {"pose_leg_p95_ms": POSE_LEG_P95_LIMIT_MS, "apply_max_ms": APPLY_LIMIT_MS},
            "meets": {
                "pose_leg_p95": None if pose_leg is None else pose_leg["p95"] <= POSE_LEG_P95_LIMIT_MS,
                "apply_max": None if apply is None else apply["max"] <= APPLY_LIMIT_MS,
            },
        }

    def summary_line(self) -> str:
        """One console line: counts and the p50/p95/p99 of every leg."""
        parts = [f"session={self.session_id}"]
        for name in (*LEGS, "device_m2p_p95_ms"):
            s = summarize(getattr(self, name))
            short = name.removesuffix("_ms")
            if s is None:
                parts.append(f"{short}=none")
            else:
                parts.append(
                    f"{name} n={s['count']} p50={s['p50']:.2f} p95={s['p95']:.2f} p99={s['p99']:.2f} max={s['max']:.2f}"
                )
        return " ".join(parts)
