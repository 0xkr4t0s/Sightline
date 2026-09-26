# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: offscreen stream frames (FR-REN-001/003/005).

Needs a GPU (`gpu.init()`); CI runners have none, so this runs locally for now. Install the
extension as for `smoke_native.py`, then:

    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/render_offscreen.py

- Submitted Solid frames are pixel-identical to independent draws at the matching pose, not blank.
- Material Preview and EEVEE frames match independent draws in those modes, not Solid.
- Pipelining carries the draw tick's pose seq and time, not the readback tick's.
- Display-referred material frames change with the scene view transform and look; uncorrected
  linear pixels differ, and the submitted bytes carry an sRGB/Rec.709 colour tag.
- Every 3D view's shading and overlays are unchanged even when the borrowed view is Wireframe.
- FrameSlot.submit refuses buffers of the wrong shape.
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
material = bpy.data.materials.new("Stream test red")
material.diffuse_color = (0.9, 0.02, 0.02, 1.0)
material.node_tree.nodes.get("Principled BSDF").inputs["Base Color"].default_value = material.diffuse_color
bpy.context.active_object.data.materials.append(material)
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


def reference(yaw_deg, mode='SOLID', color_management=True):
    """Independent synchronous draw at yaw_deg, with explicit viewport shading."""
    depsgraph = pose(yaw_deg)
    offscreen = gpu.types.GPUOffScreen(W, H, format='RGBA8')
    saved = space.shading.type, space.overlay.show_overlays
    space.shading.type, space.overlay.show_overlays = mode, False
    offscreen.draw_view3d(
        scene, view_layer, space, region,
        camera.matrix_world.inverted(), camera.calc_matrix_camera(depsgraph, x=W, y=H),
        do_color_management=color_management,
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
    assert frame['color_space'] == 'sRGB/Rec.709', frame['color_space']
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
for mode in ('MATERIAL', 'RENDERED'):
    expected = reference(0.0, mode)
    solid_error = np.abs(expected.astype(np.int16) - refs[0.0].astype(np.int16)).mean()
    assert solid_error > 2, f"{mode} reference indistinguishable from Solid"
    assert renderer.configure(W, H, mode)
    assert tick(0.0, 19, 9_000) is None  # the pending Solid frame was dropped
    assert slot._take() is None
    assert tick(0.0, 20, 10_000) is not None
    frame = slot._take()
    assert frame is not None
    pixels = np.frombuffer(frame['pixels'], dtype=np.uint8).reshape(H, W, 4)
    mode_error = np.abs(pixels.astype(np.int16) - expected.astype(np.int16)).mean()
    assert mode_error < solid_error / 2, (mode, mode_error, solid_error)

# Use the same scene colour settings that Blender uses for a Material viewport. Solid is
# Workbench shading and, like Blender's Solid viewport, does not track the scene look.
assert renderer.configure(W, H, 'MATERIAL')
saved_color = (scene.display_settings.display_device, scene.view_settings.view_transform, scene.view_settings.look)
scene.display_settings.display_device = 'sRGB'


def stream_color(seq):
    renderer.free()  # discard the preceding look's pending frame
    assert tick(0.0, seq, seq * 1_000) is None
    assert tick(0.0, seq + 1, (seq + 1) * 1_000) is not None
    frame = slot._take()
    assert frame['color_space'] == 'sRGB/Rec.709'
    return np.frombuffer(frame['pixels'], dtype=np.uint8).reshape(H, W, 4)


def max_rgb_diff(a, b):
    return int(np.abs(a[:, :, :3].astype(np.int16) - b[:, :, :3].astype(np.int16)).max())


try:
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.look = 'Medium Low Contrast'
    low = stream_color(21)
    # EEVEE sampling/8-bit quantization can differ by two codes on repeated draws.
    assert max_rgb_diff(low, reference(0.0, 'MATERIAL')) <= 2
    unmanaged_diff = max_rgb_diff(low, reference(0.0, 'MATERIAL', color_management=False))
    assert unmanaged_diff > 10, unmanaged_diff

    scene.view_settings.look = 'Medium High Contrast'
    high = stream_color(23)
    look_diff = max_rgb_diff(low, high)
    assert look_diff > 5 and max_rgb_diff(high, reference(0.0, 'MATERIAL')) <= 2, look_diff

    scene.view_settings.view_transform = 'AgX'
    scene.view_settings.look = 'AgX - Medium High Contrast'
    agx = stream_color(25)
    view_diff = max_rgb_diff(high, agx)
    assert view_diff > 5 and max_rgb_diff(agx, reference(0.0, 'MATERIAL')) <= 2, view_diff

    # A wide-gamut monitor setting must not change the meaning of tagged stream bytes
    # or be overwritten in the user's scene after the draw.
    scene.display_settings.display_device = 'Display P3'
    wide = stream_color(27)
    assert max_rgb_diff(wide, agx) <= 2, max_rgb_diff(wide, agx)
    assert (scene.display_settings.display_device, scene.view_settings.view_transform,
            scene.view_settings.look) == ('Display P3', 'AgX', 'AgX - Medium High Contrast')
    gamut_diff = max_rgb_diff(wide, reference(0.0, 'MATERIAL'))
    assert gamut_diff > 5, gamut_diff
finally:
    (scene.display_settings.display_device, scene.view_settings.view_transform,
     scene.view_settings.look) = saved_color

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

print(f"VCAM_RENDER_OK size={W}x{H} frames=7 modes=Solid/Material/EEVEE colours={colours} views_checked={len(spaces)}")
print(f"VCAM_COLOR_OK unmanaged_max={unmanaged_diff} look_max={look_diff} view_max={view_diff} "
      f"gamut_max={gamut_diff} display_restored=true tag=sRGB/Rec.709")
