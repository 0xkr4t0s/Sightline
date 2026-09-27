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
- Hold last good pose (task 1.3.6, FR-TRK-002): the fake iPhone sends a limited span
  (`testdata/rig/hold.json` "scripted"); with the option on the camera stays on the last normal
  keypose throughout and resumes after it, with it off the degraded poses are applied.
- Lens (task 2.4, FR-CTL-009): the fake iPhone's lens flags arrive as `latest_control()` keys,
  and the STATUS it receives carries the camera's actual lens (vcp.md §6.4), with the FOV and
  35 mm equivalent derived from it.

CI runs this, `addon_panel.py` and `addon_robust.py` on Linux, Windows and macOS against a
release build of the fake iPhone (`blender-smoke` job in `.github/workflows/ci.yml`, task 1.3.5).
"""

import importlib
import json
import math
import os
import struct
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
rig = importlib.import_module(MODULE + ".core.rig")
with open(os.path.join(MOTION, "scripted.json"), encoding="utf-8") as f:
    script = json.load(f)
with open(os.path.join(ROOT, "testdata", "rig", "rig_cases.json"), encoding="utf-8") as f:
    rig_doc = json.load(f)
with open(os.path.join(ROOT, "testdata", "rig", "hold.json"), encoding="utf-8") as f:
    hold_doc = json.load(f)
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


def run_fake(*extra, observe=None):
    """Streams the script from the fake iPhone; returns ({keypose: (local, world)}, DONE fields).

    `observe()` runs after every poll."""
    child = subprocess.Popen(
        [
            FAKE,
            "--host",
            f"127.0.0.1:{live.port()}",
            "--state",
            state_file,
            "--motion",
            os.path.join(MOTION, "scripted.bin"),
            "--rate",
            "120",
            "--linger",
            "1.0",
            *extra,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
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
        if observe is not None:
            observe()
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
    return max(abs(x - y) for ra, rb in zip(a, b, strict=True) for x, y in zip(ra, rb, strict=True))


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
seen, fields = run_fake(
    "--scale", str(sc["motion_scale"]), "--locks", str(sc["lock_flags"]), "--set-origin-at", str(sc["set_origin_at"])
)
scripted_err = 0.0
for name in sc["cases"]:
    case = rig_cases[name]
    key = name.removeprefix("scripted_")
    assert key in seen, f"keypose {key} was never applied: {sorted(seen)}"
    expected = apply.pose_matrix(case["expected_position"], case["expected_orientation"])
    scripted_err = max(scripted_err, max_diff(seen[key][0], expected))
assert scripted_err < 1e-5, scripted_err
assert fields["control_ack"] == "2", fields  # Set origin was state_seq 2

# Runs 3 and 4 (task 1.3.6): a limited span over the tilt move, controls back to default.
hs = hold_doc["scripted"]
keys = {k["name"]: k for k in script["keyposes"]}
apply.clear_zero(origin)
limited = ("--limited", "{}-{}".format(*hs["limited_frames"]))


class HoldWatch:
    """What the host did after each poll, by the seq of the pose that poll handled (seq = frame + 1)."""

    def __init__(self):
        self.limited_ticks = self.holding_ticks = self.holding_when_normal = 0
        self.held_err = 0.0

    def __call__(self):
        applier = session._applier
        if session.state.session_id is None or applier.session_id != session.state.session_id:
            return
        first, end = hs["limited_frames"]
        if not first + 1 <= applier._seen_seq < end + 1:
            self.holding_when_normal += applier.holding
            return
        self.limited_ticks += 1
        assert session.state.tracking_state == hs["tracking_state"], session.state  # the panel's reason
        if applier.holding:
            self.holding_ticks += 1
            held = keys[hs["held_keypose"]]["matrix_world"]
            self.held_err = max(self.held_err, max_diff(camera.matrix_basis, held))


assert bpy.context.scene.vcam_props.hold_last_good, "Hold Last Good Pose is on by default"
watch_on = HoldWatch()
seen, fields = run_fake(*limited, observe=watch_on)
assert watch_on.limited_ticks > 20 and watch_on.holding_ticks == watch_on.limited_ticks, vars(watch_on)
assert watch_on.holding_when_normal == 0, vars(watch_on)
assert watch_on.held_err < 1e-5, vars(watch_on)
assert not set(hs["hidden_keyposes"]) & set(seen), sorted(seen)
hold_err = 0.0
for name in hs["resumed_keyposes"]:
    assert name in seen, f"keypose {name} not applied after the limited span: {sorted(seen)}"
    hold_err = max(hold_err, max_diff(seen[name][0], keys[name]["matrix_world"]))
assert hold_err < 1e-5, hold_err

bpy.context.scene.vcam_props.hold_last_good = False
watch = HoldWatch()
seen, _ = run_fake(*limited, observe=watch)
assert watch.limited_ticks > 20 and watch.holding_ticks == 0, vars(watch)
for name in hs["hidden_keyposes"]:  # applied as ARKit reported it
    assert name in seen and max_diff(seen[name][0], keys[name]["matrix_world"]) < 1e-5, sorted(seen)
bpy.context.scene.vcam_props.hold_last_good = True

# Run 5 (task 2.4): lens controls over the real wire, and the applied lens in STATUS: the camera's
# values after the host applied the request (`addon_lens.py` covers the application itself).
LENS_KEYS = (
    "lens_mm",
    "focus_distance_m",
    "fstop",
    "dof_on",
    "tap_u",
    "tap_v",
    "tap_seq",
    "rack_a_m",
    "rack_b_m",
    "rack_target",
    "rack_duration_ms",
    "rack_seq",
)
cam = camera.data
cam.lens, cam.sensor_width, cam.sensor_fit = 35.0, 24.89, 'HORIZONTAL'
cam.dof.use_dof, cam.dof.focus_distance, cam.dof.aperture_fstop = True, 4.0, 2.8


def f32(value):
    return struct.unpack("<f", struct.pack("<f", float(value)))[0]


class LensWatch:
    def __init__(self):
        self.controls = []

    def __call__(self):
        live_now = session.current()
        control = live_now.latest_control() if live_now is not None else None
        if control is not None and (not self.controls or control != self.controls[-1]):
            self.controls.append(control)


lens_watch = LensWatch()
_, lens_fields = run_fake(
    "--lens",
    "85",
    "--focus",
    "3",
    "--fstop",
    "2.8",
    "--dof",
    "1",
    "--tap",
    "0.25,0.75@60",
    "--rack",
    "2,8,B,1200@120",
    observe=lens_watch,
)
first, last = lens_watch.controls[0], lens_watch.controls[-1]
assert all(key in first for key in LENS_KEYS), sorted(first)
assert (first["tap_seq"], first["rack_seq"], first["rack_target"]) == (0, 0, 0), first
assert (last["state_seq"], last["tap_seq"], last["rack_seq"]) == (3, 1, 1), last
assert first["focus_distance_m"] == 3.0, first
want = {
    "lens_mm": 85.0,
    "focus_distance_m": None,  # a tap or rack hands the focus to the host (vcp.md §6.2)
    "fstop": f32(2.8),
    "dof_on": True,
    "tap_u": 0.25,
    "tap_v": 0.75,
    "rack_a_m": 2.0,
    "rack_b_m": 8.0,
    "rack_target": 2,
    "rack_duration_ms": 1200,
}
assert {k: last[k] for k in want} == want, last
assert lens_fields["control_ack"] == "3", lens_fields
render = bpy.context.scene.render
aspect = render.resolution_x * render.pixel_aspect_x / (render.resolution_y * render.pixel_aspect_y)
reported = {k: f32(lens_fields[k]) for k in ("lens_mm", "focus_m", "fstop", "sensor_width_mm", "aspect")}
actual = {
    "lens_mm": f32(cam.lens),
    "focus_m": f32(cam.dof.focus_distance),
    "fstop": f32(cam.dof.aperture_fstop),
    "sensor_width_mm": f32(cam.sensor_width),
    "aspect": f32(aspect),
}
assert lens_fields["applied_lens"] == "1" and reported == actual, (lens_fields, actual)
# The rack to B (8 m, 1200 ms from pose 120) has finished before the run ends (FR-CTL-002).
assert (actual["lens_mm"], actual["focus_m"], cam.dof.use_dof) == (85.0, 8.0, True), actual
assert (lens_fields["dof"], lens_fields["sensor_fit"]) == ("1", "0"), lens_fields
width, lens_mm = actual["sensor_width_mm"], actual["lens_mm"]
fov = math.degrees(2 * math.atan(width / (2 * lens_mm)))
equivalent = lens_mm * 43.27 / math.hypot(width, width / actual["aspect"])
assert (lens_fields["hfov_deg"], lens_fields["equiv_mm"]) == (f"{fov:.2f}", f"{equivalent:.2f}"), lens_fields


class Stub:
    """A session whose pose and CONTROL_STATE the test sets; records STATUS."""

    def __init__(self):
        self.calls, self.lens, self.pose, self.control = [], [], None, None

    def latest_pose(self):
        return self.pose

    def latest_control(self):
        return self.control

    def update_status(self, *args, **lens):
        self.calls.append(args)
        self.lens.append(lens)


def control(seq, scale, locks, epoch):
    return {"state_seq": seq, "motion_scale": scale, "lock_flags": locks, "origin_epoch": epoch}


# Set origin + motion scale + locks through real objects, against the "combined" rig vector.
case = rig_cases["combined"]
zp = case["zero_pose"]
stub, applier = Stub(), apply.Applier()
stub.pose = {
    "seq": 1,
    "smoothed_position": zp["position"],
    "smoothed_orientation": zp["orientation"],
    "tracking_state": 5,
}
stub.control = control(1, 1.0, 0, 7)  # first epoch in a session: not a Set origin
applier.tick(stub, 11, bpy.context.scene, 0.0)
stub.control = control(2, None, None, 8)  # operator pressed Set origin at the zero pose
applier.tick(stub, 11, bpy.context.scene, 0.1)
assert abs(origin[apply.ZERO_YAW_KEY] - case["zero_yaw"]) < 1e-9, origin[apply.ZERO_YAW_KEY]
stub.control = control(3, case["motion_scale"], case["lock_flags"], None)
stub.pose = {
    "seq": 2,
    "smoothed_position": case["position"],
    "smoothed_orientation": case["orientation"],
    "tracking_state": 5,
}
applier.tick(stub, 11, bpy.context.scene, 0.2)
rig_err = max_diff(camera.matrix_basis, apply.pose_matrix(case["expected_position"], case["expected_orientation"]))
assert rig_err < 1e-6, rig_err
assert stub.calls[-1] == (11, 2, 3, apply.ERROR_NONE, camera.name), stub.calls[-1]

# Hold (task 1.3.6): a limited pose isn't applied and STATUS keeps the held seq; a controls
# change still applies, to the held pose.
stub.pose = {"seq": 3, "smoothed_position": (9, 9, 9), "smoothed_orientation": (0, 0, 0, 1), "tracking_state": 2}
applier.tick(stub, 11, bpy.context.scene, 0.3)
assert (
    applier.holding
    and max_diff(camera.matrix_basis, apply.pose_matrix(case["expected_position"], case["expected_orientation"])) < 1e-6
)
stub.control = control(4, 1.0, 0, None)
applier.tick(stub, 11, bpy.context.scene, 0.4)
held = rig.local_pose(case["position"], case["orientation"], apply.read_zero(origin))
assert max_diff(camera.matrix_basis, apply.pose_matrix(*held)) < 1e-6, "controls not applied to the held pose"
assert stub.calls[-1] == (11, 2, 4, apply.ERROR_NONE, camera.name), stub.calls[-1]
assert stub.lens[-1] == apply.applied_lens(bpy.context.scene, camera) and len(stub.lens[-1]) == 7, stub.lens[-1]
# A lens value Blender allows but the wire doesn't (focus 0) leaves the lens block out.
cam.dof.focus_distance = 0.0
applier.tick(stub, 11, bpy.context.scene, 0.5)
assert stub.lens[-1] == {} and apply.applied_lens(bpy.context.scene, camera) is None, stub.lens[-1]

# No camera: nothing is applied and STATUS reports error 1 (no camera) without a name.
before = camera.matrix_basis.copy()
bpy.context.scene.camera = None
stub, applier = Stub(), apply.Applier()
stub.pose = {"seq": 1, "smoothed_position": (1, 2, 3), "smoothed_orientation": (0, 0, 0, 1), "tracking_state": 5}
applier.tick(stub, 9, bpy.context.scene, 0.0)
assert stub.calls == [(9, 0, 0, apply.ERROR_NO_CAMERA, None)], stub.calls
assert camera.matrix_basis == before
applier.tick(stub, 9, bpy.context.scene, 0.1)
assert len(stub.calls) == 1, "unchanged STATUS is throttled"
applier.tick(stub, 9, bpy.context.scene, 0.6)
assert len(stub.calls) == 2, "STATUS repeats at 2 Hz"

assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(
    f"VCAM_ADDON_APPLY_OK keyposes=5 max_err={worst:.2e} scripted_err={scripted_err:.2e} rig_err={rig_err:.2e} "
    f"applied_pose_seq={fields['applied_pose_seq']} camera={fields['camera']} "
    f"held_ticks={watch_on.holding_ticks} held_err={watch_on.held_err:.2e} resumed_err={hold_err:.2e} "
    f"lens_keys={','.join(k for k in LENS_KEYS if k in last)} "
    f"status_lens=lens_mm:{lens_fields['lens_mm']},focus_m:{lens_fields['focus_m']},fstop:{lens_fields['fstop']},"
    f"sensor_width_mm:{lens_fields['sensor_width_mm']},aspect:{lens_fields['aspect']},"
    f"hfov_deg:{lens_fields['hfov_deg']},equiv_mm:{lens_fields['equiv_mm']}"
)
