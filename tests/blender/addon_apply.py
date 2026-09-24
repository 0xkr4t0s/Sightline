# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: the add-on drives the camera rig from vcam_native (1.3.1, 1.3.2a).

Needs the fake iPhone binary (task 1.2.7). Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_apply.py

Timers don't run in a background script, so the test calls the session poll itself.

- The streamed keyposes land as the camera's local transform under a user-placed `VCam_Origin`
  (translated, turned and scaled), checked against `testdata/motion/scripted.json`.
- The STATUS the fake device received carries the applied seq, the control ack and the camera.
- A reconnect with scripted controls (Set origin, scale 2, lock height) over the real wire,
  checked against the `scripted_*` cases of `testdata/rig/rig_cases.json` (task 1.3.2b).
- A stub session drives Set origin + motion scale + locks through real Blender objects,
  checked against `testdata/rig/rig_cases.json`.

CI runs this, `addon_panel.py` and `addon_robust.py` on Linux, Windows and macOS against a
release build of the fake iPhone (`blender-smoke` job in `.github/workflows/ci.yml`, task 1.3.5).
"""

import importlib
import json
import os
import subprocess
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
with open(os.path.join(MOTION, "scripted.json"), encoding="utf-8") as f:
    script = json.load(f)
with open(os.path.join(ROOT, "testdata", "rig", "rig_cases.json"), encoding="utf-8") as f:
    rig_doc = json.load(f)
rig_cases = {c["name"]: c for c in rig_doc["cases"]}

camera = bpy.context.scene.camera
assert camera is not None and camera.type == 'CAMERA'
# The user placed the rig: the add-on must reuse it and compose on top of it.
origin = bpy.data.objects.new(apply.ORIGIN_NAME, None)
bpy.context.scene.collection.objects.link(origin)
origin.location = (1.0, 2.0, 0.5)
origin.rotation_euler = (0.0, 0.0, 1.5707963267948966)
origin.scale = (2.0, 2.0, 2.0)
bpy.context.view_layer.update()

assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
state_file = os.path.join(session.config_dir(), "fake-iphone.key")
# Each keypose ends a 30-frame hold; any seq inside the hold shows exactly that pose.
holds = {k["name"]: range(k["frame"] - 28, k["frame"] + 2) for k in script["keyposes"]}


def run_fake(*extra):
    """Streams the script from the fake iPhone; returns ({keypose: (local, world)}, DONE fields)."""
    child = subprocess.Popen(
        [FAKE, "--host", f"127.0.0.1:{live.port()}", "--state", state_file,
         "--motion", os.path.join(MOTION, "scripted.bin"), "--rate", "120", "--linger", "1.0", *extra],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    seen = {}
    deadline = time.monotonic() + 30
    while child.poll() is None:
        assert time.monotonic() < deadline, "fake iPhone did not finish"
        session._poll()
        seq = session._applier.applied_seq
        for name, hold in holds.items():
            if name not in seen and seq in hold:
                # matrix_world of a child is only re-evaluated by the depsgraph (every redraw in the GUI).
                bpy.context.view_layer.update()
                seen[name] = ([list(r) for r in camera.matrix_basis], [list(r) for r in camera.matrix_world])
        time.sleep(0.002)
    out, err = child.communicate()
    assert child.returncode == 0, err
    for _ in range(100):  # the host reports SessionEnded just after the device closes TCP
        session._poll()
        if session.state.session_id is None:
            break
        time.sleep(0.01)
    assert session.state.session_id is None, "session did not end"
    assert session.state.device_name == "Fake iPhone", session.state
    done = next(line for line in out.splitlines() if line.startswith("FAKE_IPHONE_DONE"))
    return seen, dict(kv.split("=", 1) for kv in done.split()[1:])


def max_diff(a, b):
    return max(abs(x - y) for ra, rb in zip(a, b) for x, y in zip(ra, rb))


# Run 1: pair, default controls (scale 1, no locks, no Set origin): local = device pose.
seen, fields = run_fake("--code", live.enable_pairing())
assert camera.parent == origin and bpy.data.objects.get(apply.ORIGIN_NAME + ".001") is None
worst = 0.0
for key in script["keyposes"]:
    assert key["name"] in seen, f"keypose {key['name']} was never applied: {sorted(seen)}"
    local, world = seen[key["name"]]
    expected_world = origin.matrix_world @ Matrix(key["matrix_world"])
    worst = max(worst, max_diff(local, key["matrix_world"]), max_diff(world, expected_world))
assert worst < 1e-5, worst
# The device saw what the host applied, and on which camera (vcp.md §6.4).
assert int(fields["applied_pose_seq"]) >= len(script["frames"]) - 60, fields
assert fields["camera"] == camera.name, fields
assert fields["control_ack"] == "1", fields  # the fake's first and only CONTROL_STATE

# Run 2 (task 1.3.2b): reconnect with the stored pairing and scripted controls over the real
# wire — Set origin inside the pan hold, motion scale 2, lock height — against the rig vectors.
sc = rig_doc["scripted"]
seen, fields = run_fake("--scale", str(sc["motion_scale"]), "--locks", str(sc["lock_flags"]),
                        "--set-origin-at", str(sc["set_origin_at"]))
scripted_err = 0.0
for name in sc["cases"]:
    case = rig_cases[name]
    key = name.removeprefix("scripted_")
    assert key in seen, f"keypose {key} was never applied: {sorted(seen)}"
    expected = apply.pose_matrix(case["expected_position"], case["expected_orientation"])
    scripted_err = max(scripted_err, max_diff(seen[key][0], expected))
assert scripted_err < 1e-5, scripted_err
assert fields["control_ack"] == "2", fields  # Set origin was state_seq 2


class Stub:
    """A session whose pose and CONTROL_STATE the test sets; records STATUS."""

    def __init__(self):
        self.calls, self.pose, self.control = [], None, None

    def latest_pose(self):
        return self.pose

    def latest_control(self):
        return self.control

    def update_status(self, *args):
        self.calls.append(args)


def control(seq, scale, locks, epoch):
    return {"state_seq": seq, "motion_scale": scale, "lock_flags": locks, "origin_epoch": epoch}


# Set origin + motion scale + locks through real objects, against the "combined" rig vector.
case = rig_cases["combined"]
zp = case["zero_pose"]
stub, applier = Stub(), apply.Applier()
stub.pose = {"seq": 1, "smoothed_position": zp["position"], "smoothed_orientation": zp["orientation"]}
stub.control = control(1, 1.0, 0, 7)  # first epoch in a session: not a Set origin
applier.tick(stub, 11, bpy.context.scene, 0.0)
stub.control = control(2, None, None, 8)  # operator pressed Set origin at the zero pose
applier.tick(stub, 11, bpy.context.scene, 0.1)
assert abs(origin[apply.ZERO_YAW_KEY] - case["zero_yaw"]) < 1e-9, origin[apply.ZERO_YAW_KEY]
stub.control = control(3, case["motion_scale"], case["lock_flags"], None)
stub.pose = {"seq": 2, "smoothed_position": case["position"], "smoothed_orientation": case["orientation"]}
applier.tick(stub, 11, bpy.context.scene, 0.2)
rig_err = max_diff(camera.matrix_basis, apply.pose_matrix(case["expected_position"], case["expected_orientation"]))
assert rig_err < 1e-6, rig_err
assert stub.calls[-1] == (11, 2, 3, apply.ERROR_NONE, camera.name), stub.calls[-1]

# No camera: nothing is applied and STATUS reports error 1 (no camera) without a name.
before = camera.matrix_basis.copy()
bpy.context.scene.camera = None
stub, applier = Stub(), apply.Applier()
stub.pose = {"seq": 1, "smoothed_position": (1, 2, 3), "smoothed_orientation": (0, 0, 0, 1)}
applier.tick(stub, 9, bpy.context.scene, 0.0)
assert stub.calls == [(9, 0, 0, apply.ERROR_NO_CAMERA, None)], stub.calls
assert camera.matrix_basis == before
applier.tick(stub, 9, bpy.context.scene, 0.1)
assert len(stub.calls) == 1, "unchanged STATUS is throttled"
applier.tick(stub, 9, bpy.context.scene, 0.6)
assert len(stub.calls) == 2, "STATUS repeats at 2 Hz"

assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(f"VCAM_ADDON_APPLY_OK keyposes=5 max_err={worst:.2e} scripted_err={scripted_err:.2e} rig_err={rig_err:.2e} "
      f"applied_pose_seq={fields['applied_pose_seq']} camera={fields['camera']}")
