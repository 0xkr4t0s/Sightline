# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel status formatting (task 1.3.3; FR-BL-004). Pure Python, tested outside Blender."""

from __future__ import annotations

from .render import adapted_resolution
from .rig import LOCK_HEIGHT, LOCK_ROLL, PAN_ONLY

# vcp.md §6.1 tracking_state.
TRACKING = {
    0: "Not available",
    1: "Initializing",
    2: "Excessive motion",
    3: "Insufficient features",
    4: "Relocalizing",
    5: "Normal",
    6: "Limited",
}


def tracking_label(tracking_state: int | None) -> str:
    if tracking_state is None:
        return "No pose yet"
    return TRACKING.get(tracking_state, "Limited")


def hold_label(tracking_state: int, has_good_pose: bool) -> str:
    """FR-TRK-002: why the camera isn't following the device, for the N-panel."""
    reason = tracking_label(tracking_state)
    if not has_good_pose:
        return f"Holding: no normal pose yet ({reason})"
    return f"Holding last good pose ({reason})"


def scale_label(motion_scale: float) -> str:
    """vcp.md §6.2: host metres per device metre, shown as device:host (10.0 → "1:10")."""
    if motion_scale >= 1.0:
        return f"1:{motion_scale:g}"
    return f"{1.0 / motion_scale:g}:1"


def locks_label(lock_flags: int) -> str:
    names = [name for bit, name in ((PAN_ONLY, "Pan only"), (LOCK_HEIGHT, "Height"), (LOCK_ROLL, "Roll"))
             if lock_flags & bit]
    return ", ".join(names) if names else "None"


def pose_latency_ms(capture_time_ns: int, offset_ns: int, host_now_ns: int) -> float:
    """Pose leg (NFR-LAT-001): host clock now minus the capture time mapped onto the host clock.

    `offset_ns` is device clock − host clock (vcp.md §6.3), so the capture happened at host time
    `capture_time_ns − offset_ns`.
    """
    return (host_now_ns - (capture_time_ns - offset_ns)) / 1e6


def code_label(code: str) -> str:
    """A 6-digit pairing code in two groups of three, as the iPhone shows it."""
    return f"{code[:3]} {code[3:]}" if len(code) == 6 else code


def _level_label(quality: int, resolution_key: str, drop: int) -> str:
    width, height = adapted_resolution(resolution_key, drop)
    return f"q{quality} {width}×{height}"


def adapt_labels(stats: dict, resolution_key: str) -> list[str]:
    """NET-VID-005: the level the stream adapted to, the link's loss and the last change, with
    resolution steps shown as sizes below the user's `resolution_key`."""
    adapt = stats["adapt"]
    if adapt is None:
        return []
    level = _level_label(adapt["quality"], resolution_key, adapt["resolution_drop"])
    if (adapt["quality"], adapt["resolution_drop"]) == (stats["user_quality"], 0):
        lines = [f"Adaptive: full, {level}"]
    else:
        lines = [f"Adaptive: lowered to {level}"]
    link = f"Link: {adapt['lost']} of {adapt['expected']} frames lost"
    report = adapt["report"]
    if report is not None and report["m2p_p95_ms"]:
        link += f", M2P p95 {report['m2p_p95_ms']} ms"
    lines.append(link)
    change = adapt["last_change"]
    if change is not None:
        reason = {
            "loss": f"{change['lost']}/{change['expected']} lost",
            "m2p": f"M2P {change['m2p_p95_ms']} ms",
            "recovered": "link clear",
        }[change["reason"]]
        lines.append(
            f"Last change: {_level_label(change['from_quality'], resolution_key, change['from_resolution_drop'])}"
            f" → {_level_label(change['to_quality'], resolution_key, change['to_resolution_drop'])} ({reason})"
        )
    return lines


def video_labels(stats: dict | None, resolution_key: str) -> list[str]:
    """Viewfinder stream counters (`Session.video_stats()`, NET-VID-001/005) as N-panel lines."""
    if stats is None:
        return ["Video: not streaming"]
    lines = [f"Video: {stats['sent']} sent, {stats['encoded_skipped']} skipped, q{stats['quality']}"]
    last = stats["last_sent"]
    if last is not None:
        lines.append(f"Last: {last['width']}×{last['height']}, {last['jpeg_bytes'] / 1024:.0f} KB, "
                     f"encode {last['encode_ns'] / 1e6:.1f} ms, send {last['send_ns'] / 1e6:.1f} ms")
    lines += adapt_labels(stats, resolution_key)
    failed = stats["send_failed"] + stats["encode_failed"]
    if failed:
        error = stats["last_error"]
        lines.append(f"Video failures: {failed}" + (f" ({error})" if error else ""))
    return lines
