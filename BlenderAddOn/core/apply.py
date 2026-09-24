# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply the newest VCP pose to the target camera (task 1.3.1; FR-BL-002, ARC-003, vcp.md §6.4).

Main thread only (called from the session poll). The pose is canonical (vcp.md §7): Blender's
axes, metres, unit quaternion (x, y, z, w). So the camera's `matrix_world` is translation ×
rotation, with no axis conversion here: ARKit→canonical happens once, on the device. The
`VCam_Origin` rig, motion scale and locks come in task 1.3.2.

After applying, it publishes what the host actually applied as `STATUS`: at most every
`STATUS_INTERVAL` for the pose sequence, and at once when the camera or error changes.
"""

from __future__ import annotations

STATUS_INTERVAL = 0.5
ERROR_NONE = 0
ERROR_NO_CAMERA = 1
MAX_CAMERA_NAME = 63  # bytes of UTF-8 (vcp.md §6.4)


def pose_matrix(position, orientation):
    """4x4 world matrix from a canonical position (m) and quaternion (x, y, z, w)."""
    from mathutils import Matrix, Quaternion

    x, y, z, w = orientation
    return Matrix.Translation(position) @ Quaternion((w, x, y, z)).to_matrix().to_4x4()


def camera_name(name: str) -> str:
    """`name` cut to 63 UTF-8 bytes on a character boundary."""
    return name.encode("utf-8")[:MAX_CAMERA_NAME].decode("utf-8", "ignore")


def target_camera(scene):
    """The VCam target camera, else the scene camera; None unless it's a camera object."""
    props = getattr(scene, "vcam_props", None)
    obj = (props.target_camera if props is not None else None) or scene.camera
    return obj if obj is not None and obj.type == 'CAMERA' else None


class Applier:
    """Per-session apply state: the last applied `seq` and the last published `STATUS`."""

    def __init__(self) -> None:
        self.session_id: int | None = None
        self.applied_seq = 0
        self._published: tuple | None = None
        self._published_at = float("-inf")

    def tick(self, session, session_id: int | None, scene, now: float) -> None:
        if session_id != self.session_id:  # a new session restarts seq at 1
            self.__init__()
            self.session_id = session_id
        camera = target_camera(scene)
        pose = session.latest_pose()
        if camera is not None and pose is not None and pose["seq"] != self.applied_seq:
            camera.matrix_world = pose_matrix(pose["smoothed_position"], pose["smoothed_orientation"])
            self.applied_seq = pose["seq"]
        if session_id is None:
            return
        error = ERROR_NONE if camera is not None else ERROR_NO_CAMERA
        name = camera_name(camera.name) if camera is not None else None
        content = (error, name)
        if self._published is None or content != self._published[1:] or now - self._published_at >= STATUS_INTERVAL:
            session.update_status(session_id, self.applied_seq, 0, error, name)
            self._published = (self.applied_seq, *content)
            self._published_at = now
