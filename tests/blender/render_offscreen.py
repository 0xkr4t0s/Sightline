# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: the offscreen stream renderer (task 2.1a; FR-REN-001, FR-REN-003).

Needs a GPU (`gpu.init()`); CI runners have none, so this runs locally for now. Install the
extension as for `smoke_native.py`, then:

    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/render_offscreen.py

- Each submitted frame is 320×180 RGBA8, not blank, and pixel-identical to an independent
  synchronous Solid draw of the camera at the pose it was drawn with, with overlays off.
- Pipelining: a frame is submitted one tick after it's drawn, with that tick's pose seq and draw
  time, even though the camera has moved since.
- Every 3D view's shading and overlays are unchanged afterwards, and the stream stays Solid while
  the hidden view it borrows is set to Wireframe with overlays on.
- `FrameSlot.submit` refuses a buffer that isn't shaped (height, width, 4).
"""

import importlib
import math

import addon_utils
import bpy
import gpu
import numpy as np
from mathutils import Matrix

MODULE = "bl_ext.user_default.vcam_blender"
W, H = 320, 180

gpu.init()
addon_utils.enable(MODULE, default_set=True, handle_error=None)
render = importlib.import_module(MODULE + ".core.render")
import vcam_native  # noqa: E402 (installed by the extension)

scene = bpy.context.scene
view_layer = bpy.context.view_layer
camera = scene.camera
bpy.ops.mesh.primitive_monkey_add(location=(0.0, 0.0, 1.5))
bpy.context.active_object.modifiers.new("smooth", 'SUBSURF').levels = 2
bpy.ops.object.shade_smooth()
base = camera.matrix_world.copy()

spaces = [a.spaces.active for s in bpy.data.screens for a in s.areas if a.type == 'VIEW_3D']
space, region = render.stream_view()
shown = {w.screen for w in bpy.context.window_manager.windows}
assert all(space != a.spaces.active for s in shown for a in s.areas), "expected a hidden 3D view"
space.shading.type = 'WIREFRAME'  # the stream must not follow the borrowed view's settings
space.overlay.show_overlays = True
before = [(s.shading.type, s.overlay.show_overlays) for s in spaces]


def pose(yaw_deg):
    camera.matrix_world = Matrix.Rotation(math.radians(yaw_deg), 4, 'Z') @ base
    return bpy.context.evaluated_depsgraph_get()


def reference(yaw_deg):
    """Synchronous Solid draw at `yaw_deg`, written without the add-on's code."""
    depsgraph = pose(yaw_deg)
    offscreen = gpu.types.GPUOffScreen(W, H, format='RGBA8')
    saved = space.shading.type, space.overlay.show_overlays
    space.shading.type, space.overlay.show_overlays = 'SOLID', False
    offscreen.draw_view3d(
        scene, view_layer, space, region,
        camera.matrix_world.inverted(), camera.calc_matrix_camera(depsgraph, x=W, y=H),
        do_color_management=True,
    )
    space.shading.type, space.overlay.show_overlays = saved
    pixels = np.array(offscreen.texture_color.read(), dtype=np.uint8)
    offscreen.free()
    return pixels.reshape(H, W, 4)


refs = {yaw: reference(yaw) for yaw in (0.0, 8.0, 16.0)}
assert not np.array_equal(refs[0.0], refs[8.0]), "poses must look different"

slot = vcam_native.FrameSlot()
renderer = render.StreamRenderer(slot, W, H)


def tick(yaw_deg, seq, now_ns, cam=camera):
    return renderer.tick(scene, view_layer, pose(yaw_deg), cam, seq, now_ns)


def check(frame_id, yaw_deg, seq, now_ns):
    frame = slot._take()
    assert frame is not None, "no frame submitted"
    got = {k: frame[k] for k in ("frame_id", "width", "height", "pose_seq", "render_time_ns")}
    assert got == {"frame_id": frame_id, "width": W, "height": H, "pose_seq": seq, "render_time_ns": now_ns}, got
    pixels = np.frombuffer(frame["pixels"], dtype=np.uint8).reshape(H, W, 4)
    colours = len(np.unique(pixels[::4, ::4].reshape(-1, 4), axis=0))
    assert colours > 16, f"frame {frame_id} looks blank ({colours} colours)"
    diff = int(np.abs(pixels.astype(np.int16) - refs[yaw_deg]).max())
    assert diff == 0, f"frame {frame_id} differs from the Solid reference at {yaw_deg}° (max {diff})"
    others = [y for y in refs if y != yaw_deg and np.array_equal(pixels, refs[y])]
    assert not others, f"frame {frame_id} shows the pose at {others}"
    return colours


assert tick(0.0, 11, 1_000) is None, "nothing to submit on the first tick"
assert slot._take() is None
assert tick(8.0, 12, 2_000) == 1
colours = check(1, 0.0, 11, 1_000)
assert tick(16.0, 13, 3_000) == 2
check(2, 8.0, 12, 2_000)
assert tick(0.0, 14, 4_000, cam=None) == 3, "the drawn frame is still submitted without a camera"
check(3, 16.0, 13, 3_000)
assert tick(0.0, 15, 5_000, cam=None) is None, "nothing drawn without a camera"
assert slot._take() is None

# Newest frame wins when nobody takes them.
tick(8.0, 16, 6_000)
tick(16.0, 17, 7_000)
tick(0.0, 18, 8_000)
assert slot.replaced() == 1, slot.replaced()
check(5, 16.0, 17, 7_000)
renderer.free()

after = [(s.shading.type, s.overlay.show_overlays) for s in spaces]
assert after == before, (before, after)

for bad in (np.zeros((H, W, 3), np.uint8), np.zeros(W * H * 4, np.uint8), np.zeros((0, W, 4), np.uint8)):
    try:
        slot.submit(bad, 1, 1)
    except ValueError:
        pass
    else:
        raise AssertionError(f"shape {bad.shape} accepted")

print(f"VCAM_RENDER_OK size={W}x{H} frames=5 colours={colours} views_checked={len(spaces)}")
