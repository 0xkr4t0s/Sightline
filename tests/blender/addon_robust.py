# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: the session survives renames, undo, file reload and a deleted camera
(task 1.3.4; FR-BL-007, NET-004 file reload).

Needs the fake iPhone binary (task 1.2.7). Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_robust.py

While the fake streams: rename the camera and the rig. Once it holds its last pose: undo, reopen
the .blend, delete the camera, load an empty file. Each step must keep the same session running,
drive the right camera (or report "no camera" to the device and warn), and never raise in the
poll. References to Blender data are fetched again after every undo/load: both free them.
"""

import importlib
import os
import subprocess
import tempfile
import time

import addon_utils
import bpy
from mathutils import Matrix

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOTION = os.path.join(ROOT, "testdata", "motion")
FAKE = os.environ["FAKE_IPHONE"]

addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")
apply = importlib.import_module(MODULE + ".core.apply")


def poll():
    session._poll()
    # The poll swallows exceptions into last_error (a raising timer would be dropped); any
    # error here means something broke. DNS-SD errors are environment, not robustness.
    err = session.state.last_error
    assert err is None or err.startswith("DNS-SD"), err


def poll_until(what, cond, timeout=10.0):
    deadline = time.monotonic() + timeout
    while not cond():
        assert time.monotonic() < deadline, f"timed out waiting for {what}"
        poll()
        time.sleep(0.002)


def published():
    """(applied_seq, state_seq, error, camera name) of the last STATUS sent to the device."""
    return session.applier()._published


def expected_basis(pose):
    return apply.pose_matrix(pose["smoothed_position"], pose["smoothed_orientation"])


def max_diff(a, b):
    return max(abs(x - y) for ra, rb in zip(a, b) for x, y in zip(ra, rb))


assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
child = subprocess.Popen(
    [FAKE, "--host", f"127.0.0.1:{live.port()}", "--state", os.path.join(session.config_dir(), "k"),
     "--code", live.enable_pairing(), "--motion", os.path.join(MOTION, "scripted.bin"), "--rate", "60",
     "--linger", "30"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
poll_until("first pose", lambda: session.applier().applied_seq > 0)

# Renamed camera: still driven, and the device is told the new name.
bpy.context.scene.camera.name = "Hero Cam"
seq = session.applier().applied_seq
poll_until("pose after rename", lambda: session.applier().applied_seq > seq)
assert published()[2:] == (apply.ERROR_NONE, "Hero Cam"), published()

# Renamed rig: the camera stays under it (no second VCam_Origin, no re-parent jump).
rig = bpy.data.objects[apply.ORIGIN_NAME]
rig.name = "My Rig"
seq = session.applier().applied_seq
poll_until("pose after rig rename", lambda: session.applier().applied_seq > seq)
assert bpy.data.objects.get(apply.ORIGIN_NAME) is None, "a second rig was created"
assert bpy.data.objects["Hero Cam"].parent == bpy.data.objects["My Rig"]


# The script ends; the fake lingers holding its last pose (like a paused device).
def stream_ended():
    seq = live.latest_pose()["seq"]
    t = time.monotonic() + 0.3
    while time.monotonic() < t:
        poll()
        time.sleep(0.01)
    return live.latest_pose()["seq"] == seq


poll_until("stream end", stream_ended, timeout=20)
poll()
final = live.latest_pose()
assert max_diff(bpy.data.objects["Hero Cam"].matrix_basis, expected_basis(final)) < 1e-6

# Undo: an undo step can hold an older camera transform than the live pose. After undo the
# camera must show the live pose again, not the restored one.
bpy.data.objects["Hero Cam"].matrix_basis = Matrix.Translation((9.0, 9.0, 9.0))  # "older" state
bpy.ops.ed.undo_push(message="older pose")
session.applier().reapply()
poll()
assert max_diff(bpy.data.objects["Hero Cam"].matrix_basis, expected_basis(final)) < 1e-6
bpy.ops.ed.undo_push(message="later edit")
assert bpy.ops.ed.undo() == {'FINISHED'}
assert bpy.data.objects["Hero Cam"].matrix_basis.translation.x == 9.0  # undo restored it
poll()
assert max_diff(bpy.data.objects["Hero Cam"].matrix_basis, expected_basis(final)) < 1e-6, "undo: pose not re-applied"

# File reload: save with a stale camera and smoothing off, diverge the session, reopen. The same
# session keeps running with its timer, takes the file's smoothing and re-applies the pose.
bpy.data.objects["Hero Cam"].matrix_basis = Matrix.Identity(4)
bpy.context.scene.vcam_props.smoothing = False
path = os.path.join(tempfile.mkdtemp(), "robust.blend")
assert bpy.ops.wm.save_as_mainfile(filepath=path) == {'FINISHED'}
live.set_smoothing(True)
assert bpy.ops.wm.open_mainfile(filepath=path) == {'FINISHED'}
assert session.current() is live and live.running()
assert bpy.app.timers.is_registered(session._poll)
assert live.smoothing() is None, "the reloaded file's smoothing setting was not applied"
poll()
assert max_diff(bpy.data.objects["Hero Cam"].matrix_basis, expected_basis(final)) < 1e-6, "reload: pose not re-applied"
assert published()[2:] == (apply.ERROR_NONE, "Hero Cam"), published()

# Camera deleted in the UI: the object lingers outside the scene (the target pointer still uses
# it), so it must not be driven; the device gets "no camera" and the panel warns.
scene = bpy.context.scene
scene.vcam_props.target_camera = bpy.data.objects["Hero Cam"]
cam = bpy.data.objects["Hero Cam"]
cam.matrix_basis = Matrix.Identity(4)
with bpy.context.temp_override(selected_objects=[cam], active_object=cam, object=cam):
    assert bpy.ops.object.delete() == {'FINISHED'}
assert scene.vcam_props.target_camera is not None  # still referenced, not in the scene
camera, warning = apply.camera_status(scene)
assert camera is None and "Hero Cam" in warning and "deleted" in warning, warning
session.applier().reapply()
poll()
assert published()[2:] == (apply.ERROR_NO_CAMERA, None), published()
assert cam.matrix_basis == Matrix.Identity(4), "a deleted camera was driven"
assert bpy.ops.vcam.origin_clear.poll() is False

# A new camera picked in the panel is driven again.
new = bpy.data.objects.new("Replacement", bpy.data.cameras.new("Replacement"))
scene.collection.objects.link(new)
scene.vcam_props.target_camera = new
session.applier().reapply()
poll()
assert published()[2:] == (apply.ERROR_NONE, "Replacement"), published()
assert new.parent == bpy.data.objects["My Rig"]  # the renamed rig, found by its marker

# An empty file: no camera at all, nothing raises, the device is told.
assert bpy.ops.wm.read_homefile(use_empty=True) == {'FINISHED'}
assert session.current() is live
camera, warning = apply.camera_status(bpy.context.scene)
assert camera is None and warning.startswith("No camera"), warning
poll()
assert published()[2:] == (apply.ERROR_NO_CAMERA, None), published()

child.terminate()
child.wait(timeout=10)
assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
assert all(h not in getattr(bpy.app.handlers, n) for n, h in session._HANDLERS), "handlers left behind"
print(f"VCAM_ADDON_ROBUST_OK final_seq={final['seq']} rename=cam+rig undo=reapplied reload=same_session "
      f"deleted=no_camera empty_file=no_camera")
