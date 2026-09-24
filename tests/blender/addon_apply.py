# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: the add-on drives the camera from vcam_native (task 1.3.1; FR-BL-002).

Needs the fake iPhone binary (task 1.2.7). Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_apply.py

Timers don't run in a background script, so the test calls the session poll itself. It checks
the scene camera's `matrix_world` against every keypose in `testdata/motion/scripted.json`
(computed independently by `tools/gen_testdata.py`), and the STATUS the fake device received.
The CI version, with the VCam_Origin rig, is task 1.3.5.
"""

import importlib
import json
import os
import subprocess
import time

import addon_utils
import bpy

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOTION = os.path.join(ROOT, "testdata", "motion")
FAKE = os.environ["FAKE_IPHONE"]

addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")
apply = importlib.import_module(MODULE + ".core.apply")
with open(os.path.join(MOTION, "scripted.json"), encoding="utf-8") as f:
    script = json.load(f)

camera = bpy.context.scene.camera
assert camera is not None and camera.type == 'CAMERA'

assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
code = live.enable_pairing()
state_file = os.path.join(session.config_dir(), "fake-iphone.key")
child = subprocess.Popen(
    [FAKE, "--host", f"127.0.0.1:{live.port()}", "--state", state_file, "--code", code,
     "--motion", os.path.join(MOTION, "scripted.bin"), "--rate", "120", "--linger", "1.0"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

# Each keypose ends a 30-frame hold; any seq inside the hold shows exactly that pose.
holds = {k["name"]: range(k["frame"] - 28, k["frame"] + 2) for k in script["keyposes"]}
seen = {}
deadline = time.monotonic() + 30
while child.poll() is None:
    assert time.monotonic() < deadline, "fake iPhone did not finish"
    session._poll()
    seq = session._applier.applied_seq
    for name, hold in holds.items():
        if name not in seen and seq in hold:
            seen[name] = [list(row) for row in camera.matrix_world]
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

worst = 0.0
for key in script["keyposes"]:
    assert key["name"] in seen, f"keypose {key['name']} was never applied: {sorted(seen)}"
    got = seen[key["name"]]
    worst = max(worst, max(abs(g - w) for gr, wr in zip(got, key["matrix_world"]) for g, w in zip(gr, wr)))
assert worst < 1e-5, worst
# The device saw what the host applied, and on which camera (vcp.md §6.4).
done = next(line for line in out.splitlines() if line.startswith("FAKE_IPHONE_DONE"))
fields = dict(kv.split("=", 1) for kv in done.split()[1:])
assert int(fields["applied_pose_seq"]) >= len(script["frames"]) - 60, done
assert fields["camera"] == camera.name, done

# No camera: nothing is applied and STATUS reports error 1 (no camera) without a name.
class Stub:
    def __init__(self):
        self.calls = []
    def latest_pose(self):
        return {"seq": 1, "smoothed_position": (1, 2, 3), "smoothed_orientation": (0, 0, 0, 1)}
    def update_status(self, *args):
        self.calls.append(args)

bpy.context.scene.camera = None
stub, applier = Stub(), apply.Applier()
applier.tick(stub, 9, bpy.context.scene, 0.0)
assert stub.calls == [(9, 0, 0, apply.ERROR_NO_CAMERA, None)], stub.calls
applier.tick(stub, 9, bpy.context.scene, 0.1)
assert len(stub.calls) == 1, "unchanged STATUS is throttled"
applier.tick(stub, 9, bpy.context.scene, 0.6)
assert len(stub.calls) == 2, "STATUS repeats at 2 Hz"

assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(f"VCAM_ADDON_APPLY_OK keyposes={len(seen)} max_err={worst:.2e} "
      f"applied_pose_seq={fields['applied_pose_seq']} camera={fields['camera']}")
