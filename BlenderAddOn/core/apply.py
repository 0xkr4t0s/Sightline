# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply the newest VCP pose to the camera rig (tasks 1.3.1, 1.3.2a, 1.3.6).

FR-BL-002, FR-BL-003, FR-CTL-004, FR-TRK-002, FR-TRK-003, vcp.md §6.2/§6.4. Main thread only
(called from the session poll).

The rig is `VCam_Origin` (the user places, turns and scales it) → the target camera. The camera
is parented to it with an identity parent inverse, and its `matrix_basis` is the local pose
from `core/rig.py`: the device pose relative to the Set-origin zero, with the axis locks and the
motion scale from `CONTROL_STATE`. The pose is canonical (vcp.md §7, Blender's axes), so there's
no axis conversion here. The zero is stored on the origin object, so it survives reconnects and
saving the file.

Lens (task 2.4; FR-BL-005, FR-CTL-001/003): the device's changed lens, focus distance, f-stop
and DoF requests (merged in `rig.Controls` / `lens.LensControls`) are written to the target
camera's data in the same tick. A request that arrives while there is no camera waits for one.
The scene's sensor preset is written when it or the target camera changes (`properties/`).

Tap-to-focus and the A/B rack (FR-CTL-002; maths and request rules in `core/lens.py`) run in
the same tick, before this tick's pose is applied, so a tap ray-casts from the pose the
streamed picture was drawn with. A hit sets `dof.focus_distance` and never `use_dof` (that
follows the device's DoF flag); a miss keeps the distance and is logged and shown in the
N-panel. A rack writes one eased value per tick and never blocks. Besides a manual focus
request or a tap, any other change of the focus distance (an edit in Blender, another target
camera) cancels it, so the rack doesn't fight the user.

STATUS reports what the host actually applied: the pose `seq`, the merged `state_seq` as
`control_ack`, the camera, and the camera's lens as Blender has it, including edits made in
Blender (`core/lens.py`). It goes out at once on a camera/error/ack/lens change, and otherwise
at most every `STATUS_INTERVAL` for the pose sequence.

Hold last good pose (FR-TRK-002, the scene's `hold_last_good`, on by default): while the newest
pose isn't normal, the camera shows the session's last normal pose (`rig.PoseHold`) and
`applied_pose_seq` stays at that pose's `seq`.
"""

from __future__ import annotations

from .lens import FocusRack, axial_distance, clamp_distance, preset_sensor, render_aspect, status_lens, tap_ray
from .log import get_logger
from .rig import Controls, PoseHold, local_pose, zero_from_pose

_log = get_logger(__name__)

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


def scene_aspect(scene) -> float:
    """The scene's render picture width / height, pixel aspect included (LNS-003)."""
    render = scene.render
    return render_aspect(render.resolution_x, render.resolution_y, render.pixel_aspect_x, render.pixel_aspect_y)


def camera_lens(scene, camera) -> tuple:
    """(lens, focus distance, f-stop, DoF on, sensor width, sensor fit, render aspect) as Blender has them."""
    data, dof = camera.data, camera.data.dof
    aspect = scene_aspect(scene)
    return data.lens, dof.focus_distance, dof.aperture_fstop, dof.use_dof, data.sensor_width, data.sensor_fit, aspect


def applied_lens(scene, camera) -> dict | None:
    """The camera's current lens as `update_status` keyword arguments, or None (vcp.md §6.4)."""
    return status_lens(*camera_lens(scene, camera))


def apply_lens(camera, changes) -> dict:
    """Writes the device's changed lens requests (`LensControls.take()`) to the camera's data.

    Main thread only. A value the camera already has isn't written again. Returns what changed.
    """
    data = camera.data
    targets = {
        "lens_mm": (data, "lens"),
        "focus_distance_m": (data.dof, "focus_distance"),
        "fstop": (data.dof, "aperture_fstop"),
        "dof_on": (data.dof, "use_dof"),
    }
    written = {}
    for key, value in changes.items():
        owner, name = targets[key]
        if getattr(owner, name) != value:
            setattr(owner, name, value)
            written[key] = value
    return written


def tap_hit(scene, camera, u: float, v: float):
    """Ray-casts through (u, v) of the camera's picture: (distance along the view axis, object
    name), or None if nothing is hit between the clip planes. Main thread only.

    `view_frame` has the scene render's aspect, and so does the streamed picture (LNS-003,
    `render.fit_aspect`), so (u, v) of the device's viewfinder land on the same scene point.
    """
    import bpy
    from mathutils import Vector

    depsgraph = bpy.context.evaluated_depsgraph_get()
    world = camera.evaluated_get(depsgraph).matrix_world.normalized()  # the view ignores scale
    data = camera.data
    corners = [tuple(c) for c in data.view_frame(scene=scene)]
    start, direction, length = tap_ray(corners, u, v, data.clip_start, data.clip_end, data.type == 'ORTHO')
    rotation = world.to_3x3()
    hit, location, _normal, _index, obj, _matrix = scene.ray_cast(
        depsgraph, world @ Vector(start), rotation @ Vector(direction), distance=length
    )
    if not hit:
        return None
    return axial_distance(world.translation, rotation @ Vector((0.0, 0.0, -1.0)), location), obj.name


def apply_sensor_preset(scene) -> bool:
    """Sets the scene's sensor preset (LNS-002) on the target camera; False if nothing to set."""
    props = getattr(scene, "vcam_props", None)
    camera = target_camera(scene)
    sensor = preset_sensor(props.sensor_preset, props.sensor_custom_width) if props is not None else None
    if camera is None or sensor is None:
        return False
    camera.data.sensor_width, camera.data.sensor_fit = sensor
    return True


def target_camera(scene):
    """The camera to drive, or None (see `camera_status`)."""
    return camera_status(scene)[0]


def hold_enabled(scene) -> bool:
    """The scene's Hold Last Good Pose option (FR-TRK-002); on when the scene has no settings."""
    return bool(getattr(getattr(scene, "vcam_props", None), "hold_last_good", True))


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
    """Per-session apply state: controls, the shown and last seen `seq`, the last published STATUS."""

    def __init__(self) -> None:
        self.session_id: int | None = None
        self.controls = Controls()
        self.hold = PoseHold()
        # seq of the pose on the camera; while holding, that of the held pose.
        self.applied_seq = 0
        # The newest pose is limited and not applied (FR-TRK-002); the N-panel shows it.
        self.holding = False
        self._seen_seq = 0
        self._set_origin = False
        self._force = False
        self._published: tuple | None = None
        self._published_at = float("-inf")
        # FR-CTL-002: the running rack, the focus distance it last wrote (as Blender stored it),
        # and the last tap's (distance, object name), both None after a miss.
        self.rack: FocusRack | None = None
        self._rack_focus: float | None = None
        self.last_tap: tuple[float | None, str | None] | None = None

    def request_set_origin(self) -> None:
        """Set origin from Blender (FR-TRK-003): re-zero at the pose applied on the next tick."""
        self._set_origin = True

    def reapply(self) -> None:
        """Apply the current pose again on the next tick (after the zero or the hold option changed)."""
        self._force = True

    def _lens_tick(self, scene, camera, now: float) -> None:
        """Writes the device's lens requests, carries out a new tap, then starts or steps a rack."""
        lens = self.controls.lens
        if lens.waiting():
            changes = lens.take()
            if "focus_distance_m" in changes:
                self._cancel_rack("manual focus")
            if changes:
                apply_lens(camera, changes)
            tap = lens.take_tap()
            if tap is not None:
                self._cancel_rack("tap")
                self._tap(scene, camera, *tap)
            rack = lens.take_rack()
            if rack is not None:
                target, mark, duration = rack
                self.rack = FocusRack(target, camera.data.dof.focus_distance, mark, duration, now)
                self._rack_focus = None
                _log.info(
                    "rack to %s: %.3f -> %.3f m over %.0f ms", "AB"[target - 1], self.rack.start_m, mark, duration * 1e3
                )
        if self.rack is not None:
            self._step_rack(camera, now)

    def _tap(self, scene, camera, u: float, v: float) -> None:
        dof = camera.data.dof
        hit = tap_hit(scene, camera, u, v)
        if hit is None:
            self.last_tap = (None, None)
            _log.info("tap focus u=%.3f v=%.3f: nothing hit, focus kept at %.3f m", u, v, dof.focus_distance)
            return
        distance, name = hit
        dof.focus_distance = clamp_distance(distance)
        self.last_tap = (dof.focus_distance, name)
        _log.info("tap focus u=%.3f v=%.3f: hit %r, focus %.3f m", u, v, name, dof.focus_distance)

    def _step_rack(self, camera, now: float) -> None:
        rack, dof = self.rack, camera.data.dof
        if self._rack_focus is not None and dof.focus_distance != self._rack_focus:
            self._cancel_rack("focus changed in Blender")
            return
        dof.focus_distance = rack.value(now)
        self._rack_focus = dof.focus_distance
        if rack.finished(now):
            _log.info("rack to %s done at %.3f m", "AB"[rack.target - 1], dof.focus_distance)
            self.rack = self._rack_focus = None

    def _cancel_rack(self, reason: str) -> None:
        if self.rack is not None:
            _log.info("rack to %s cancelled: %s", "AB"[self.rack.target - 1], reason)
        self.rack = self._rack_focus = None

    def tick(self, session, session_id: int | None, scene, now: float):
        """Handles the newest pose if due; returns it (applied or held against), else None."""
        if session_id != self.session_id:  # a new session restarts every sequence number
            self.__init__()
            self.session_id = session_id
        camera = target_camera(scene)
        changed, set_origin = self.controls.update(session.latest_control()) if session_id else (False, False)
        self._set_origin |= set_origin
        if camera is not None:
            self._lens_tick(scene, camera, now)
        pose = session.latest_pose()
        handled = None
        due = pose is not None and (pose["seq"] != self._seen_seq or changed or self._set_origin or self._force)
        if camera is not None and due:
            shown, self.holding = self.hold.select(pose, pose["tracking_state"], hold_enabled(scene))
            if shown is not None:  # None: holding before the session's first normal pose
                position, orientation = shown["smoothed_position"], shown["smoothed_orientation"]
                origin = ensure_rig(scene, camera)
                if self._set_origin:
                    write_zero(origin, position, orientation)
                    self._set_origin = False
                c = self.controls
                local = local_pose(position, orientation, read_zero(origin), c.motion_scale, c.lock_flags)
                camera.matrix_basis = pose_matrix(*local)
                self.applied_seq = shown["seq"]
            self._seen_seq = pose["seq"]
            self._force = False
            handled = pose
        if session_id is None:
            return handled
        error = ERROR_NONE if camera is not None else ERROR_NO_CAMERA
        name = camera_name(camera.name) if camera is not None else None
        lens = applied_lens(scene, camera) if camera is not None else None
        content = (self.controls.state_seq, error, name, lens)
        if self._published is None or content != self._published[1:] or now - self._published_at >= STATUS_INTERVAL:
            session.update_status(session_id, self.applied_seq, self.controls.state_seq, error, name, **(lens or {}))
            self._published = (self.applied_seq, *content)
            self._published_at = now
        return handled
