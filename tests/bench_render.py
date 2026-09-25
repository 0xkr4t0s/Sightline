# SPDX-License-Identifier: GPL-3.0-or-later
"""Spike S-1: offscreen render + readback timing (docs/IMPLEMENTATION_PLAN.md §0.2).

For each shading mode and resolution: draw the scene camera into a `GPUOffScreen` with
`draw_view3d`, read the colour texture back, and hand the buffer to `vcam_native`
(`FrameSlot.submit`, the one-copy hand-off of task 2.1a). The camera moves slightly every frame, like a live VCam, so EEVEE's
viewport sample accumulation can't make repeat frames artificially cheap.

Headless (no visible 3D view; `gpu.init()` provides the GPU context):

    blender --background --factory-startup --python-exit-code 1 \
        --python tests/bench_render.py -- --json out.json --save-dir /tmp/s1

In the UI (a window opens; the script drives itself from `bpy.app.timers` and quits):

    blender --factory-startup --python tests/bench_render.py -- --json out.json

`vcam_native` is used if the built extension is installed (see tests/blender/smoke_native.py);
otherwise the hand-off column is skipped.
"""

import argparse
import json
import math
import os
import statistics
import sys
import time
import traceback

import bpy
import gpu
import numpy as np
from mathutils import Matrix

RESOLUTIONS = {"540p": (960, 540), "720p": (1280, 720), "1080p": (1920, 1080)}
MODES = ("SOLID", "MATERIAL", "RENDERED")  # RENDERED = EEVEE viewport
ADDON = "bl_ext.user_default.vcam_blender"
DEFERRED_FRAMES = 20
DEFERRED_IDLE_S = 0.040


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--frames", type=int, default=60)
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--json", help="write results here")
    p.add_argument("--save-dir", help="save one PNG per mode at 540p for visual checks")
    p.add_argument("--dump-raw", help="write each cell's last frame as raw RGBA (bottom-up rows) for S-2")
    p.add_argument("--interval", type=float, help="seconds between frames (default: 0 headless, 1/30 UI)")
    return p.parse_args(argv)


def build_scene():
    """Default scene plus a 5x5 grid of subdivided Suzannes with a shared material."""
    mat = bpy.data.materials.new("S1_Material")
    mat.diffuse_color = (0.8, 0.3, 0.2, 1.0)
    for i in range(25):
        x, y = (i % 5 - 2) * 2.5, (i // 5 - 2) * 2.5
        bpy.ops.mesh.primitive_monkey_add(location=(x, y, 0.0))
        obj = bpy.context.active_object
        obj.modifiers.new("Subsurf", "SUBSURF").levels = 2
        obj.data.materials.append(mat)
    cam = bpy.context.scene.camera
    cam.location = (0.0, -16.0, 9.0)
    cam.rotation_euler = (math.radians(62.0), 0.0, 0.0)
    bpy.context.view_layer.update()  # otherwise camera.matrix_world is stale for the first cell


def evaluated_triangles():
    depsgraph = bpy.context.evaluated_depsgraph_get()
    total = 0
    for inst in depsgraph.object_instances:
        if inst.object.type == "MESH":
            mesh = inst.object.data
            mesh.calc_loop_triangles()
            total += len(mesh.loop_triangles)
    return total


def view3d_space_and_region():
    """A VIEW_3D space + WINDOW region, preferring a screen that no window is showing.

    The offscreen render takes its shading settings from this space, so using a hidden
    screen leaves the user's visible viewports untouched (and proves none is needed).
    """
    shown = {w.screen for w in bpy.context.window_manager.windows}
    screens = [s for s in bpy.data.screens if s not in shown] + list(shown)
    for screen in screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                region = next(r for r in area.regions if r.type == "WINDOW")
                return screen.name, area.spaces.active, region
    raise RuntimeError("no VIEW_3D area in any screen")


def load_vcam_native():
    try:
        import addon_utils

        addon_utils.enable(ADDON, default_set=True, handle_error=None)
        import vcam_native

        return vcam_native if hasattr(vcam_native, "FrameSlot") else None
    except Exception:
        return None


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def save_png(pixels, width, height, path):
    img = bpy.data.images.new("S1_Save", width, height, alpha=True)
    img.pixels.foreach_set((pixels.astype(np.float32) / 255.0).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def bench(mode, width, height, args, ctx, out):
    """Benchmark one cell. A generator: each `yield` returns control to the caller for
    the given number of seconds (headless: sleep; UI: the next timer tick), and the
    result is stored in `out`."""
    scene, view_layer, native = ctx["scene"], ctx["view_layer"], ctx["native"]
    _, space, region = view3d_space_and_region()
    space.shading.type = mode
    space.overlay.show_overlays = False  # viewfinder shows the camera image only
    cam = scene.camera
    base = cam.matrix_world.copy()
    proj = cam.calc_matrix_camera(ctx["depsgraph"], x=width, y=height)
    offscreens = [gpu.types.GPUOffScreen(width, height, format="RGBA8") for _ in range(2)]
    offscreen = offscreens[0]

    def move_camera(i):
        # ~0.2 degree pan per frame: a new view every frame, like a live VCam. Moving the
        # object (not just the view matrix) also makes visible viewports redraw.
        cam.matrix_world = Matrix.Rotation(math.radians(0.2 * i), 4, "Z") @ base
        return cam.matrix_world.inverted()

    def draw(target, i):
        target.draw_view3d(scene, view_layer, space, region, move_camera(i), proj, do_color_management=True)

    keys = ("draw", "read", "draw_read", "handoff", "copy", "read_deferred", "pipelined", "pipelined_read", "pipelined_draw", "tick_gap")
    rows = {k: [] for k in keys}
    first_ms = None
    pixels = None
    last_tick = None
    slot = native.FrameSlot() if native is not None else None
    for i in range(args.warmup + args.frames):
        t0 = time.perf_counter()
        if last_tick is not None and i > args.warmup:
            rows["tick_gap"].append((t0 - last_tick) * 1000)
        last_tick = t0
        draw(offscreen, i)
        t1 = time.perf_counter()
        buf = offscreen.texture_color.read()  # blocks until the GPU has finished the frame
        t2 = time.perf_counter()
        if slot is not None:
            slot.submit(buf, i, 0)  # the production hand-off: one copy into Rust's buffer
        t3 = time.perf_counter()
        pixels = np.asarray(buf)  # zero-copy view
        copied = pixels.copy()  # reference: one full memcpy of the frame
        t4 = time.perf_counter()
        del copied
        if i == 0:
            first_ms = (t2 - t0) * 1000
        if i >= args.warmup:
            rows["draw"].append((t1 - t0) * 1000)
            rows["read"].append((t2 - t1) * 1000)
            rows["draw_read"].append((t2 - t0) * 1000)
            if slot is not None:
                rows["handoff"].append((t3 - t2) * 1000)
            rows["copy"].append((t4 - t3) * 1000)
        yield args.interval

    # Deferred read: draw in one tick, read in the next. If read() mostly waits for the
    # GPU, idling between the two moves that wait off the main thread.
    for i in range(DEFERRED_FRAMES):
        draw(offscreen, -i)
        yield DEFERRED_IDLE_S
        t0 = time.perf_counter()
        offscreen.texture_color.read()
        rows["read_deferred"].append((time.perf_counter() - t0) * 1000)

    # Pipelined (the Phase 2 design): each tick reads the frame drawn on the previous
    # tick, then draws the next one into the other offscreen. Cost = read + draw per tick.
    draw(offscreens[1], 0)
    yield args.interval
    for i in range(1, args.frames + 1):
        t0 = time.perf_counter()
        offscreens[i % 2].texture_color.read()
        t1 = time.perf_counter()
        draw(offscreens[(i + 1) % 2], i)
        t2 = time.perf_counter()
        rows["pipelined"].append((t2 - t0) * 1000)
        rows["pipelined_read"].append((t1 - t0) * 1000)
        rows["pipelined_draw"].append((t2 - t1) * 1000)
        yield args.interval
    for o in offscreens:
        o.free()
    cam.matrix_world = base

    assert pixels.dtype == np.uint8 and pixels.shape == (height, width, 4), (pixels.dtype, pixels.shape)
    assert np.shares_memory(pixels, np.asarray(buf))
    colours = len(np.unique(pixels[::8, ::8].reshape(-1, 4), axis=0))
    assert colours > 16, f"{mode} {width}x{height}: image looks blank ({colours} colours)"

    out["result"] = {
        "mode": mode,
        "width": width,
        "height": height,
        "first_frame_ms": round(first_ms, 2),
        "sampled_colours": colours,
    }
    for key, vals in rows.items():
        if vals:
            out["result"][key] = {
                "median_ms": round(statistics.median(vals), 3),
                "p95_ms": round(pct(vals, 0.95), 3),
            }
    out["pixels"] = pixels


def run_all(args, ctx, info):
    """Generator over every cell; yields pause lengths in seconds."""
    results = []
    for mode in MODES:
        for label, (w, h) in RESOLUTIONS.items():
            out = {}
            yield from bench(mode, w, h, args, ctx, out)
            results.append(out["result"])
            print("S1_RESULT", json.dumps(out["result"]), flush=True)
            if args.dump_raw:
                out["pixels"].tofile(f"{args.dump_raw}/{mode.lower()}_{w}x{h}.rgba")
            if args.save_dir and label == "540p":
                save_png(out["pixels"], w, h, f"{args.save_dir}/s1_{mode.lower()}_{label}.png")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"info": info, "results": results}, f, indent=2)


def main():
    args = parse_args()
    if args.interval is None:
        args.interval = 0.0 if bpy.app.background else 1.0 / 30.0
    if bpy.app.background:
        gpu.init()
    build_scene()
    # Timer callbacks have no window context, so capture everything context-bound now.
    ctx = {
        "scene": bpy.context.scene,
        "view_layer": bpy.context.view_layer,
        "depsgraph": bpy.context.evaluated_depsgraph_get(),
        "native": load_vcam_native(),
    }
    info = {
        "blender": bpy.app.version_string,
        "gpu_backend": gpu.platform.backend_type_get(),
        "gpu_renderer": gpu.platform.renderer_get(),
        "background": bpy.app.background,
        "offscreen_settings_from_screen": view3d_space_and_region()[0],
        "shown_screens": [w.screen.name for w in bpy.context.window_manager.windows],
        "vcam_native": getattr(ctx["native"], "__file__", None),
        "frames": args.frames,
        "interval_s": args.interval,
        "triangles": evaluated_triangles(),
    }
    print("S1_INFO", json.dumps(info), flush=True)
    steps = run_all(args, ctx, info)

    if bpy.app.background:
        for pause in steps:
            if pause:
                time.sleep(pause)
        return

    # UI: drive the same steps from a timer so Blender's event loop (and any visible
    # viewport redraws) runs between frames. Quit when done; exit 1 on any error.
    def tick():
        try:
            return next(steps)
        except StopIteration:
            print("S1_DONE", flush=True)
            bpy.ops.wm.quit_blender()
        except Exception:
            traceback.print_exc()
            sys.stdout.flush()
            os._exit(1)
        return None

    bpy.app.timers.register(tick, first_interval=1.0)


main()
