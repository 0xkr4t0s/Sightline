# SPDX-License-Identifier: GPL-3.0-or-later
"""Spike S-1: offscreen render + readback timing (docs/IMPLEMENTATION_PLAN.md §0.2).

For each shading mode and resolution: draw the scene camera into a `GPUOffScreen` with
`draw_view3d`, read the colour texture back, and hand the buffer to `vcam_native`
without copying. The camera moves slightly every frame, like a live VCam, so EEVEE's
viewport sample accumulation can't make repeat frames artificially cheap.

Headless (no visible 3D view; `gpu.init()` provides the GPU context):

    blender --background --factory-startup --python-exit-code 1 \
        --python tests/bench_render.py -- --json out.json --save-dir /tmp/s1

`vcam_native` is used if the built extension is installed (see tests/blender/smoke_native.py);
otherwise the zero-copy column is skipped.
"""

import argparse
import json
import math
import statistics
import sys
import time

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
    for area in bpy.context.window.screen.areas:
        if area.type == "VIEW_3D":
            region = next(r for r in area.regions if r.type == "WINDOW")
            return area.spaces.active, region
    raise RuntimeError("no VIEW_3D area in the current screen")


def load_vcam_native():
    try:
        import addon_utils

        addon_utils.enable(ADDON, default_set=True, handle_error=None)
        import vcam_native

        return vcam_native if hasattr(vcam_native, "_frame_probe") else None
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


def bench(mode, width, height, args, native):
    scene, view_layer = bpy.context.scene, bpy.context.view_layer
    space, region = view3d_space_and_region()
    space.shading.type = mode
    space.overlay.show_overlays = False  # viewfinder shows the camera image only
    cam = scene.camera
    base = cam.matrix_world.copy()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    proj = cam.calc_matrix_camera(depsgraph, x=width, y=height)
    offscreen = gpu.types.GPUOffScreen(width, height, format="RGBA8")

    rows = {"draw": [], "read": [], "draw_read": [], "probe": [], "copy": [], "read_deferred": []}
    first_ms = None
    pixels = None
    checksum = None
    for i in range(args.warmup + args.frames):
        # ~0.2 degree pan per frame so each frame is a new view.
        view = (Matrix.Rotation(math.radians(0.2 * i), 4, "Z") @ base).inverted()
        t0 = time.perf_counter()
        offscreen.draw_view3d(scene, view_layer, space, region, view, proj, do_color_management=True)
        t1 = time.perf_counter()
        buf = offscreen.texture_color.read()  # blocks until the GPU has finished the frame
        t2 = time.perf_counter()
        if native is not None:
            nbytes, checksum = native._frame_probe(buf)  # zero-copy, reads every byte
            assert nbytes == width * height * 4, nbytes
        t3 = time.perf_counter()
        pixels = np.asarray(buf)  # zero-copy view
        copied = pixels.copy()  # reference: one full memcpy of the frame
        t4 = time.perf_counter()
        if i == 0:
            first_ms = (t2 - t0) * 1000
        if i < args.warmup:
            continue
        rows["draw"].append((t1 - t0) * 1000)
        rows["read"].append((t2 - t1) * 1000)
        rows["draw_read"].append((t2 - t0) * 1000)
        if native is not None:
            rows["probe"].append((t3 - t2) * 1000)
        rows["copy"].append((t4 - t3) * 1000)
        del copied

    # Deferred read: draw in one timer tick, read in the next. If read() mostly waits
    # for the GPU, idling between the two moves that wait off the main thread.
    for i in range(DEFERRED_FRAMES):
        view = (Matrix.Rotation(math.radians(-0.2 * i), 4, "Z") @ base).inverted()
        offscreen.draw_view3d(scene, view_layer, space, region, view, proj, do_color_management=True)
        time.sleep(DEFERRED_IDLE_S)
        t0 = time.perf_counter()
        offscreen.texture_color.read()
        rows["read_deferred"].append((time.perf_counter() - t0) * 1000)
    offscreen.free()

    assert pixels.dtype == np.uint8 and pixels.shape == (height, width, 4), (pixels.dtype, pixels.shape)
    assert np.shares_memory(pixels, np.asarray(buf))
    colours = len(np.unique(pixels[::8, ::8].reshape(-1, 4), axis=0))
    assert colours > 16, f"{mode} {width}x{height}: image looks blank ({colours} colours)"

    result = {
        "mode": mode,
        "width": width,
        "height": height,
        "first_frame_ms": round(first_ms, 2),
        "sampled_colours": colours,
        "zero_copy_checksum": checksum,
    }
    for key, vals in rows.items():
        if vals:
            result[key] = {
                "median_ms": round(statistics.median(vals), 3),
                "p95_ms": round(pct(vals, 0.95), 3),
            }
    return result, pixels


def main():
    args = parse_args()
    if bpy.app.background:
        gpu.init()
    build_scene()
    native = load_vcam_native()
    info = {
        "blender": bpy.app.version_string,
        "gpu_backend": gpu.platform.backend_type_get(),
        "gpu_renderer": gpu.platform.renderer_get(),
        "background": bpy.app.background,
        "vcam_native": getattr(native, "__file__", None),
        "frames": args.frames,
        "triangles": evaluated_triangles(),
    }
    print("S1_INFO", json.dumps(info))
    results = []
    for mode in MODES:
        for label, (w, h) in RESOLUTIONS.items():
            result, pixels = bench(mode, w, h, args, native)
            results.append(result)
            print("S1_RESULT", json.dumps(result))
            if args.save_dir and label == "540p":
                save_png(pixels, w, h, f"{args.save_dir}/s1_{mode.lower()}_{label}.png")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"info": info, "results": results}, f, indent=2)


main()
