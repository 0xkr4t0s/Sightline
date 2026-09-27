"""Soak verdicts (task 2.7; NFR-REL-003): no crash, bounded memory and handles, bounded latency.

Pure functions over the samples `run_soak.py` takes every few seconds. A sample is a dict:

    t_s              seconds since the fake iPhone started
    host_alive       the Blender process still exists
    rss_kib          Blender's resident set size (KiB), None if it couldn't be read
    handles          Blender's open file descriptors, None if they couldn't be read
    state_uptime_s   the QA host's `uptime_s` from state.json (it rewrites the file at ~5 Hz)
    session_id       the device session, None when no device is connected
    applied_seq      the newest pose sequence applied to the camera
    video_sent       viewfinder frames the host has sent
    video_expected / video_lost   frames the device reported expecting / missing (VIDEO_REPORT)
    pose_leg_p95_ms  the host's rolling pose-leg p95 (newest 36 000 poses, ~10 min at 60 Hz)
    frame_p95_ms     the sum of the host's rolling render/readback, encode and send p95
    errors           exceptions the QA host's loop captured

The thresholds and methods are in `METHODS` and are copied into every report.
"""

from __future__ import annotations

import statistics
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

KIND = "vcam-soak"
FORMAT = 1
# Fewer samples than this after the warm-up can't show a trend.
MIN_SAMPLES = 3


@dataclass(frozen=True)
class GrowthLimit:
    """Growth is a leak only when both the fitted slope and the net growth exceed their limit."""

    slope_per_min: float
    growth: float
    unit: str

    def as_dict(self) -> dict[str, Any]:
        return {"slope_per_min": self.slope_per_min, "growth": self.growth, "unit": self.unit}


# 1 MiB/min is 120 MiB over the 2-hour soak. 16 MiB of net growth is above the RSS noise of a
# streaming Blender (texture and allocator churn) but below a 10-minute run of a 2 MiB/min leak.
RSS_LIMIT = GrowthLimit(slope_per_min=1.0, growth=16.0, unit="MiB")
# Open descriptors of a steady session don't change; a few can come and go (a log rotation, a
# lazily opened file), a leak of one per frame or per report can't stay under these.
HANDLE_LIMIT = GrowthLimit(slope_per_min=0.5, growth=8.0, unit="handles")


@dataclass(frozen=True)
class LatencyLimits:
    pose_leg_p95_ms: float
    frame_p95_ms: float
    m2p_p95_ms: float

    def as_dict(self) -> dict[str, float]:
        return {
            "pose_leg_p95_ms": self.pose_leg_p95_ms,
            "frame_p95_ms": self.frame_p95_ms,
            "m2p_p95_ms": self.m2p_p95_ms,
        }


# NFR-LAT-001's host pose-leg limit on loopback; the soak adds the injected jitter on top.
POSE_LEG_P95_BASE_MS = 20.0
# Render/readback + encode + send p95 of one frame. The debug vcam_native wheel encodes a
# 960×540 JPEG in ~37 ms here; 100 ms leaves room for load while staying under the 120 ms M2P budget.
FRAME_P95_MS = 100.0
# NFR-LAT-003.
M2P_P95_MS = 120.0

METHODS = {
    "rss_bounded": (
        "Blender's RSS (macOS `ps -o rss=`, Linux /proc/PID/status VmRSS) in MiB, samples at or after "
        "the warm-up only. slope = least-squares fit in MiB/min; net growth = median of the last tenth "
        "of the samples minus the median of the first tenth. Fails only when slope > limit AND net "
        "growth > limit: a steep slope over a few MiB (short run, allocator noise) or a one-off step "
        "(a cache filling once) is not a leak; a steady leak exceeds both."
    ),
    "handles_bounded": (
        "Blender's open file descriptors (macOS `lsof -F f`, numbered descriptors only; Linux "
        "/proc/PID/fd entries), judged like RSS with the handle limits."
    ),
    "no_crash": (
        "Fails if the Blender process disappears, state.json stops updating between two samples "
        "(hung main thread), the QA host's loop captured errors, the device session dropped or was "
        "set up again, the fake iPhone exited non-zero or without FAKE_IPHONE_DONE, or the run "
        "ended before 98 % of the requested duration."
    ),
    "latency_bounded": (
        "After the warm-up, at every sample: the host's rolling pose-leg p95 (NFR-LAT-001 limit plus "
        "the injected jitter) and the rolling render/readback + encode + send p95 stay under their "
        "limits, and both the applied pose sequence and the sent-frame count rise between samples "
        "(no stall). The device's M2P p95 is checked only when the device measured it; the fake "
        "iPhone doesn't (VIDEO_REPORT m2p_p95_ms 0). Without a viewfinder stream (`--no-video`, a "
        "host without a GPU) only the pose leg and the applied pose sequence are judged."
    ),
}


FRAME_LEGS = ("render_readback_ms", "encode_ms", "send_ms")


def _get(data: Any, *keys: str) -> Any:
    for key in keys:
        if not isinstance(data, Mapping):
            return None
        data = data.get(key)
    return data


def sample_from_state(
    t_s: float, host_alive: bool, rss_kib: int | None, handles: int | None, state: Mapping[str, Any]
) -> dict[str, Any]:
    """One sample from the process probe and the QA host's state.json (see the module docstring)."""
    frame_p95 = [_get(state, "latency", leg, "p95") for leg in FRAME_LEGS]
    pose_p95 = _get(state, "latency", "pose_leg_ms", "p95")
    errors = state.get("errors")
    return {
        "t_s": round(t_s, 1),
        "host_alive": host_alive,
        "rss_kib": rss_kib,
        "handles": handles,
        "state_uptime_s": state.get("uptime_s"),
        "session_id": _get(state, "session", "session_id"),
        "applied_seq": _get(state, "session", "applied_seq"),
        "video_sent": _get(state, "video", "sent"),
        "video_expected": _get(state, "video", "adapt", "expected"),
        "video_lost": _get(state, "video", "adapt", "lost"),
        "quality": _get(state, "video", "adapt", "quality"),
        "resolution_drop": _get(state, "video", "adapt", "resolution_drop"),
        "pose_leg_p95_ms": None if pose_p95 is None else round(float(pose_p95), 3),
        "frame_p95_ms": None if None in frame_p95 else round(sum(float(v) for v in frame_p95), 3),
        "errors": len(errors) if isinstance(errors, list) else 0,
    }


def series(samples: Sequence[Mapping[str, Any]], key: str, scale: float = 1.0) -> list[tuple[float, float]]:
    """(t_s, value × scale) of every sample that has `key`."""
    return [(float(s["t_s"]), float(s[key]) * scale) for s in samples if s.get(key) is not None]


def slope_per_min(points: Sequence[tuple[float, float]]) -> float | None:
    """Least-squares slope in units per minute; None without two distinct times."""
    if len(points) < 2:
        return None
    mean_t = statistics.fmean(t for t, _ in points)
    mean_v = statistics.fmean(v for _, v in points)
    var = sum((t - mean_t) ** 2 for t, _ in points)
    if var == 0.0:
        return None
    cov = sum((t - mean_t) * (v - mean_v) for t, v in points)
    return cov / var * 60.0


def net_growth(points: Sequence[tuple[float, float]]) -> float | None:
    """Median of the last tenth minus the median of the first tenth (at least one sample each)."""
    if len(points) < 2:
        return None
    k = max(1, len(points) // 10)
    first = statistics.median(v for _, v in points[:k])
    last = statistics.median(v for _, v in points[-k:])
    return last - first


def growth_verdict(points: Sequence[tuple[float, float]], warmup_s: float, limit: GrowthLimit) -> dict[str, Any]:
    after = [(t, v) for t, v in points if t >= warmup_s]
    slope = slope_per_min(after)
    growth = net_growth(after)
    out: dict[str, Any] = {
        "pass": False,
        "samples": len(after),
        "slope_per_min": None if slope is None else round(slope, 4),
        "growth": None if growth is None else round(growth, 3),
        "first": round(after[0][1], 3) if after else None,
        "last": round(after[-1][1], 3) if after else None,
        "max": round(max(v for _, v in after), 3) if after else None,
        "limit": limit.as_dict(),
    }
    if slope is None or growth is None or len(after) < MIN_SAMPLES:
        out["reason"] = f"too few samples after the {warmup_s:g} s warm-up ({len(after)})"
        return out
    unit = limit.unit
    text = (
        f"slope {slope:.3f} {unit}/min (limit {limit.slope_per_min:g}), "
        f"net growth {growth:.1f} {unit} (limit {limit.growth:g})"
    )
    leak = slope > limit.slope_per_min and growth > limit.growth
    out["pass"] = not leak
    out["reason"] = ("growing: " if leak else "bounded: ") + text
    return out


def _session_reasons(samples: Sequence[Mapping[str, Any]]) -> tuple[int, list[str]]:
    ids = [s.get("session_id") for s in samples]
    seen = [i for i, sid in enumerate(ids) if sid is not None]
    reasons = []
    sessions = len({ids[i] for i in seen})
    if seen:
        gaps = [i for i in range(seen[0], seen[-1]) if ids[i] is None]
        if gaps:
            reasons.append(f"the device session dropped (no session at {samples[gaps[0]]['t_s']:g} s)")
    if sessions > 1:
        reasons.append(f"the device session was set up {sessions} times")
    return sessions, reasons


def crash_verdict(
    samples: Sequence[Mapping[str, Any]],
    fake_exit: int | None,
    fake_done: Mapping[str, Any] | None,
    duration_s: float,
) -> dict[str, Any]:
    reasons: list[str] = []
    host_exit_at: float | None = None
    for s in samples:
        if not s.get("host_alive"):
            host_exit_at = float(s["t_s"])
            reasons.append(f"the Blender host exited (gone at {host_exit_at:g} s)")
            break
    alive = [s for s in samples if s.get("host_alive")]
    for prev, cur in zip(alive, alive[1:], strict=False):
        before, after = prev.get("state_uptime_s"), cur.get("state_uptime_s")
        if before is None or after is None or after <= before:
            reasons.append(f"state.json stopped updating at {cur['t_s']:g} s (host hung)")
            break
    errors = max((int(s.get("errors") or 0) for s in samples), default=0)
    if errors:
        reasons.append(f"the QA host's loop captured {errors} errors")
    sessions, session_reasons = _session_reasons(samples)
    reasons += session_reasons
    if fake_exit is None:
        reasons.append("the fake iPhone didn't finish (stopped by the runner)")
    elif fake_exit != 0:
        reasons.append(f"the fake iPhone exited {fake_exit}")
    if fake_done is None:
        reasons.append("the fake iPhone printed no FAKE_IPHONE_DONE line")
    last_t = float(samples[-1]["t_s"]) if samples else 0.0
    if not samples:
        reasons.append("no samples")
    elif last_t < 0.98 * duration_s:
        reasons.append(f"the run ended after {last_t:g} s of {duration_s:g} s")
    return {"pass": not reasons, "reasons": reasons, "sessions": sessions, "host_exit_at_s": host_exit_at}


def _max_over(post: Sequence[Mapping[str, Any]], key: str, limit: float, what: str, reasons: list[str]) -> float | None:
    values = [(float(s["t_s"]), float(s[key])) for s in post if s.get(key) is not None]
    if not values:
        reasons.append(f"no {what} samples after the warm-up")
        return None
    over = [(t, v) for t, v in values if v > limit]
    if over:
        t, v = over[0]
        reasons.append(f"{what} p95 {v:.1f} ms > {limit:g} ms at {t:g} s ({len(over)} samples over)")
    return max(v for _, v in values)


def latency_verdict(
    samples: Sequence[Mapping[str, Any]],
    warmup_s: float,
    limits: LatencyLimits,
    m2p_p95_ms: float | None,
    video: bool = True,
) -> dict[str, Any]:
    """`video=False` (a host without a GPU, `--no-video`) judges the pose path only."""
    reasons: list[str] = []
    post = [s for s in samples if float(s["t_s"]) >= warmup_s and s.get("host_alive")]
    if not post:
        reasons.append("no samples after the warm-up")
    pose_max = _max_over(post, "pose_leg_p95_ms", limits.pose_leg_p95_ms, "pose leg", reasons) if post else None
    frame_max = _max_over(post, "frame_p95_ms", limits.frame_p95_ms, "frame path", reasons) if post and video else None
    keys = ("applied_seq", "video_sent") if video else ("applied_seq",)
    stalls = [
        cur
        for prev, cur in zip(post, post[1:], strict=False)
        if any((cur.get(key) or 0) <= (prev.get(key) or 0) for key in keys)
    ]
    if stalls:
        reasons.append(f"{len(stalls)} stalls (no new pose or frame between samples), first at {stalls[0]['t_s']:g} s")
    if m2p_p95_ms is not None and m2p_p95_ms > limits.m2p_p95_ms:
        reasons.append(f"device M2P p95 {m2p_p95_ms:g} ms > {limits.m2p_p95_ms:g} ms")
    return {
        "pass": not reasons,
        "reasons": reasons,
        "pose_leg_p95_max_ms": None if pose_max is None else round(pose_max, 3),
        "frame_p95_max_ms": None if frame_max is None else round(frame_max, 3),
        "stalls": len(stalls),
        "m2p": "not measured" if m2p_p95_ms is None else m2p_p95_ms,
        "video": video,
        "limits": limits.as_dict(),
    }


def verdicts(
    samples: Sequence[Mapping[str, Any]],
    *,
    warmup_s: float,
    duration_s: float,
    fake_exit: int | None,
    fake_done: Mapping[str, Any] | None,
    limits: LatencyLimits,
    m2p_p95_ms: float | None,
    video: bool = True,
) -> dict[str, dict[str, Any]]:
    return {
        "no_crash": crash_verdict(samples, fake_exit, fake_done, duration_s),
        "rss_bounded": growth_verdict(series(samples, "rss_kib", scale=1 / 1024), warmup_s, RSS_LIMIT),
        "handles_bounded": growth_verdict(series(samples, "handles"), warmup_s, HANDLE_LIMIT),
        "latency_bounded": latency_verdict(samples, warmup_s, limits, m2p_p95_ms, video),
    }


def _value(text: str) -> int | float | str:
    for kind in (int, float):
        try:
            return kind(text)
        except ValueError:
            pass
    return text


def parse_fake_done(text: str) -> dict[str, Any] | None:
    """key=value fields of the last `FAKE_IPHONE_DONE` line, numbers converted; None if there is none."""
    lines = [line for line in text.splitlines() if line.startswith("FAKE_IPHONE_DONE")]
    if not lines:
        return None
    fields = (token.partition("=") for token in lines[-1].split()[1:])
    return {key: _value(value) for key, sep, value in fields if sep}


def platform_tag(system: str, machine: str) -> str:
    """`macos-arm64`, `linux-x86_64`, … for the report name."""
    os_name = {"darwin": "macos"}.get(system.lower(), system.lower())
    arch = {"aarch64": "arm64", "amd64": "x86_64"}.get(machine.lower(), machine.lower())
    return f"{os_name}-{arch}"


def default_out(root: Path, date: str, tag: str) -> Path:
    return root / "reports" / f"soak-{date}-{tag}.json"


def build_report(
    meta: Mapping[str, Any], samples: Sequence[Mapping[str, Any]], results: Mapping[str, Mapping[str, Any]]
) -> dict[str, Any]:
    """The report: `meta` (date, platform, impairment, …), the verdicts, their methods and the samples."""
    return {
        "kind": KIND,
        "format": FORMAT,
        **meta,
        "pass": all(bool(v["pass"]) for v in results.values()),
        "verdicts": dict(results),
        "methods": METHODS,
        "samples": list(samples),
    }
