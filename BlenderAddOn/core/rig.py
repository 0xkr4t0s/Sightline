# SPDX-License-Identifier: GPL-3.0-or-later
"""Rig math: device pose → camera local transform under VCam_Origin (tasks 1.3.2a, 1.3.6).

FR-BL-003, FR-CTL-004, FR-TRK-002, FR-TRK-003, vcp.md §6.1/§6.2. Pure Python (no bpy/mathutils),
so pytest can check it against `testdata/rig/rig_cases.json` and `testdata/rig/hold.json`.
Quaternions are (x, y, z, w); axes are canonical (Blender's: Z up; an identity camera looks down
−Z with +Y up).

The incoming pose is never edited. The camera's local transform under `VCam_Origin` is:

1. **Relative to the zero:** p_rel = Rz(−ψ₀)·(p − p₀), q_rel = Rz(−ψ₀)·q. The zero (p₀, ψ₀) is
   the pose at the last Set origin (identity until then). ψ is the heading: the forward
   direction projected on the ground, 0 along +Y, counter-clockwise about +Z. When the camera
   looks straight up or down, its up vector gives the heading instead.
2. **Locks** (`lock_flags`): bit 2 *pan only* sets p_rel = 0; bit 0 *lock height* sets
   p_rel.z = 0 (the camera stays at the origin's height); bit 1 *lock roll* keeps the forward
   direction but turns the camera about it until its up vector is in the plane of forward and
   world up (not defined, and left unchanged, when looking straight up or down).
3. **Motion scale:** p_local = motion_scale · p_rel. Rotation is never scaled.

The user places, turns and scales `VCam_Origin` in the scene; Blender composes that on top.

**Hold last good pose** (FR-TRK-002, `PoseHold`): with the option on, a pose whose
`tracking_state` isn't normal (5) is not applied; the camera keeps the last normal pose of the
session (or doesn't move, if there hasn't been one yet), and the next normal pose resumes.
Controls still apply to the held pose.
"""

from __future__ import annotations

import math

LOCK_HEIGHT = 1 << 0
LOCK_ROLL = 1 << 1
PAN_ONLY = 1 << 2
_EPS = 1e-9
TRACKING_NORMAL = 5  # vcp.md §6.1


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def qrot(q, v):
    """Rotates vector `v` by unit quaternion `q`."""
    x, y, z, w = q
    return qmul(qmul(q, (*v, 0.0)), (-x, -y, -z, w))[:3]


def qyaw(angle):
    """Rotation by `angle` radians about +Z."""
    return (0.0, 0.0, math.sin(angle / 2), math.cos(angle / 2))


def canonical(q):
    """Unit quaternion with w >= 0 (q and −q are the same rotation)."""
    n = math.sqrt(sum(c * c for c in q))
    q = tuple(c / n for c in q)
    return tuple(-c for c in q) if q[3] < 0 else q


def heading(q) -> float:
    """ψ of orientation `q` (radians): 0 along +Y, counter-clockwise about +Z."""
    fx, fy, _ = qrot(q, (0.0, 0.0, -1.0))
    if math.hypot(fx, fy) < 1e-6:  # looking straight up or down: use the up vector
        fx, fy, _ = qrot(q, (0.0, 1.0, 0.0))
    return math.atan2(-fx, fy)


def zero_from_pose(position, orientation):
    """The Set origin zero (p₀, ψ₀) for the current pose."""
    return tuple(position), heading(orientation)


def remove_roll(q):
    """Same forward direction, up vector turned into the plane of forward and world +Z."""
    f = qrot(q, (0.0, 0.0, -1.0))
    up = (-f[0] * f[2], -f[1] * f[2], 1.0 - f[2] * f[2])  # Z minus its component along f
    n = math.sqrt(sum(c * c for c in up))
    if n < 1e-6:
        return canonical(q)
    u = tuple(c / n for c in up)
    back = tuple(-c for c in f)  # local +Z
    right = (u[1] * back[2] - u[2] * back[1], u[2] * back[0] - u[0] * back[2], u[0] * back[1] - u[1] * back[0])
    return _quat_from_columns(right, u, back)


def _quat_from_columns(x, y, z):
    """Quaternion of the rotation whose matrix columns are the orthonormal axes x, y, z."""
    m00, m01, m02 = x[0], y[0], z[0]
    m10, m11, m12 = x[1], y[1], z[1]
    m20, m21, m22 = x[2], y[2], z[2]
    trace = m00 + m11 + m22
    if trace > 0:
        s = math.sqrt(trace + 1.0) * 2
        q = ((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s)
    elif m00 > m11 and m00 > m22:
        s = math.sqrt(1.0 + m00 - m11 - m22) * 2
        q = (0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s)
    elif m11 > m22:
        s = math.sqrt(1.0 + m11 - m00 - m22) * 2
        q = ((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s)
    else:
        s = math.sqrt(1.0 + m22 - m00 - m11) * 2
        q = ((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s)
    return canonical(q)


def local_pose(position, orientation, zero=None, motion_scale=1.0, lock_flags=0):
    """Camera local (position, quaternion) under VCam_Origin for one device pose."""
    p0, yaw0 = zero if zero is not None else ((0.0, 0.0, 0.0), 0.0)
    unyaw = qyaw(-yaw0)
    p = qrot(unyaw, tuple(a - b for a, b in zip(position, p0)))
    q = canonical(qmul(unyaw, orientation))
    if lock_flags & PAN_ONLY:
        p = (0.0, 0.0, 0.0)
    if lock_flags & LOCK_HEIGHT:
        p = (p[0], p[1], 0.0)
    if lock_flags & LOCK_ROLL:
        q = remove_roll(q)
    return tuple(motion_scale * c for c in p), q


class Controls:
    """The merged CONTROL_STATE of one session (vcp.md §6.2).

    Absent fields keep their previous value. Only a newer `state_seq` is applied. Any change of
    `origin_epoch` after the first one seen is a Set-origin request.
    """

    def __init__(self) -> None:
        self.state_seq = 0
        self.motion_scale = 1.0
        self.lock_flags = 0
        self.origin_epoch: int | None = None

    def update(self, control) -> tuple[bool, bool]:
        """Merges `control` (a `latest_control()` dict or None): (changed, set_origin)."""
        if control is None or control["state_seq"] <= self.state_seq:
            return False, False
        self.state_seq = control["state_seq"]
        if control["motion_scale"] is not None:
            self.motion_scale = control["motion_scale"]
        if control["lock_flags"] is not None:
            self.lock_flags = control["lock_flags"]
        set_origin = False
        epoch = control["origin_epoch"]
        if epoch is not None:
            set_origin = self.origin_epoch is not None and epoch != self.origin_epoch
            self.origin_epoch = epoch
        return True, set_origin


class PoseHold:
    """FR-TRK-002: which device pose to show, per session.

    `select` takes an opaque `sample` (the caller's pose) and returns (sample to apply, or None
    to leave the camera alone; holding). The last normal sample is remembered whether or not
    holding is enabled, so turning the option on during a limited span holds at the last normal
    pose, not at the last degraded one.
    """

    def __init__(self) -> None:
        self.good = None

    def select(self, sample, tracking_state: int, enabled: bool):
        if tracking_state == TRACKING_NORMAL:
            self.good = sample
            return sample, False
        if enabled:
            return self.good, True
        return sample, False
