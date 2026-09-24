# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check of what the N-panel shows and does (task 1.3.3; FR-BL-004).

Needs the fake iPhone binary (task 1.2.7). Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_panel.py

Drives the panel's operators and state with the fake iPhone streaming: pairing start/cancel,
tracking state, latency and clock jitter, Set/Clear origin from Blender, and the smoothing
toggle. (The panel's drawing is checked visually in a GUI run; see the loop log.)
"""

import importlib
import json
import os
import subprocess
import time

import addon_utils
import bpy
from mathutils import Vector

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOTION = os.path.join(ROOT, "testdata", "motion")
FAKE = os.environ["FAKE_IPHONE"]

addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")
apply = importlib.import_module(MODULE + ".core.apply")
with open(os.path.join(MOTION, "scripted.json"), encoding="utf-8") as f:
    script = json.load(f)
keys = {k["name"]: k for k in script["keyposes"]}
scene = bpy.context.scene
camera = scene.camera


def poll_until(what, cond, timeout=10.0):
    deadline = time.monotonic() + timeout
    while not cond():
        assert time.monotonic() < deadline, f"timed out waiting for {what}"
        session._poll()
        time.sleep(0.002)


# Smoothing set before the session starts is applied at start; toggling reaches the session.
scene.vcam_props.smoothing = True
assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
assert live.smoothing() is not None
scene.vcam_props.smoothing = False
assert live.smoothing() is None

# Pairing: start shows a code, cancel withdraws it, start again for the device.
assert bpy.ops.vcam.origin_set.poll() is False  # no device yet
assert bpy.ops.vcam.pairing_start() == {'FINISHED'}
first = live.pairing_code()
assert first is not None and len(first) == 6
assert bpy.ops.vcam.pairing_start.poll() is False
assert bpy.ops.vcam.pairing_cancel() == {'FINISHED'}
assert live.pairing_code() is None
assert bpy.ops.vcam.pairing_start() == {'FINISHED'}
code = live.pairing_code()

child = subprocess.Popen(
    [FAKE, "--host", f"127.0.0.1:{live.port()}", "--state", os.path.join(session.config_dir(), "k"),
     "--code", code, "--motion", os.path.join(MOTION, "scripted.bin"), "--rate", "60", "--linger", "1.5"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

# Device, tracking state and latency (once the clock estimate exists).
poll_until("device", lambda: session.state.session_id is not None)
assert live.pairing_code() is None, "a successful pairing consumes the code"
poll_until("clock sync", lambda: session.state.latency_ms is not None)
assert session.state.device_name == "Fake iPhone"
assert session.state.tracking_state == 5
latency, jitter = session.state.latency_ms, session.state.clock_jitter_ms
assert 0.0 <= latency < 100.0 and 0.0 <= jitter < 20.0, (latency, jitter)

# Set origin from Blender inside the pan hold: that pose becomes the zero, so the camera sits at
# the origin facing +Y; the zero is on the rig object.
pan = keys["pan"]
poll_until("pan hold", lambda: session.applier().applied_seq in range(pan["frame"] - 20, pan["frame"] - 5))
assert bpy.ops.vcam.origin_set() == {'FINISHED'}
session._poll()
origin = bpy.data.objects[apply.ORIGIN_NAME]
assert apply.ZERO_YAW_KEY in origin
local = camera.matrix_basis
assert local.translation.length < 1e-6, local
forward = local.to_3x3() @ Vector((0.0, 0.0, -1.0))
assert abs(forward.y - 1.0) < 1e-6, forward  # heading zeroed to +Y, level

# Clear origin: the rig follows the raw device pose again.
assert bpy.ops.vcam.origin_clear() == {'FINISHED'}
assert apply.ZERO_YAW_KEY not in origin
session._poll()
pose = live.latest_pose()
expected = apply.pose_matrix(pose["smoothed_position"], pose["smoothed_orientation"])
err = max(abs(a - b) for ra, rb in zip(camera.matrix_basis, expected) for a, b in zip(ra, rb))
assert err < 1e-6, err
assert bpy.ops.vcam.origin_clear.poll() is False

deadline = time.monotonic() + 30
while child.poll() is None:
    assert time.monotonic() < deadline
    session._poll()
    time.sleep(0.002)
assert child.returncode == 0, child.stderr.read()
poll_until("session end", lambda: session.state.session_id is None)
assert bpy.ops.vcam.origin_set.poll() is False
assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(f"VCAM_ADDON_PANEL_OK latency_ms={latency:.2f} jitter_ms={jitter:.3f} pairing=start/cancel/start "
      f"set_origin=zeroed clear_origin=raw smoothing=toggled")
