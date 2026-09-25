# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply the newest VCP pose to the camera rig (tasks 1.3.1, 1.3.2a).

FR-BL-002, FR-BL-003, FR-CTL-004, FR-TRK-003, vcp.md §6.2/§6.4. Main thread only (called from
the session poll).

The rig is `VCam_Origin` (the user places, turns and scales it) → the target camera. The camera
is parented to it with an identity parent inverse, and its `matrix_basis` is the local pose
from `core/rig.py`: the device pose relative to the Set-origin zero, with the axis locks and the
motion scale from `CONTROL_STATE`. The pose is canonical (vcp.md §7, Blender's axes), so there's
no axis conversion here. The zero is stored on the origin object, so it survives reconnects and
saving the file.

STATUS reports what the host actually applied: the pose `seq`, the merged `state_seq` as
`control_ack`, and the camera. It goes out at once on a camera/error/ack change, and otherwise at
most every `STATUS_INTERVAL` for the pose sequence.
"""

from __future__ import annotations

from .rig import Controls, local_pose, zero_from_pose

STATUS_INTERVAL = 0.5
ERROR_NONE = 0
ERROR_NO_CAMERA = 1
MAX_CAMERA_NAME = 63  # bytes of UTF-8 (vcp.md §6.4)
ORIGIN_NAME = "VCam_Origin"
ZERO_POSITION_KEY = "vcam_zero_position"
ZERO_YAW_KEY = "vcam_zero_yaw"
# Marks the rig empty, so it is still found after the user renames it (FR-BL-007).
RIG_KEY = "vcam_origin"


def pose_matrix(position, orientation):
    """4x4 matrix from a canonical position (m) and quaternion (x, y, z, w)."""
    from mathutils import Matrix, Quaternion

    x, y, z, w = orientation
    return Matrix.Translation(position) @ Quaternion((w, x, y, z)).to_matrix().to_4x4()


def camera_name(name: str) -> str:
    """`name` cut to 63 UTF-8 bytes on a character boundary."""
    return name.encode("utf-8")[:MAX_CAMERA_NAME].decode("utf-8", "ignore")


def _in_scene(scene, obj) -> bool:
    # A camera deleted in the UI keeps existing while the target pointer uses it, but leaves
    # every scene; scene.camera can still point at it.
    return scene.objects.get(obj.name) == obj


def camera_status(scene):
    """(camera to drive, warning): the VCam target camera, else the scene camera (FR-BL-007).

    The camera is None, with a warning short enough for the N-panel, when the choice is unset,
    not a camera, or no longer in the scene. A deleted target does not fall back to the scene
    camera: that would move a camera the operator didn't pick.
    """
    props = getattr(scene, "vcam_props", None)
    target = props.target_camera if props is not None else None
    obj = target if target is not None else scene.camera
    if obj is None:
        return None, "No camera to drive"
    if obj.type != 'CAMERA':
        return None, f'"{obj.name}" is not a camera'
    if not _in_scene(scene, obj):
        return None, f'"{obj.name}" is in another scene' if obj.users_scene else f'"{obj.name}" was deleted'
    return obj, None


def target_camera(scene):
    """The camera to drive, or None (see `camera_status`)."""
    return camera_status(scene)[0]


def find_origin(camera):
    """The rig empty: `camera`'s marked parent, else `VCam_Origin`, else a marked (renamed) rig."""
    import bpy

    parent = camera.parent if camera is not None else None
    if parent is not None and parent.get(RIG_KEY):
        return parent
    origin = bpy.data.objects.get(ORIGIN_NAME)
    if origin is None:  # only until a camera is parented: then the first branch finds it
        origin = next((o for o in bpy.data.objects if o.get(RIG_KEY)), None)
    return origin


def ensure_rig(scene, camera):
    """Finds (or creates, at the camera's position) the rig empty and parents the camera to it."""
    import bpy
    from mathutils import Matrix

    origin = find_origin(camera)
    if origin is None:
        origin = bpy.data.objects.new(ORIGIN_NAME, None)
        origin.empty_display_type = 'PLAIN_AXES'
        origin.location = camera.matrix_world.translation
    if not origin.get(RIG_KEY):
        origin[RIG_KEY] = True
    if not _in_scene(scene, origin):
        scene.collection.objects.link(origin)
    if camera.parent != origin:
        camera.parent = origin
        camera.matrix_parent_inverse = Matrix.Identity(4)
    return origin


def read_zero(origin):
    """The Set-origin zero stored on the rig, or None (identity) if there isn't one."""
    if ZERO_POSITION_KEY not in origin or ZERO_YAW_KEY not in origin:
        return None
    return tuple(origin[ZERO_POSITION_KEY]), float(origin[ZERO_YAW_KEY])


def clear_zero(origin) -> None:
    """Back to the identity zero: the device's own world origin and heading."""
    for key in (ZERO_POSITION_KEY, ZERO_YAW_KEY):
        if key in origin:
            del origin[key]


def write_zero(origin, position, orientation) -> None:
    p0, yaw0 = zero_from_pose(position, orientation)
    origin[ZERO_POSITION_KEY] = list(p0)
    origin[ZERO_YAW_KEY] = yaw0


class Applier:
    """Per-session apply state: controls, the last applied `seq`, the last published STATUS."""

    def __init__(self) -> None:
        self.session_id: int | None = None
        self.controls = Controls()
        self.applied_seq = 0
        self._set_origin = False
        self._force = False
        self._published: tuple | None = None
        self._published_at = float("-inf")

    def request_set_origin(self) -> None:
        """Set origin from Blender (FR-TRK-003): re-zero at the pose applied on the next tick."""
        self._set_origin = True

    def reapply(self) -> None:
        """Apply the current pose again on the next tick (after the zero changed)."""
        self._force = True

    def tick(self, session, session_id: int | None, scene, now: float):
        """Applies the newest pose if due; returns the pose dict it applied, else None."""
        if session_id != self.session_id:  # a new session restarts every sequence number
            self.__init__()
            self.session_id = session_id
        camera = target_camera(scene)
        changed, set_origin = self.controls.update(session.latest_control()) if session_id else (False, False)
        self._set_origin |= set_origin
        pose = session.latest_pose()
        applied = None
        due = pose is not None and (pose["seq"] != self.applied_seq or changed or self._set_origin or self._force)
        if camera is not None and due:
            position, orientation = pose["smoothed_position"], pose["smoothed_orientation"]
            origin = ensure_rig(scene, camera)
            if self._set_origin:
                write_zero(origin, position, orientation)
                self._set_origin = False
            c = self.controls
            local = local_pose(position, orientation, read_zero(origin), c.motion_scale, c.lock_flags)
            camera.matrix_basis = pose_matrix(*local)
            self.applied_seq = pose["seq"]
            self._force = False
            applied = pose
        if session_id is None:
            return applied
        error = ERROR_NONE if camera is not None else ERROR_NO_CAMERA
        name = camera_name(camera.name) if camera is not None else None
        content = (self.controls.state_seq, error, name)
        if self._published is None or content != self._published[1:] or now - self._published_at >= STATUS_INTERVAL:
            session.update_status(session_id, self.applied_seq, self.controls.state_seq, error, name)
            self._published = (self.applied_seq, *content)
            self._published_at = now
        return applied
