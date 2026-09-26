# SPDX-License-Identifier: GPL-3.0-or-later
"""Offscreen stream renderer (task 2.1a; FR-REN-001, FR-REN-003, SRS §13.1).

Draws the VCam camera into a `GPUOffScreen` with `draw_view3d`, using the camera's own view and
projection matrices, so the stream doesn't depend on what the user's viewports show. Each frame
goes to `vcam_native.FrameSlot.submit`, which makes the only copy on the Python side.

Pipelined as measured in S-1b: a tick first reads the frame drawn on the previous tick (the GPU
has usually finished it by then, so `read()` barely waits), then draws the next one. A frame is
therefore one tick old when it's submitted. Its pose `seq` and draw time are captured when it's
drawn and submitted with it.

`draw_view3d` takes its shading from a `SpaceView3D`. The renderer uses one on a screen that no
window shows (a hidden workspace) when there is one, and sets Solid with overlays off for the
draw only, restoring the space's settings straight after. The user's viewports never change.

Main thread only. Not here yet: the timer, the main-thread budget and frame skipping (2.1b), the
stream settings (2.1c), colour management (2.1d).
"""

SHADING = 'SOLID'


def stream_view():
    """(space, region) to draw the stream with: a `VIEW_3D` on a hidden screen, else one on screen.

    None when no screen has a 3D view. Looked up every tick: the add-on keeps no `bpy` data
    across ticks (undo and file reload free it).
    """
    import bpy

    shown = {w.screen for w in bpy.context.window_manager.windows}
    fallback = None
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type != 'VIEW_3D':
                continue
            region = next((r for r in area.regions if r.type == 'WINDOW'), None)
            if region is None:
                continue
            if screen not in shown:
                return area.spaces.active, region
            fallback = fallback or (area.spaces.active, region)
    return fallback


class StreamRenderer:
    """Renders the camera at a fixed size into `slot` (a `vcam_native.FrameSlot`), one tick behind."""

    def __init__(self, slot, width: int = 960, height: int = 540) -> None:
        self.slot = slot
        self.width = width
        self.height = height
        self._offscreen = None
        # (pose_seq, render_time_ns) of the frame drawn but not read yet.
        self._pending = None

    def tick(self, scene, view_layer, depsgraph, camera, pose_seq: int, now_ns: int):
        """Submits the frame drawn on the previous tick, then draws `camera` for the next one.

        `depsgraph` must be evaluated (`context.evaluated_depsgraph_get()`), so the camera's
        matrix includes this tick's pose. With `camera` None nothing new is drawn. Returns the
        submitted `frame_id`, or None. Raises `RuntimeError` when no screen has a 3D view.
        """
        import gpu

        if self._offscreen is None:
            self._offscreen = gpu.types.GPUOffScreen(self.width, self.height, format='RGBA8')
        submitted = None
        if self._pending is not None:
            seq, drawn_ns = self._pending
            self._pending = None
            submitted = self.slot.submit(self._offscreen.texture_color.read(), seq, drawn_ns)
        if camera is not None:
            self._draw(scene, view_layer, depsgraph, camera)
            self._pending = (pose_seq, now_ns)
        return submitted

    def _draw(self, scene, view_layer, depsgraph, camera) -> None:
        view = stream_view()
        if view is None:
            raise RuntimeError("No 3D view to render the stream from")
        space, region = view
        shading, overlay = space.shading, space.overlay
        saved = shading.type, overlay.show_overlays
        shading.type, overlay.show_overlays = SHADING, False
        try:
            view_matrix = camera.evaluated_get(depsgraph).matrix_world.inverted()
            projection = camera.calc_matrix_camera(depsgraph, x=self.width, y=self.height)
            self._offscreen.draw_view3d(
                scene, view_layer, space, region, view_matrix, projection, do_color_management=True
            )
        finally:
            shading.type, overlay.show_overlays = saved

    def free(self) -> None:
        """Releases the GPU buffer; a frame drawn but not read yet is dropped."""
        if self._offscreen is not None:
            self._offscreen.free()
            self._offscreen = None
        self._pending = None
