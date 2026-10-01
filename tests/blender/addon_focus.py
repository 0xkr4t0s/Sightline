# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: tap-to-focus and the host-run A/B rack (task 2.4; FR-CTL-002, vcp.md §6.2).

Needs the fake iPhone binary. Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_focus.py

Timers don't run in a background script, so the test calls the session poll itself and times it.
The 50 ms limit (NFR-PERF-002) is checked on wall time (perf_counter), so a poll blocked on a
lock or a join fails even though it burns no CPU. One run can be hit by a shared CI runner
pre-empting Blender (once seen at 52.6 ms), so when a poll reaches 50 ms the two timing runs
(tap, then rack and tap) are repeated once and the test fails only if the repeat also has a poll
of 50 ms or more: a deterministic block recurs, a one-off pre-emption does not. Per-poll CPU time
is printed for information only, with the clock named (thread_time, or process_time where
Blender's Python lacks it, as on macOS; process_time also counts the native threads).

This test runs with streaming off (a background Blender never streams), so it covers the pose,
tap and rack path, not the GPU readback that NFR-PERF-002 also bounds; that is the render tests'
and the GUI run's job.

Known scene: the rig at the world origin, so the fake iPhone's scripted start pose puts the
camera (24 mm, 36 mm sensor, 1920×1080) at (0, 0, 1.6) looking along +Y. "Near", a 0.8 m cube,
has its front face 1.1 m ahead on the view axis. "Far" has its front face 4.6 m deep, under the
picture point (0.75, 0.25) (right of centre, above it): its euclidean distance is 5.01 m, and
with v measured from the bottom the ray would miss.

- Over the wire: `--tap 0.75,0.25@15` sets the focus to 4.6 m along the view axis (the first
  state's baseline tap_seq doesn't cast), DoF stays off, STATUS reports it. `--rack 1,6,B,1000`
  then moves the focus from 1 m to 6 m over ~1 s, monotonically, through the 500 ms resends,
  and ends at 6.0; a later tap with the camera looking at empty sky misses and keeps 6 m. No
  poll during the rack or the taps takes 50 ms of wall time or more (in both runs, see above).
- A stub session in the same scene: the same tap_seq after the camera moved doesn't cast
  again; a new one does; a tap keeps the device's DoF flag; an orthographic camera works; a
  manual focus change (or the same manual distance again after a tap or rack) and a new tap
  cancel a rack; the miss is logged and in the N-panel.
- LNS-003: with a 2.39:1 render the stream frame is 960×402, and a tap at the picture point
  where that frame shows a small cube hits the cube.
"""

import importlib
import logging
import math
import os
import subprocess
import threading
import time

import addon_utils
import bpy
from mathutils import Matrix, Vector

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOTION = os.path.join(ROOT, "testdata", "motion")
FAKE = os.environ["FAKE_IPHONE"]
NEAR_M, FAR_M = 1.1, 4.6
MAX_POLL_MS = 50.0  # wall time per poll, NFR-PERF-002
# Information only. Blender's macOS Python has no thread_time; process_time also counts the native
# threads, so there it can only overstate the poll's own CPU time.
CPU_CLOCK = "thread_time" if hasattr(time, "thread_time") else "process_time"
cpu_time = getattr(time, CPU_CLOCK)

addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")
apply = importlib.import_module(MODULE + ".core.apply")
panels = importlib.import_module(MODULE + ".ui.panels")
render_mod = importlib.import_module(MODULE + ".core.render")

scene = bpy.context.scene
camera = scene.camera
cam = camera.data
for obj in [o for o in scene.objects if o.type == 'MESH']:
    bpy.data.objects.remove(obj)
cam.lens, cam.sensor_width, cam.sensor_fit = 24.0, 36.0, 'AUTO'
cam.dof.use_dof = False
assert (scene.render.resolution_x, scene.render.resolution_y) == (1920, 1080)
origin = bpy.data.objects.new(apply.ORIGIN_NAME, None)
scene.collection.objects.link(origin)
camera.parent, camera.matrix_parent_inverse = origin, Matrix.Identity(4)


def cube(name, centre, size=0.8):
    mesh = bpy.data.meshes.new(name)
    h = size / 2
    verts = [(x, y, z) for x in (-h, h) for y in (-h, h) for z in (-h, h)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    mesh.from_pydata(verts, [], faces)
    obj = bpy.data.objects.new(name, mesh)
    obj.location = centre
    scene.collection.objects.link(obj)
    return obj


# The picture point (0.75, 0.25) is (0.375, 0.2109375) per metre of depth for this camera.
half_w, half_h = 18.0 / 24.0, 18.0 / 24.0 * 1080 / 1920
cube("Near", (0.0, NEAR_M + 0.4, 1.6))
cube("Far", (0.5 * half_w * FAR_M, FAR_M + 0.4, 1.6 + 0.5 * half_h * FAR_M))
FAR_EUCLID = FAR_M * math.sqrt(1 + (0.5 * half_w) ** 2 + (0.5 * half_h) ** 2)


class Capture(logging.Handler):
    def __init__(self):
        super().__init__(logging.INFO)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


capture = Capture()
log_root = logging.getLogger("vcam_blender")
log_root.setLevel(logging.INFO)
log_root.addHandler(capture)

# Every ray cast goes through tap_hit; record the thread and the answers.
casts = []
real_tap_hit = apply.tap_hit


def recording_tap_hit(*args):
    hit = real_tap_hit(*args)
    casts.append((threading.current_thread() is threading.main_thread(), args[2:], hit))
    return hit


apply.tap_hit = recording_tap_hit

assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
state_file = os.path.join(session.config_dir(), "fake-iphone.key")
code = live.enable_pairing()


def run_fake(*extra):
    """Streams the scripted motion; returns (FAKE_IPHONE_DONE fields, [(t, wall_ms, focus, cpu_ms)])."""
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
    samples = []
    t0 = time.monotonic()
    deadline = t0 + 30
    while child.poll() is None:
        assert time.monotonic() < deadline, "fake iPhone did not finish"
        started, started_cpu = time.perf_counter(), cpu_time()
        session._poll()
        wall_ms = (time.perf_counter() - started) * 1e3
        cpu_ms = (cpu_time() - started_cpu) * 1e3
        if session.state.session_id is not None:
            samples.append((time.monotonic() - t0, wall_ms, cam.dof.focus_distance, cpu_ms))
        time.sleep(0.004)
    out, err = child.communicate()
    assert child.returncode == 0, err
    for _ in range(100):
        session._poll()
        if session.state.session_id is None:
            break
        time.sleep(0.01)
    done = next(line for line in out.splitlines() if line.startswith("FAKE_IPHONE_DONE"))
    return dict(kv.split("=", 1) for kv in done.split()[1:]), samples


def near(value, want, rel=0.01):
    return abs(value - want) <= rel * want


# The two timing runs; the repeat after a slow poll uses the same arguments without a pairing code.
TIMING_RUNS = (
    ("--focus", "3", "--dof", "0", "--tap", "0.75,0.25@15"),
    ("--focus", "1", "--dof", "1", "--rack", "1,6,B,1000@30", "--tap", "0.5,0.5@200"),
)

# Run 1: a tap over the wire. The first state (tap_seq 0) is the baseline; tap_seq 1 at frame 15.
fields, samples = run_fake("--code", code, "--focus", "3", "--dof", "0", "--tap", "0.75,0.25@15")
focus_values = [f for _, _, f, _ in samples]
assert 3.0 in focus_values, "the device's focus was applied before the tap"
assert focus_values.index(3.0) < len(focus_values) - 1
wire_tap = cam.dof.focus_distance
assert near(wire_tap, FAR_M) and not near(wire_tap, FAR_EUCLID), (wire_tap, FAR_M, FAR_EUCLID)
assert cam.dof.use_dof is False, "a tap doesn't turn DoF on"
assert [c[1] for c in casts] == [(0.75, 0.25)] and casts[0][2][1] == "Far", casts
assert near(float(fields["focus_m"]), FAR_M) and fields["dof"] == "0", fields
tap_samples = samples

# Run 2: rack 1 → 6 m (B) over 1 s from frame 30, then a tap at frame 200 (camera tilted towards
# empty sky after the scripted pan) misses and keeps the distance.
casts.clear()
fields, samples = run_fake("--focus", "1", "--dof", "1", "--rack", "1,6,B,1000@30", "--tap", "0.5,0.5@200")
series = [(t, f) for t, _, f, _ in samples]
first = next(i for i, (_, f) in enumerate(series) if f == 1.0)
moving = [(t, f) for t, f in series[first:] if f > 1.0]
assert moving, series
values = [f for _, f in series[first:]]
assert all(b >= a for a, b in zip(values, values[1:], strict=False)), "the rack went backwards or restarted"
assert cam.dof.focus_distance == 6.0 and values[-1] == 6.0, values[-1]
reached = next(t for t, f in moving if f == 6.0)
rack_s = reached - moving[0][0]
assert 0.8 <= rack_s <= 1.4, rack_s
distinct = len({f for _, f in moving})
assert distinct >= 20, f"only {distinct} distinct values: a jump, not a rack"
mid = [f for t, f in moving if abs(t - (moving[0][0] + rack_s / 2)) < 0.05]
assert mid and all(2.0 < f < 5.0 for f in mid), mid
assert len(casts) == 1 and casts[0][2] is None, casts  # the tap at frame 200 missed
assert cam.dof.use_dof is True and fields["focus_m"] == "6" and fields["dof"] == "1", fields
assert any("nothing hit, focus kept at 6.000 m" in line for line in capture.lines), capture.lines
assert any(line.startswith("rack to B: 1.000 -> 6.000 m over 1000 ms") for line in capture.lines), capture.lines
assert all(main for main, _, _ in casts)


def worst_poll(*runs):
    """The slowest poll over the runs: (wall_ms, cpu_ms of that poll, time into its run)."""
    return max(((wall, cpu, t) for run in runs for t, wall, _, cpu in run), default=(0.0, 0.0, 0.0))


# NFR-PERF-002: no poll takes 50 ms of wall time. A single pre-empted poll is absorbed by running
# the same two runs once more; the test fails only if the repeat also has a slow poll.
wall_1, cpu_1, at_1 = worst_poll(tap_samples, samples)
poll_retried = wall_1 >= MAX_POLL_MS
max_poll_ms, max_poll_cpu_ms = wall_1, cpu_1
if poll_retried:
    print(
        f"poll wall time {wall_1:.1f} ms >= {MAX_POLL_MS:.0f} ms at t={at_1:.2f} s "
        f"(cpu {cpu_1:.1f} ms, {CPU_CLOCK}); repeating the timing runs once"
    )
    repeat = [run_fake(*args)[1] for args in TIMING_RUNS]
    assert all(main for main, _, _ in casts)
    max_poll_ms, max_poll_cpu_ms, at_2 = worst_poll(*repeat)
    assert max_poll_ms < MAX_POLL_MS, (
        f"poll wall time {max_poll_ms:.1f} ms >= {MAX_POLL_MS:.0f} ms at t={at_2:.2f} s "
        f"(cpu {max_poll_cpu_ms:.1f} ms, {CPU_CLOCK}) in the repeat as well as in the first run "
        f"({wall_1:.1f} ms at t={at_1:.2f} s): the main thread blocked, this is not a pre-empted runner"
    )


class Stub:
    """A session whose pose and CONTROL_STATE the test sets."""

    def __init__(self):
        self.pose, self.control, self.lens = None, None, []

    def latest_pose(self):
        return self.pose

    def latest_control(self):
        return self.control

    def update_status(self, *_args, **lens):
        self.lens.append(lens)


FORWARD = (math.sqrt(0.5), 0.0, 0.0, math.sqrt(0.5))  # looking along +Y (vcp.md §7 rest pose)
LEFT = (0.5, 0.5, 0.5, 0.5)  # the scripted pan: looking along −X
stub, applier = Stub(), apply.Applier()
seq = {"state": 0, "pose": 0}
clock = iter(i / 60 for i in range(100_000))


def pose(orientation):
    seq["pose"] += 1
    stub.pose = {
        "seq": seq["pose"],
        "smoothed_position": (0.0, 0.0, 1.6),
        "smoothed_orientation": orientation,
        "tracking_state": 5,
    }


def send(tap=(0.5, 0.5, 0), rack=(1.0, 6.0, 0, 1000, 0), **lens):
    seq["state"] += 1
    stub.control = {
        "state_seq": seq["state"],
        "motion_scale": 1.0,
        "lock_flags": 0,
        "origin_epoch": 0,
        "lens_mm": None,
        "focus_distance_m": None,
        "fstop": None,
        "dof_on": None,
        "tap_u": tap[0],
        "tap_v": tap[1],
        "tap_seq": tap[2],
        "rack_a_m": rack[0],
        "rack_b_m": rack[1],
        "rack_target": rack[2],
        "rack_duration_ms": rack[3],
        "rack_seq": rack[4],
        **lens,
    }
    return tick()


def tick():
    now = next(clock)
    applier.tick(stub, 31, scene, now)
    return now


casts.clear()
pose(FORWARD)
send(focus_distance_m=3.0, dof_on=True)
tick()
assert cam.dof.focus_distance == 3.0 and not casts
send(tap=(0.5, 0.5, 1), dof_on=True)
assert near(cam.dof.focus_distance, NEAR_M) and cam.dof.use_dof is True, cam.dof.focus_distance
near_focus = cam.dof.focus_distance
# The camera turns away; the same tap_seq in a newer state doesn't cast again.
pose(LEFT)
tick()
send(tap=(0.5, 0.5, 1), dof_on=True)
tick()
assert len(casts) == 1 and cam.dof.focus_distance == near_focus
# A new tap_seq casts from the new view: empty sky, a miss, the distance is kept.
send(tap=(0.5, 0.5, 2), dof_on=True)
assert len(casts) == 2 and casts[-1][2] is None and cam.dof.focus_distance == near_focus
assert applier.last_tap == (None, None)
# Back to the front; DoF off from the device, then a tap: the distance changes, DoF stays off.
pose(FORWARD)
tick()
send(tap=(0.75, 0.25, 3), dof_on=False)
assert near(cam.dof.focus_distance, FAR_M) and cam.dof.use_dof is False
assert applier.last_tap[1] == "Far"
# An orthographic camera (4 m × 2.25 m picture): the parallel ray through Far's front-face centre
# hits it at 4.6 m; a perspective ray through the same picture point would miss everything.
cam.type, cam.ortho_scale = 'ORTHO', 4.0
cam.dof.focus_distance = 3.0
far_x, far_z = 0.5 * half_w * FAR_M, 0.5 * half_h * FAR_M
send(tap=(0.5 + far_x / 4.0, 0.5 - far_z / 2.25, 4), dof_on=False)
assert near(cam.dof.focus_distance, FAR_M) and applier.last_tap[1] == "Far", (cam.dof.focus_distance, applier.last_tap)
cam.type = 'PERSP'

# A rack, cancelled by a manual focus change; then a rack cancelled by a tap.
send(tap=(0.5, 0.5, 4), rack=(1.0, 6.0, 0, 1000, 1), focus_distance_m=1.0)
assert cam.dof.focus_distance == 1.0
send(tap=(0.5, 0.5, 4), rack=(1.0, 6.0, 2, 1000, 2))
for _ in range(20):
    tick()
racked = cam.dof.focus_distance
assert 1.0 < racked < 6.0 and applier.rack is not None, racked
send(tap=(0.5, 0.5, 4), rack=(1.0, 6.0, 2, 1000, 2), focus_distance_m=2.5)
assert applier.rack is None and cam.dof.focus_distance == 2.5
for _ in range(90):
    tick()
assert cam.dof.focus_distance == 2.5, "the cancelled rack continued"
send(tap=(0.5, 0.5, 4), rack=(1.0, 6.0, 2, 1000, 3))
for _ in range(20):
    tick()
assert 2.5 < cam.dof.focus_distance < 6.0 and applier.rack is not None
send(tap=(0.5, 0.5, 5), rack=(1.0, 6.0, 2, 1000, 3))
assert applier.rack is None and near(cam.dof.focus_distance, NEAR_M)
for _ in range(90):
    tick()
assert near(cam.dof.focus_distance, NEAR_M), "the rack continued after a tap"
assert all(main for main, _, _ in casts)
# The device leaves the focus out after a tap or rack, so the earlier manual 2.5 m again is a new
# request: it overrides the tap, and cancels a running rack.
send(tap=(0.5, 0.5, 5), rack=(1.0, 6.0, 2, 1000, 3), fstop=4.0)
assert near(cam.dof.focus_distance, NEAR_M), "a change without the focus keeps the tap's distance"
send(tap=(0.5, 0.5, 5), rack=(1.0, 6.0, 2, 1000, 3), focus_distance_m=2.5)
assert cam.dof.focus_distance == 2.5, "the same manual focus again overrides the tap"
send(tap=(0.5, 0.5, 5), rack=(1.0, 6.0, 2, 1000, 4))
for _ in range(20):
    tick()
assert 2.5 < cam.dof.focus_distance < 6.0 and applier.rack is not None
send(tap=(0.5, 0.5, 5), rack=(1.0, 6.0, 2, 1000, 4), focus_distance_m=2.5)
assert applier.rack is None and cam.dof.focus_distance == 2.5, "the same manual focus again cancels the rack"

# The N-panel shows the last tap (a miss here) and a running rack.
session._applier = applier
applier.last_tap = (None, None)
send(tap=(0.5, 0.5, 5), rack=(1.0, 6.0, 1, 1000, 5))
labels = []


class Layout:
    def __setattr__(self, _name, _value):
        pass

    def _nested(self, *_args, **_kwargs):
        return self

    box = column = row = _nested

    def label(self, text="", **_kwargs):
        labels.append(text)

    def prop(self, *_args, **_kwargs):
        pass

    def operator(self, *_args, **_kwargs):
        return type("Op", (), {})()


panels.VCAM_PT_main_panel.draw(type("Panel", (), {"layout": Layout()})(), bpy.context)
assert "Tap focus: nothing hit, focus kept" in labels and "Rack to A: 1.00 m over 1.0 s" in labels, labels

# LNS-003: a 2.39:1 render streams 960×402, drawn with the camera's projection for that size
# (StreamRenderer._draw). "Scope", a 0.2 m cube 3 m ahead, sits where that frame shows the
# picture point (0.8, 0.1); a tap where the device sees it hits it. The 16:9 frame the stream
# used before showed a different point there.
render = scene.render
render.resolution_x, render.resolution_y = 2048, 858
stream_size = render_mod.adapted_resolution('540p', 0, apply.scene_aspect(scene))
assert stream_size == (960, 402), stream_size
SCOPE_M = 3.0
scope_h = half_w * 858 / 2048
scope_face = Vector((0.6 * half_w * SCOPE_M, SCOPE_M, 1.6 + 0.8 * scope_h * SCOPE_M))
cube("Scope", scope_face + Vector((0.0, 0.1, 0.0)), size=0.2)
depsgraph = bpy.context.evaluated_depsgraph_get()


def picture_point(size):
    """(u, v) of the Scope face centre in a stream frame of `size` (u from the left, v from the top)."""
    view = camera.evaluated_get(depsgraph).matrix_world.inverted()
    clip = camera.calc_matrix_camera(depsgraph, x=size[0], y=size[1]) @ view @ scope_face.to_4d()
    return (clip.x / clip.w + 1) / 2, (1 - clip.y / clip.w) / 2


scope_uv = picture_point(stream_size)
assert abs(scope_uv[0] - 0.8) < 2e-3 and abs(scope_uv[1] - 0.1) < 2e-3, scope_uv
old_uv = picture_point((960, 540))
assert abs(old_uv[1] - scope_uv[1]) > 0.05, (old_uv, scope_uv)
send(tap=(*scope_uv, 6), rack=(1.0, 6.0, 1, 1000, 4), focus_distance_m=2.5)
assert applier.last_tap[1] == "Scope" and near(cam.dof.focus_distance, SCOPE_M), (applier.last_tap, scope_uv)
render.resolution_x, render.resolution_y = 1920, 1080

apply.tap_hit = real_tap_hit
log_root.removeHandler(capture)
assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(
    f"VCAM_ADDON_FOCUS_OK tap_axial_m={wire_tap:.4f} expected_m={FAR_M} euclidean_m={FAR_EUCLID:.4f} "
    f"dof_after_tap=off rack=1->6m_in_{rack_s:.2f}s distinct={distinct} monotonic=yes resend=no_restart "
    f"miss=kept_6m max_poll_ms={max_poll_ms:.2f} poll_retried={int(poll_retried)} "
    f"max_poll_cpu_ms={max_poll_cpu_ms:.2f} cpu_clock={CPU_CLOCK} "
    f"same_tap_seq=no_cast cancel=manual,tap main_thread=all "
    f"aspect_tap=Scope@{stream_size[0]}x{stream_size[1]}_uv={scope_uv[0]:.3f},{scope_uv[1]:.3f}"
)
