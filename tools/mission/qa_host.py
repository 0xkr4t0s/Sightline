# SPDX-License-Identifier: GPL-3.0-or-later
"""Long-running headless Sightline host for QA: a background Blender that a script or an agent
starts, drives (fake iPhone, or the app in the iOS simulator) and inspects through files.

Start it with tools/mission/qa_blender.sh, or directly:

    "$BLENDER" --background --factory-startup --python-exit-code 1 \\
        --python tools/mission/qa_host.py -- [--port 47000] [--bind 127.0.0.1]
        [--scene qa|factory] [--blend FILE] [--no-video] [--no-pairing] [--log FILE]

It enables the installed extension (BLENDER_USER_RESOURCES, see env.sh), sets up the scene,
starts a session with pairing on and the viewfinder stream running, then polls it on the main
thread at the add-on timer's 60 Hz until stopped.

Scene: `--blend FILE` opens that file. Otherwise `--scene qa` (the default, `build_qa_scene`)
replaces the factory cube with a test set that keeps content in view for every scripted motion:
the rig (`VCam_Origin`) at the world origin 1.2 m above a checkered floor, facing +Y (the
canonical rest pose's view) at a striped 7-colour totem 1.5 m ahead, inside a ring of 12
coloured pillars 5 m out, lettered A (straight ahead) to L anticlockwise; 24 mm lens, blue-grey
sky. Colours show in Solid (material colour) and Material Preview. `--scene factory` keeps
Blender's factory startup scene (the grey cube, usually out of view of scripted motion).

Files (under $MISSION_DIR, default .mission):

  qa/host.json    written at start and whenever it changes: state (running/stopped/failed), port,
                  bind, pairing_code (current code or null), pid, blender_version, blend,
                  scene (qa/factory/blend), log, started_at.
  qa/state.json   rewritten at ~5 Hz: poll timings, session and device, camera and VCam_Origin
                  transforms, controls, tap/rack focus, latency, video stats, stream and render
                  settings, the N-panel's labels
                  and buttons (drawn by the real panel), and the errors the loop captured.
  qa/cmd/*.json   command queue: one JSON object per file, run in name order on the main thread.
                  The result goes to qa/cmd/<name>.result.json and the command file is removed.
                  Write the file under another name first and rename it, so it's read whole.
  logs/qa-host.log  the add-on's log (core/log.py, redacted) plus this host's lines.

Commands ({"cmd": NAME, ...}); relative paths are relative to the repository root:
  ping                                  → {"pong": true}
  state                                 → the state.json snapshot
  pair                                  new pairing code (also in host.json)
  cancel_pair                           withdraw the pairing code
  set        prop, value                set a scene `vcam_props` property (target_camera by object name)
  set_render [resolution_x, resolution_y, pixel_aspect_x, pixel_aspect_y]
                                        set the scene's render size / pixel aspect (the stream
                                        follows its aspect, LNS-003)
  set_origin / clear_origin             the N-panel's Set/Clear Origin operators
  render_png [path, resolution, shading] draw the driven camera like the stream and save a PNG
                                        (default .mission/qa/render.png, the stream's size at the
                                        render aspect and shading)
  latency_report [path]                 the N-panel's Save Latency Report for the current or last
                                        device session (default .mission/qa/latency-host.json):
                                        pose, apply, render/readback, encode, send, device M2P
  save_blend path                       save a copy of the open file
  open_blend path                       open a .blend (the session keeps running)
  eval       code                       QA escape hatch: exec Python with bpy on the main thread;
                                        returns repr() of the variable `result` and printed output
  stop                                  stop the session and exit

SIGTERM and SIGINT stop the host the same way as `stop`.
"""

import argparse
import contextlib
import datetime
import importlib
import io
import json
import os
import signal
import struct
import sys
import time
import traceback
import zlib
from collections import deque

import addon_utils
import bpy

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MISSION_DIR = os.path.abspath(os.environ.get("MISSION_DIR") or os.path.join(ROOT, ".mission"))
QA_DIR = os.path.join(MISSION_DIR, "qa")
CMD_DIR = os.path.join(QA_DIR, "cmd")
HOST_FILE = os.path.join(QA_DIR, "host.json")
STATE_FILE = os.path.join(QA_DIR, "state.json")
STATE_INTERVAL = 0.2
CMD_INTERVAL = 0.05
MAX_ERRORS = 20
# vcam_native latest_control() keys for the T2 lens fields (vcp.md §6.2 bits 4-9).
LENS_CONTROL_KEYS = (
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


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser(prog="qa_host.py", description="Headless Sightline host for QA")
    p.add_argument("--port", type=int, default=47000, help="TCP control port (default 47000)")
    p.add_argument("--bind", default="127.0.0.1", help="address to listen on (default 127.0.0.1)")
    p.add_argument("--blend", help=".blend file to open before the session starts (overrides --scene)")
    p.add_argument(
        "--scene",
        choices=("qa", "factory"),
        default="qa",
        help="without --blend: the coloured QA test scene (default) or Blender's factory cube",
    )
    p.add_argument("--no-video", action="store_true", help="don't render or stream the viewfinder")
    p.add_argument("--no-pairing", action="store_true", help="don't show a pairing code at start")
    p.add_argument("--log", default=os.path.join(MISSION_DIR, "logs", "qa-host.log"), help="log file")
    return p.parse_args(argv)


def now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")


def resolve(path: str) -> str:
    return os.path.abspath(os.path.join(ROOT, os.path.expanduser(path)))


def write_json(path: str, data) -> None:
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, default=_json_default)
        f.write("\n")
    os.replace(tmp, path)


def _json_default(o):
    try:
        return list(o)
    except TypeError:
        return repr(o)


def matrix(m) -> list:
    return [[round(v, 6) for v in row] for row in m]


def vector(v) -> list:
    return [round(x, 6) for x in v]


def write_png(path: str, pixels) -> None:
    """Writes an (h, w, 4) uint8 GPU read-back (rows bottom-up) as an RGB PNG."""
    import numpy as np

    height, width = pixels.shape[:2]
    rows = np.ascontiguousarray(np.flipud(pixels)[:, :, :3]).reshape(height, width * 3)
    raw = np.concatenate([np.zeros((height, 1), dtype=np.uint8), rows], axis=1).tobytes()

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


QA_RIG_HEIGHT = 1.2
QA_RING_RADIUS = 5.0
QA_PILLARS = 12
QA_LENS_MM = 24.0
QA_TOTEM_DISTANCE = 1.5
QA_TOTEM_COLORS = (
    (0.9, 0.9, 0.9),
    (0.85, 0.1, 0.1),
    (0.95, 0.8, 0.1),
    (0.1, 0.3, 0.9),
    (0.1, 0.7, 0.2),
    (0.9, 0.4, 0.05),
    (0.6, 0.1, 0.8),
)


def _hsv(h: float, s: float = 0.85, v: float = 0.9) -> tuple:
    import colorsys

    return colorsys.hsv_to_rgb(h % 1.0, s, v)


def _material(name: str, rgb) -> "bpy.types.Material":
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*rgb, 1.0)  # Solid shading with color type Material
    if m.node_tree is None and hasattr(m, "use_nodes"):
        m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF") if m.node_tree is not None else None
    if bsdf is not None:  # Material Preview and Rendered
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.6
    return m


def _mesh_object(collection, name: str, build, location, materials, face_material=None):
    import bmesh

    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    build(bm)
    if face_material is not None:
        for face in bm.faces:
            face.material_index = face_material(face)
    bm.to_mesh(mesh)
    bm.free()
    for m in materials:
        mesh.materials.append(m)
    obj = bpy.data.objects.new(name, mesh)
    obj.location = location
    obj.color = (*materials[0].diffuse_color[:3], 1.0)
    collection.objects.link(obj)
    return obj


def build_qa_scene(apply) -> dict:
    """Replaces the factory cube with a scene where every scripted motion keeps content in view.

    The canonical rest pose (identity device pose, vcp.md §7) looks along the rig's +Y. The iOS
    app's QA motions sit at that pose (rig-local height 0); the fake iPhone's scripted.bin starts
    there 1.6 m higher, then pans 90° to -X, tilts 30° down, dollies 2 m and cranes 1.5 m. So the
    rig stands at the world origin, QA_RIG_HEIGHT above a checkered floor, facing +Y at a tall
    striped totem (seen by both heights) inside a ring of coloured, lettered pillars (A straight
    ahead, then B, C, … anticlockwise, i.e. to the left), so several objects are in view at any
    heading, and the floor shows the tilt and dolly.
    """
    import math

    import bmesh
    from mathutils import Matrix, Vector

    scene = bpy.context.scene
    camera = scene.camera
    for obj in list(bpy.data.objects):
        if obj.type in ('MESH', 'LIGHT') and obj is not camera:
            bpy.data.objects.remove(obj)
    collection = bpy.data.collections.new("QA Scene")
    scene.collection.children.link(collection)

    tile_a, tile_b = _material("QA Floor Light", (0.55, 0.55, 0.55)), _material("QA Floor Dark", (0.12, 0.12, 0.14))

    def floor(bm):
        n, size = 24, 1.0
        for i in range(n):
            for j in range(n):
                x, y = (i - n / 2) * size, (j - n / 2) * size
                verts = [bm.verts.new((x + dx, y + dy, 0.0)) for dx, dy in ((0, 0), (size, 0), (size, size), (0, size))]
                bm.faces.new(verts)

    def checker(face):
        c = face.calc_center_median()
        return (math.floor(c.x) + math.floor(c.y)) % 2

    _mesh_object(collection, "QA Floor", floor, (0, 0, 0), [tile_a, tile_b], checker)

    block = 0.5
    for k, rgb in enumerate(QA_TOTEM_COLORS):
        _mesh_object(
            collection,
            f"QA Totem {k}",
            lambda bm: bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Diagonal((0.4, 0.4, block * 0.96, 1.0))),
            (0.0, QA_TOTEM_DISTANCE, block * (k + 0.5)),
            [_material(f"QA Totem {k}", rgb)],
        )

    white = _material("QA Letter", (0.97, 0.97, 0.97))
    for k in range(QA_PILLARS):
        letter = chr(ord("A") + k)
        angle = math.pi / 2 + k * 2 * math.pi / QA_PILLARS
        direction = Vector((math.cos(angle), math.sin(angle), 0.0))
        height = 4.0 + (k % 3) * 0.6
        _mesh_object(
            collection,
            f"QA Pillar {letter}",
            lambda bm, h=height: bmesh.ops.create_cone(
                bm,
                cap_ends=True,
                segments=24,
                radius1=0.35,
                radius2=0.35,
                depth=h,
                matrix=Matrix.Translation((0, 0, h / 2)),
            ),
            direction * QA_RING_RADIUS,
            [_material(f"QA Pillar {letter}", _hsv(k / QA_PILLARS))],
        )
        curve = bpy.data.curves.new(f"QA Letter {letter}", 'FONT')
        curve.body = letter
        curve.size = 1.1
        curve.align_x, curve.align_y = 'CENTER', 'CENTER'
        curve.extrude = 0.03
        curve.materials.append(white)
        text = bpy.data.objects.new(f"QA Letter {letter}", curve)
        text.location = direction * (QA_RING_RADIUS - 0.45) + Vector((0, 0, 2.0))
        text.rotation_euler = (math.pi / 2, 0.0, angle - math.pi / 2)  # faces the centre
        collection.objects.link(text)

    sun = bpy.data.objects.new("QA Sun", bpy.data.lights.new("QA Sun", 'SUN'))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(50), 0.0, math.radians(30))
    collection.objects.link(sun)

    world = scene.world or bpy.data.worlds.new("World")
    scene.world = world
    sky = (0.18, 0.26, 0.4)
    world.color = sky
    background = world.node_tree.nodes.get("Background") if world.node_tree is not None else None
    if background is not None:
        background.inputs["Color"].default_value = (*sky, 1.0)
    for screen in bpy.data.screens:
        for area in screen.areas:
            for space in area.spaces:
                if space.type == 'VIEW_3D':
                    space.shading.color_type = 'MATERIAL'
                    space.shading.background_type = 'WORLD'

    camera.data.lens = QA_LENS_MM
    camera.data.clip_end = 200.0
    origin = bpy.data.objects.new(apply.ORIGIN_NAME, None)
    origin.empty_display_type = 'PLAIN_AXES'
    origin.location = (0.0, 0.0, QA_RIG_HEIGHT)
    scene.collection.objects.link(origin)
    apply.ensure_rig(scene, camera)
    camera.matrix_basis = Matrix.Rotation(math.pi / 2, 4, 'X')  # the rest pose: looking along +Y
    return {"rig_height": QA_RIG_HEIGHT, "pillars": QA_PILLARS, "lens_mm": QA_LENS_MM}


class PanelRecorder:
    """Stands in for `Panel.layout`: records what the add-on's N-panel draw() would show."""

    def __init__(self, sink=None):
        object.__setattr__(self, "sink", sink if sink is not None else {"labels": [], "operators": [], "props": []})

    def __setattr__(self, name, value):  # enabled, scale_y, alert, …: layout-only
        pass

    def _nested(self, *_args, **_kwargs):
        return PanelRecorder(self.sink)

    box = column = row = split = grid_flow = column_flow = _nested

    def label(self, text="", icon='NONE', **_kwargs):
        self.sink["labels"].append(text)

    def prop(self, data, name, text=None, **_kwargs):
        value = getattr(data, name, None)
        value = (
            getattr(value, "name", value)
            if value is not None and not isinstance(value, (bool, int, float, str))
            else value
        )
        self.sink["props"].append({"prop": name, "text": text, "value": value})

    def operator(self, idname, text=None, **_kwargs):
        category, _, name = idname.partition(".")
        try:
            enabled = bool(getattr(getattr(bpy.ops, category), name).poll())  # greyed out when False
        except Exception:  # noqa: BLE001
            enabled = None
        self.sink["operators"].append({"operator": idname, "text": text, "enabled": enabled})
        return argparse.Namespace()

    def separator(self, *_args, **_kwargs):
        pass


class Host:
    def __init__(self, args):
        self.args = args
        self.stopping = False
        self.started_at = now_iso()
        self.started = time.monotonic()
        self.errors = deque(maxlen=MAX_ERRORS)
        self.ticks = 0
        # Duration of the add-on's main-thread poll: the last one, and the longest since the
        # previous state.json write.
        self.poll_ms_last = self.poll_ms_max = 0.0
        self.host_info: dict = {}
        self.pairing_code = None
        self.seen_errors = (None, None)
        self.log_path = os.path.abspath(args.log)

    # -- setup --------------------------------------------------------------------------------

    def start(self) -> None:
        a = self.args
        os.makedirs(CMD_DIR, exist_ok=True)
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        open(self.log_path, "w").close()
        # Picked up by the add-on's register(), so its own start-up lines land in the same file.
        os.environ["SIGHTLINE_LOG_FILE"] = self.log_path
        if not a.no_video:
            import gpu

            gpu.init()
        if addon_utils.enable(MODULE, default_set=True, handle_error=None) is None:
            raise RuntimeError(f"could not enable {MODULE}: run tools/mission/setup.sh")
        mod = lambda name: importlib.import_module(f"{MODULE}.{name}")  # noqa: E731
        self.session = mod("core.session")
        self.apply = mod("core.apply")
        self.render = mod("core.render")
        self.status = mod("core.status")
        self.latency = mod("core.latency")
        self.panels = mod("ui.panels")
        self.logmod = mod("core.log")
        self.logmod.log_to_file(self.log_path)
        self.log = self.logmod.get_logger("qa_host")
        self.log.info(
            "qa host starting pid=%d blender=%s video=%s", os.getpid(), bpy.app.version_string, not a.no_video
        )
        if a.blend:
            bpy.ops.wm.open_mainfile(filepath=resolve(a.blend))
            self.log.info("opened blend=%s", self.rel(bpy.data.filepath))
            self.scene = "blend"
        elif a.scene == "qa":
            self.log.info("qa scene built %s", build_qa_scene(self.apply))
            self.scene = "qa"
        else:
            self.scene = "factory"
        self.session.start(a.port, a.bind, stream=not a.no_video)
        if not a.no_pairing:
            self.pairing_code = self.session.current().enable_pairing()
            self.log.info("pairing enabled")
        signal.signal(signal.SIGTERM, self._on_signal)
        signal.signal(signal.SIGINT, self._on_signal)
        self.write_host("running")
        self.write_state()
        port = self.session.current().port()
        self.log.info("qa host ready port=%d bind=%s", port, a.bind)
        print(f"QA_HOST_READY port={port} pid={os.getpid()}", flush=True)

    def _on_signal(self, signum, _frame) -> None:
        self.stopping = True
        self.log.info("signal %d: stopping", signum)

    def rel(self, path):
        if not path:
            return None
        path = os.path.abspath(path)
        if path == ROOT or path.startswith(ROOT + os.sep):
            return os.path.relpath(path, ROOT)
        return self.logmod.redact(path)

    def write_host(self, state: str, **extra) -> None:
        live = self.session.current() if hasattr(self, "session") else None
        self.host_info = {
            "state": state,
            "port": live.port() if live is not None else self.args.port,
            "bind": self.args.bind,
            "pairing_code": self.pairing_code if live is not None else None,
            "pid": os.getpid(),
            "blender_version": bpy.app.version_string,
            "video": not self.args.no_video,
            "blend": self.rel(bpy.data.filepath),
            "scene": getattr(self, "scene", None),
            "log": self.rel(self.log_path),
            "state_file": self.rel(STATE_FILE),
            "cmd_dir": self.rel(CMD_DIR),
            "started_at": self.started_at,
            **extra,
        }
        write_json(HOST_FILE, self.host_info)

    # -- loop ---------------------------------------------------------------------------------

    def run(self) -> None:
        session = self.session
        next_cmd = next_state = 0.0
        while not self.stopping:
            tick = time.monotonic()
            try:
                session._poll()  # the add-on's timer body: events, pose apply, stream render
            except Exception as e:  # noqa: BLE001 - keep hosting; the error is in state.json
                self.error("poll", e)
            poll_ms = (time.monotonic() - tick) * 1e3
            self.poll_ms_last, self.poll_ms_max = poll_ms, max(self.poll_ms_max, poll_ms)
            self.ticks += 1
            self._note_session_errors()
            if tick >= next_cmd:
                next_cmd = tick + CMD_INTERVAL
                if self.process_commands():
                    next_state = 0.0
            if tick >= next_state:
                next_state = tick + STATE_INTERVAL
                self._refresh_pairing()
                self.write_state()
            time.sleep(max(0.001, session.POLL_INTERVAL - (time.monotonic() - tick)))

    def shutdown(self) -> None:
        self.log.info("qa host stopping")
        self.session.stop()
        self.pairing_code = None
        self.write_state()
        self.write_host("stopped", stopped_at=now_iso())
        self.log.info("qa host stopped")

    def error(self, where: str, e: BaseException) -> None:
        text = self.logmod.redact(f"{type(e).__name__}: {e}")
        self.errors.append({"time": now_iso(), "where": where, "error": text})
        self.log.error("%s failed: %s", where, text, exc_info=e)

    def _note_session_errors(self) -> None:
        st = self.session.state
        seen = (st.last_error, st.stream_error)
        if seen != self.seen_errors:
            for where, old, new in zip(("session", "stream"), self.seen_errors, seen, strict=True):
                if new and new != old:
                    self.errors.append({"time": now_iso(), "where": where, "error": self.logmod.redact(new)})
            self.seen_errors = seen

    def _refresh_pairing(self) -> None:
        live = self.session.current()
        code = live.pairing_code() if live is not None else None
        if code != self.pairing_code:
            self.pairing_code = code
            self.log.info("pairing code %s", "shown" if code else "consumed or expired")
            self.write_host("running")

    # -- state --------------------------------------------------------------------------------

    def write_state(self) -> None:
        try:
            write_json(STATE_FILE, self.snapshot())
        except Exception as e:  # noqa: BLE001
            self.error("state", e)
        self.poll_ms_max = 0.0

    def snapshot(self) -> dict:
        s, apply, status = self.session, self.apply, self.status
        scene = bpy.context.scene
        props = scene.vcam_props
        live = s.current()
        st = s.state
        applier = s.applier()
        camera, warning = apply.camera_status(scene)
        origin = apply.find_origin(camera)
        controls = applier.controls
        pose = live.latest_pose() if live is not None else None
        control = live.latest_control() if live is not None else None
        stream = s._stream
        log = s.latency_log()

        def summary(values):
            data = self.latency.summarize(values)
            if data is not None:
                data.pop("histogram", None)
            return data

        uptime = time.monotonic() - self.started
        rack = applier.rack
        return {
            "time": now_iso(),
            "uptime_s": round(uptime, 3),
            "ticks": self.ticks,
            "poll_hz": round(self.ticks / uptime, 1) if uptime > 0 else None,
            "poll_ms": {"last": round(self.poll_ms_last, 3), "max_since_last_state": round(self.poll_ms_max, 3)},
            "blend": self.rel(bpy.data.filepath),
            "session": {
                "running": live is not None,
                "port": live.port() if live is not None else None,
                "pairing_code": live.pairing_code() if live is not None else None,
                "session_id": st.session_id,
                "device_id": st.device_id,
                "device_name": st.device_name,
                "tracking_state": st.tracking_state,
                "tracking_label": status.tracking_label(st.tracking_state),
                "holding": applier.holding,
                "applied_seq": applier.applied_seq,
                "latency_ms": st.latency_ms,
                "clock_jitter_ms": st.clock_jitter_ms,
                "last_error": st.last_error,
                "stream_error": st.stream_error,
                "stats": dict(live.stats()) if live is not None else None,
                "latest_pose": {k: pose[k] for k in ("seq", "tracking_state", "position", "orientation") if k in pose}
                if pose is not None
                else None,
            },
            "camera": None
            if camera is None
            else {
                "name": camera.name,
                "parent": camera.parent.name if camera.parent is not None else None,
                "matrix_world": matrix(camera.matrix_world),
                "matrix_basis": matrix(camera.matrix_basis),
                "location_world": vector(camera.matrix_world.translation),
                "rotation_euler_world_deg": [
                    round(v * 180.0 / 3.141592653589793, 4) for v in camera.matrix_world.to_euler()
                ],
                "lens": camera.data.lens,
                "sensor_width": camera.data.sensor_width,
                "sensor_fit": camera.data.sensor_fit,
                "dof_use": camera.data.dof.use_dof,
                "focus_distance": camera.data.dof.focus_distance,
                "fstop": camera.data.dof.aperture_fstop,
                # The applied-lens STATUS arguments (sensor_fit as the wire code, AUTO resolved).
                "status_lens": apply.applied_lens(scene, camera),
            },
            "camera_warning": warning,
            "origin": None
            if origin is None
            else {
                "name": origin.name,
                "matrix_world": matrix(origin.matrix_world),
                "zero": apply.read_zero(origin),
            },
            "controls": {
                "state_seq": controls.state_seq,
                "motion_scale": controls.motion_scale,
                "motion_scale_label": status.scale_label(controls.motion_scale),
                "lock_flags": controls.lock_flags,
                "locks_label": status.locks_label(controls.lock_flags),
                "origin_epoch": controls.origin_epoch,
                "thermal_state": control["thermal_state"] if control is not None else None,
                # The T2 lens keys of the newest native CONTROL_STATE (None when absent).
                **{key: control.get(key) if control is not None else None for key in LENS_CONTROL_KEYS},
            },
            # FR-CTL-002 on the host: the last tap's (distance, object) (None, None after a miss)
            # and the running rack.
            "focus": {
                "last_tap": applier.last_tap,
                "rack": None
                if rack is None
                else {
                    "target": "AB"[rack.target - 1],
                    "start_m": rack.start_m,
                    "end_m": rack.end_m,
                    "duration_s": rack.duration_s,
                },
            },
            "latency": {
                "session_id": log.session_id,
                **{name: summary(getattr(log, name)) for name in self.latency.LEGS},
                "device_m2p_p95_ms": summary(log.device_m2p_p95_ms),
                "poses_without_clock": log.without_clock,
                "poses_not_applied": log.not_applied,
                "frames_not_sampled": log.frames_not_sampled,
                "device_reports_not_measured": log.reports_not_measured,
            },
            "video": dict(live.video_stats() or {}) or None if live is not None else None,
            "stream": {
                "enabled": s._stream_enabled,
                "failed": s._stream_failed,
                "active": stream is not None,
                "width": stream.renderer.width if stream is not None else None,
                "height": stream.renderer.height if stream is not None else None,
                "shading": stream.renderer.shading if stream is not None else None,
                "fps_cap": stream.pacer.fps if stream is not None else None,
                "budget_ms": stream.pacer.budget_ms if stream is not None else None,
                "draw_ms": stream.renderer.draw_ns / 1e6 if stream is not None else None,
                "read_ms": stream.renderer.read_ns / 1e6 if stream is not None else None,
            },
            "settings": {name: self.prop_value(props, name) for name in self.prop_names(props)},
            "render": {
                "engine": scene.render.engine,
                "resolution_x": scene.render.resolution_x,
                "resolution_y": scene.render.resolution_y,
                "resolution_percentage": scene.render.resolution_percentage,
                "pixel_aspect_x": scene.render.pixel_aspect_x,
                "pixel_aspect_y": scene.render.pixel_aspect_y,
                "aspect": self.apply.scene_aspect(scene),
                "fps": scene.render.fps,
                "frame_current": scene.frame_current,
            },
            "panel": self.panel(),
            "errors": list(self.errors),
        }

    def panel(self) -> dict:
        recorder = PanelRecorder()
        try:
            self.panels.VCAM_PT_main_panel.draw(argparse.Namespace(layout=recorder), bpy.context)
        except Exception as e:  # noqa: BLE001 - a draw error is a finding, not a host failure
            recorder.sink["error"] = self.logmod.redact(f"{type(e).__name__}: {e}")
        return recorder.sink

    @staticmethod
    def prop_names(props) -> list[str]:
        return [p.identifier for p in props.bl_rna.properties if p.identifier not in ("rna_type", "name")]

    @staticmethod
    def prop_value(props, name):
        value = getattr(props, name)
        if value is None or isinstance(value, (bool, int, float, str)):
            return value
        return getattr(value, "name", repr(value))

    # -- commands -----------------------------------------------------------------------------

    def process_commands(self) -> bool:
        try:
            names = sorted(n for n in os.listdir(CMD_DIR) if n.endswith(".json") and not n.endswith(".result.json"))
        except FileNotFoundError:
            os.makedirs(CMD_DIR, exist_ok=True)
            return False
        for name in names:
            path = os.path.join(CMD_DIR, name)
            started = time.perf_counter()
            kind = None
            try:
                with open(path, encoding="utf-8") as f:
                    command = json.load(f)
                if not isinstance(command, dict) or not isinstance(command.get("cmd"), str):
                    raise ValueError('a command is a JSON object with a "cmd" string')
                kind = command["cmd"]
                handler = getattr(self, f"cmd_{kind}", None)
                if handler is None:
                    known = sorted(n[4:] for n in dir(self) if n.startswith("cmd_"))
                    raise ValueError(f"unknown command {kind!r}; known: {', '.join(known)}")
                result = {"ok": True, "cmd": kind, "result": handler(command)}
            except Exception as e:  # noqa: BLE001 - reported in the result file
                result = {
                    "ok": False,
                    "cmd": kind,
                    "error": self.logmod.redact(f"{type(e).__name__}: {e}"),
                    "traceback": self.logmod.redact(traceback.format_exc()),
                }
            result["elapsed_ms"] = round((time.perf_counter() - started) * 1e3, 2)
            write_json(os.path.join(CMD_DIR, name[:-5] + ".result.json"), result)
            os.remove(path)
            self.log.info("command %s cmd=%s ok=%s elapsed_ms=%s", name, kind, result["ok"], result["elapsed_ms"])
            if self.stopping:
                break
        return bool(names)

    def _live(self):
        live = self.session.current()
        if live is None:
            raise RuntimeError("the session is not running")
        return live

    def cmd_ping(self, _c):
        return {"pong": True}

    def cmd_state(self, _c):
        return self.snapshot()

    def cmd_stop(self, _c):
        self.stopping = True
        return {"stopping": True}

    def cmd_pair(self, _c):
        live = self._live()
        if live.pairing_code() is not None:
            live.disable_pairing()
        self.pairing_code = live.enable_pairing()
        self.log.info("pairing enabled")
        self.write_host("running")
        return {"pairing_code": self.pairing_code}

    def cmd_cancel_pair(self, _c):
        self._live().disable_pairing()
        self.log.info("pairing cancelled")
        self._refresh_pairing()
        return {"pairing_code": None}

    def cmd_set(self, c):
        props = bpy.context.scene.vcam_props
        name = c.get("prop")
        if name not in self.prop_names(props):
            raise KeyError(f"unknown prop {name!r}; known: {', '.join(self.prop_names(props))}")
        if "value" not in c:
            raise ValueError('"set" needs a "value"')
        value = c["value"]
        rna = props.bl_rna.properties[name]
        if rna.type == 'POINTER':
            value = bpy.data.objects[value] if value else None
        elif rna.type == 'ENUM' and not isinstance(value, str):
            value = str(value)  # e.g. stream_fps 24 → '24'
        setattr(props, name, value)
        self.log.info("set %s=%r", name, self.prop_value(props, name))
        return {"prop": name, "value": self.prop_value(props, name)}

    RENDER_PROPS = ("resolution_x", "resolution_y", "pixel_aspect_x", "pixel_aspect_y")

    def cmd_set_render(self, c):
        """Output properties a user sets in Blender: render size and pixel aspect (LNS-003)."""
        render = bpy.context.scene.render
        given = {name: c[name] for name in self.RENDER_PROPS if name in c}
        if not given:
            raise ValueError(f'"set_render" needs one of {", ".join(self.RENDER_PROPS)}')
        for name, value in given.items():
            setattr(render, name, value)
        result = {name: getattr(render, name) for name in self.RENDER_PROPS}
        result["aspect"] = self.apply.scene_aspect(bpy.context.scene)
        self.log.info("set_render %s", result)
        return result

    def _operator(self, op, why: str):
        if not op.poll():
            raise RuntimeError(f"{op.idname()} is unavailable: {why}")
        return sorted(op())

    def cmd_set_origin(self, _c):
        return {"operator": self._operator(bpy.ops.vcam.origin_set, "no device session")}

    def cmd_clear_origin(self, _c):
        return {"operator": self._operator(bpy.ops.vcam.origin_clear, "no Set-origin zero is stored")}

    def cmd_render_png(self, c):
        import numpy as np

        scene = bpy.context.scene
        props = scene.vcam_props
        camera, warning = self.apply.camera_status(scene)
        if camera is None:
            raise RuntimeError(warning)
        width, height = self.render.adapted_resolution(
            c.get("resolution") or props.stream_resolution, 0, self.apply.scene_aspect(scene)
        )
        shading = c.get("shading") or props.stream_shading
        path = resolve(c.get("path") or os.path.join(QA_DIR, "render.png"))
        frames = []

        class Slot:
            def submit(self, pixels, _seq, _time_ns):
                frames.append(np.array(pixels, dtype=np.uint8, copy=True))
                return len(frames)

        renderer = self.render.StreamRenderer(Slot(), width, height, shading)
        try:
            depsgraph = bpy.context.evaluated_depsgraph_get()
            renderer.tick(scene, bpy.context.view_layer, depsgraph, camera, self.session.applier().applied_seq, 0)
            renderer.tick(scene, bpy.context.view_layer, depsgraph, None, 0, 0)  # reads the drawn frame
        finally:
            renderer.free()
        write_png(path, frames[0])
        return {"path": self.rel(path), "width": width, "height": height, "shading": shading, "camera": camera.name}

    def cmd_latency_report(self, c):
        """The add-on's Save Latency Report (NFR-LAT-004) for the current or last device session."""
        path = resolve(c.get("path") or os.path.join(QA_DIR, "latency-host.json"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        op = bpy.ops.vcam.latency_report_save
        if not op.poll():
            raise RuntimeError(f"{op.idname()} is unavailable: no pose applied in this device session")
        result = sorted(op(filepath=path))
        return {"path": self.rel(path), "operator": result, "summary": self.session.latency_log().summary_line()}

    def cmd_save_blend(self, c):
        if not c.get("path"):
            raise ValueError('"save_blend" needs a "path"')
        path = resolve(c["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        result = bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
        return {"path": self.rel(path), "operator": sorted(result)}

    def cmd_open_blend(self, c):
        if not c.get("path"):
            raise ValueError('"open_blend" needs a "path"')
        result = bpy.ops.wm.open_mainfile(filepath=resolve(c["path"]))
        self.write_host("running")
        return {"blend": self.rel(bpy.data.filepath), "operator": sorted(result)}

    def cmd_eval(self, c):
        code = c.get("code")
        if not isinstance(code, str):
            raise ValueError('"eval" needs "code" (a string)')
        namespace = {"bpy": bpy, "C": bpy.context, "D": bpy.data, "session": self.session, "host": self, "result": None}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(compile(code, "<qa eval>", "exec"), namespace)
        value = namespace.get("result")
        reply = {"result": repr(value), "stdout": out.getvalue()}
        try:
            json.dumps(value)
            reply["value"] = value
        except (TypeError, ValueError):
            pass
        return reply


def main() -> None:
    host = Host(parse_args())
    try:
        host.start()
    except Exception as e:  # noqa: BLE001
        os.makedirs(QA_DIR, exist_ok=True)
        text = f"{type(e).__name__}: {e}"
        if hasattr(host, "log"):
            text = host.logmod.redact(text)
            host.log.exception("qa host failed to start")
        else:  # the add-on's redacting log isn't loaded
            text = text.replace(os.path.expanduser("~"), "~")
            print(traceback.format_exc().replace(os.path.expanduser("~"), "~"), file=sys.stderr)
        write_json(HOST_FILE, {"state": "failed", "error": text, "pid": os.getpid(), "started_at": host.started_at})
        if hasattr(host, "session"):
            host.session.stop()
        # Exit instead of re-raising: Blender would print the unredacted traceback to stdout.
        sys.exit(1)
    try:
        host.run()
    finally:
        host.shutdown()


main()
