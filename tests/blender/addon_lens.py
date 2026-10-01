# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: device lens controls, sensor presets and the applied lens (task 2.4).

FR-BL-005, FR-CTL-001/003/009, LNS-001/002, vcp.md §6.2/§6.4. Needs the fake iPhone binary.
Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_lens.py

Timers don't run in a background script, so the test calls the session poll itself.

- Over the wire: the fake iPhone's `--lens/--focus/--fstop/--dof` land on the target camera's
  data, on the main thread only, and the STATUS it receives reports the camera's values. The
  factory camera's AUTO fit is reported as HORIZONTAL, so the device gets a FOV.
- A sensor preset changed in Blender while the device is connected reaches the device in the
  next STATUS (host-side changes are reported, not the device's request).
- A stub session: a resent or older `state_seq` changes nothing, an edit made in Blender
  survives a resend and a later state that repeats the same request, a state without lens bits
  keeps the lens, DoF off keeps the f-stop, and invalid values never reach the camera.
- The sensor presets set `sensor_width` and `sensor_fit` on the target camera, also when the
  target camera changes; "Camera" leaves it alone.
- The N-panel's Lens section shows the camera's values and the preset control.
"""

import importlib
import math
import os
import struct
import subprocess
import threading
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
panels = importlib.import_module(MODULE + ".ui.panels")

scene = bpy.context.scene
props = scene.vcam_props
camera = scene.camera
cam = camera.data
assert cam.sensor_fit == 'AUTO' and (scene.render.resolution_x, scene.render.resolution_y) == (1920, 1080)
assert props.sensor_preset == 'CAMERA', "the default preset leaves the camera's sensor alone"


def f32(value):
    return struct.unpack("<f", struct.pack("<f", float(value)))[0]


def lens_values():
    dof = cam.dof
    return cam.lens, dof.focus_distance, dof.aperture_fstop, dof.use_dof, cam.sensor_width, cam.sensor_fit


# Every camera data write of the device path goes through apply_lens; record the thread it runs on.
lens_writes = []
real_apply_lens = apply.apply_lens


def recording_apply_lens(target, changes):
    written = real_apply_lens(target, changes)
    lens_writes.append((threading.current_thread() is threading.main_thread(), dict(changes), written))
    return written


apply.apply_lens = recording_apply_lens

assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
state_file = os.path.join(session.config_dir(), "fake-iphone.key")
code = live.enable_pairing()


def run_fake(*extra, observe=None):
    """Streams the scripted motion from the fake iPhone; returns its FAKE_IPHONE_DONE fields."""
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
    deadline = time.monotonic() + 30
    while child.poll() is None:
        assert time.monotonic() < deadline, "fake iPhone did not finish"
        session._poll()
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
    done = next(line for line in out.splitlines() if line.startswith("FAKE_IPHONE_DONE"))
    return dict(kv.split("=", 1) for kv in done.split()[1:])


def reported(fields):
    return {k: f32(fields[k]) for k in ("lens_mm", "focus_m", "fstop", "sensor_width_mm", "aspect")}


def actual():
    render = scene.render
    aspect = render.resolution_x * render.pixel_aspect_x / (render.resolution_y * render.pixel_aspect_y)
    return {
        "lens_mm": f32(cam.lens),
        "focus_m": f32(cam.dof.focus_distance),
        "fstop": f32(cam.dof.aperture_fstop),
        "sensor_width_mm": f32(cam.sensor_width),
        "aspect": f32(aspect),
    }


def fov_fields(values):
    width, lens_mm, aspect = values["sensor_width_mm"], values["lens_mm"], values["aspect"]
    fov = math.degrees(2 * math.atan(width / (2 * lens_mm)))
    equivalent = lens_mm * 43.27 / math.hypot(width, width / aspect)
    return f"{fov:.2f}", f"{equivalent:.2f}"


# Run 1: the device's lens over the real wire, onto the factory camera (AUTO fit, 50 mm, DoF off).
cam.dof.use_dof = False
fields = run_fake("--code", code, "--lens", "85", "--focus", "2", "--fstop", "1.4", "--dof", "1")
assert (f32(cam.lens), f32(cam.dof.focus_distance), f32(cam.dof.aperture_fstop), cam.dof.use_dof) == (
    85.0,
    2.0,
    f32(1.4),
    True,
), lens_values()
assert cam.sensor_fit == 'AUTO', "a device lens request doesn't touch the sensor"
assert lens_writes and all(main for main, _, _ in lens_writes), lens_writes
assert fields["applied_lens"] == "1" and reported(fields) == actual(), (fields, actual())
assert (fields["dof"], fields["sensor_fit"]) == ("1", "0"), fields  # AUTO on a 16:9 render: horizontal
wire = actual()
assert (fields["hfov_deg"], fields["equiv_mm"]) == fov_fields(wire), fields
auto_fov = fields["hfov_deg"]

# Run 2: a preset changed in Blender mid-session reaches the device in the next STATUS.
writes_before = len(lens_writes)
changed = []


def change_preset():
    if not changed and session.state.session_id is not None and session.applier().controls.state_seq >= 1:
        props.sensor_preset = 'ALEXA_35_OG'
        changed.append(session.applier().controls.state_seq)


fields = run_fake("--lens", "85", "--focus", "2", "--fstop", "1.4", "--dof", "1", observe=change_preset)
assert changed, "the preset was never changed during the session"
assert (f32(cam.sensor_width), cam.sensor_fit) == (f32(27.99), 'HORIZONTAL'), lens_values()
assert fields["applied_lens"] == "1" and reported(fields) == actual(), (fields, actual())
assert fields["sensor_width_mm"] == "27.99" and fields["sensor_fit"] == "0", fields
assert (fields["hfov_deg"], fields["equiv_mm"]) == fov_fields(actual()), fields
# The new session re-sends the same lens, which the camera already has: no write.
assert all(not written for _, _, written in lens_writes[writes_before:]), lens_writes[writes_before:]
assert all(main for main, _, _ in lens_writes), lens_writes


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


def control(seq, **fields):
    base = {"state_seq": seq, "motion_scale": None, "lock_flags": None, "origin_epoch": None}
    return {**base, "lens_mm": None, "focus_distance_m": None, "fstop": None, "dof_on": None, **fields}


full = {"lens_mm": 50.0, "focus_distance_m": 4.0, "fstop": 2.8, "dof_on": True}
stub, applier = Stub(), apply.Applier()
stub.pose = {"seq": 1, "smoothed_position": (0, 0, 0), "smoothed_orientation": (0, 0, 0, 1), "tracking_state": 5}
tick = iter(i * 0.1 for i in range(1000))
stub.control = control(5, motion_scale=1.0, lock_flags=0, origin_epoch=0, **full)
applier.tick(stub, 21, scene, next(tick))
assert (cam.lens, cam.dof.focus_distance, f32(cam.dof.aperture_fstop), cam.dof.use_dof) == (50.0, 4.0, f32(2.8), True)
assert stub.calls[-1][2] == 5 and stub.lens[-1] == apply.applied_lens(scene, camera), stub.lens[-1]
# A resend of the same state_seq with other values, and an older state_seq, change nothing.
writes_before = len(lens_writes)
stub.control = control(5, lens_mm=35.0)
applier.tick(stub, 21, scene, next(tick))
stub.control = control(4, lens_mm=35.0, dof_on=False)
applier.tick(stub, 21, scene, next(tick))
assert (cam.lens, cam.dof.use_dof, len(lens_writes)) == (50.0, True, writes_before), lens_values()
# An edit made in Blender survives a resend, a state without lens bits, and a later complete
# state that repeats the same request; STATUS reports the edit.
cam.lens = 40.0
stub.control = control(5, **full)
applier.tick(stub, 21, scene, next(tick))
stub.control = control(6, motion_scale=2.0)
applier.tick(stub, 21, scene, next(tick))
stub.control = control(7, **full)
applier.tick(stub, 21, scene, next(tick))
assert cam.lens == 40.0 and len(lens_writes) == writes_before, lens_values()
assert stub.lens[-1]["lens_mm"] == 40.0 and stub.calls[-1][2] == 7, (stub.lens[-1], stub.calls[-1])
# A delayed copy of an older state after a newer one (VAL-CROSS-009): the newer focal stays.
stub.control = control(8, lens_mm=50.0)
applier.tick(stub, 21, scene, next(tick))
stub.control = control(9, lens_mm=35.0)
applier.tick(stub, 21, scene, next(tick))
stub.control = control(8, lens_mm=50.0)
applier.tick(stub, 21, scene, next(tick))
assert cam.lens == 35.0 and applier.controls.state_seq == 9 and stub.calls[-1][2] == 9, lens_values()
# DoF off keeps the f-stop.
stub.control = control(10, dof_on=False)
applier.tick(stub, 21, scene, next(tick))
assert cam.dof.use_dof is False and f32(cam.dof.aperture_fstop) == f32(2.8), lens_values()
# Invalid values never reach the camera (Rust rejects them first; this is the add-on's own check).
before = lens_values()
for seq, bad in enumerate(
    (
        {"lens_mm": math.nan},
        {"lens_mm": -35.0},
        {"lens_mm": 85.0, "focus_distance_m": 0.0},
        {"fstop": math.inf},
        {"dof_on": 1},
    ),
    start=11,
):
    stub.control = control(seq, **bad)
    applier.tick(stub, 21, scene, next(tick))
    assert lens_values() == before, (bad, lens_values())
# A request made while there is no camera waits for one.
scene.camera = None
stub.control = control(20, lens_mm=70.0)
applier.tick(stub, 21, scene, next(tick))
assert cam.lens == 35.0 and stub.calls[-1][3] == apply.ERROR_NO_CAMERA
scene.camera = camera
applier.tick(stub, 21, scene, next(tick))
assert cam.lens == 70.0, lens_values()
assert all(main for main, _, _ in lens_writes), lens_writes

# Sensor presets on the target camera (LNS-002).
widths = {}
for preset, width in (('SUPER_35', 24.89), ('FULL_FRAME', 36.0), ('ALEXA_35_OG', 27.99)):
    cam.sensor_fit = 'VERTICAL'
    props.sensor_preset = preset
    assert (f32(cam.sensor_width), cam.sensor_fit) == (f32(width), 'HORIZONTAL'), (preset, lens_values())
    widths[preset] = round(cam.sensor_width, 2)
props.sensor_custom_width = 30.0  # not applied while another preset is selected
assert f32(cam.sensor_width) == f32(27.99), lens_values()
props.sensor_preset = 'CUSTOM'
assert (f32(cam.sensor_width), cam.sensor_fit) == (f32(30.0), 'HORIZONTAL'), lens_values()
props.sensor_custom_width = 31.5
assert f32(cam.sensor_width) == f32(31.5), lens_values()
widths['CUSTOM'] = round(cam.sensor_width, 2)
props.sensor_preset = 'CAMERA'
cam.sensor_width, cam.sensor_fit = 36.0, 'AUTO'
props.sensor_custom_width = 20.0
assert (cam.sensor_width, cam.sensor_fit) == (36.0, 'AUTO'), "Camera leaves the sensor alone"
# Picking another target camera gives it the scene's preset.
other = bpy.data.objects.new("Other Camera", bpy.data.cameras.new("Other Camera"))
scene.collection.objects.link(other)
props.sensor_preset = 'SUPER_35'
props.target_camera = other
assert (f32(other.data.sensor_width), other.data.sensor_fit) == (f32(24.89), 'HORIZONTAL')
props.target_camera = None
props.sensor_preset = 'CAMERA'
cam.sensor_width, cam.sensor_fit = 36.0, 'AUTO'


class Layout:
    """Records what the N-panel's draw() shows."""

    def __init__(self, sink):
        self.__dict__["sink"] = sink

    def __setattr__(self, _name, _value):
        pass

    def _nested(self, *_args, **_kwargs):
        return Layout(self.sink)

    box = column = row = _nested

    def label(self, text="", **_kwargs):
        self.sink["labels"].append(text)

    def prop(self, data, name, **_kwargs):
        self.sink["props"].append((name, getattr(data, name)))

    def operator(self, *_args, **_kwargs):
        return type("Op", (), {})()


def draw_panel():
    sink = {"labels": [], "props": []}
    panels.VCAM_PT_main_panel.draw(type("Panel", (), {"layout": Layout(sink)})(), bpy.context)
    return sink


cam.lens, cam.dof.focus_distance, cam.dof.aperture_fstop, cam.dof.use_dof = 85.0, 2.0, 1.4, True
sink = draw_panel()
lens_at = sink["labels"].index("Lens")
assert sink["labels"][lens_at + 1 : lens_at + 7] == [
    "Focal length: 85 mm",
    "Focus distance: 2.00 m",
    "Aperture: f/1.4",
    "Depth of field: on",
    "Sensor: 36 mm, auto fit (horizontal)",
    f"FOV {2 * math.degrees(math.atan(36 / 170)):.1f}°, 35 mm equivalent 89 mm",
], sink["labels"]
assert ("sensor_preset", 'CAMERA') in sink["props"] and "sensor_custom_width" not in dict(sink["props"])
props.sensor_preset = 'CUSTOM'
cam.lens = 24.0
sink = draw_panel()
assert "Focal length: 24 mm" in sink["labels"] and ("sensor_custom_width", 20.0) in sink["props"], sink

apply.apply_lens = real_apply_lens
assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(
    f"VCAM_ADDON_LENS_OK wire=lens_mm:85,focus_m:2,fstop:1.4,dof:1 auto_fit=0 auto_hfov_deg={auto_fov} "
    f"host_preset_status_width={fields['sensor_width_mm']} writes={len(lens_writes)} main_thread=all "
    f"presets={','.join(f'{k}:{v}' for k, v in widths.items())} stale=ignored duplicate=ignored invalid=ignored"
)
