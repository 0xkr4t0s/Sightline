# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel status formatting (task 1.3.3; FR-BL-004). Pure Python, tested outside Blender."""

from __future__ import annotations

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
