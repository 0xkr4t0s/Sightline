# SPDX-License-Identifier: GPL-3.0-or-later
"""Offscreen stream renderer (task 2.1; FR-REN-001..005, SRS §13.1).

Draws the VCam camera into a `GPUOffScreen` with `draw_view3d`, using the camera's own view and
projection matrices, so the stream doesn't depend on what the user's viewports show. Each frame
goes to `vcam_native.FrameSlot.submit`, which makes the only copy on the Python side.

Pipelined as measured in S-1b: a tick first reads the frame drawn on the previous tick (the GPU
has usually finished it by then, so `read()` barely waits), then draws the next one. A frame is
therefore one tick old when it's submitted. Its pose `seq` and draw time are captured when it's
drawn and submitted with it.

draw_view3d takes its shading from a SpaceView3D. The renderer uses one on a screen that no
window shows (a hidden workspace) when there is one, and sets the selected shading with overlays
off for the draw only, restoring the space's settings straight after. User viewports never change.

Main thread only. The session poll drives it at the selected fps cap, skipping frames after
expensive draw/read operations. Blender applies the viewport display transform and look to
Material Preview/Rendered; Solid follows Blender's Workbench viewport. The result is sRGB.
"""

import time

DEFAULT_BUDGET_MS = 12
STREAM_RESOLUTIONS = {'360p': (640, 360), '540p': (960, 540), '720p': (1280, 720), '1080p': (1920, 1080)}
STREAM_FPS_CAPS = (24, 30, 60)


class FramePacer:
    """Skip frames after an over-budget draw/read, without catching up missed frames.

    A synchronous GPU call cannot be interrupted: the budget limits how often it runs, not the
    duration of any single GPU call.
    """

    def __init__(self, budget_ms: int = DEFAULT_BUDGET_MS) -> None:
        self.budget_ms = budget_ms
        self.fps = 30
        self.next_due_ns = 0
        self.cost_ns = 0

    def due(self, now_ns: int, budget_ms: int, fps: int) -> bool:
        if budget_ms != self.budget_ms or fps != self.fps:
            self.budget_ms = budget_ms
            self.fps = fps
            self.next_due_ns = now_ns  # a new setting takes effect without waiting for an old skip
        return now_ns >= self.next_due_ns

    def record(self, now_ns: int, read_ns: int, draw_ns: int) -> None:
        measured = read_ns + draw_ns
        # Raise the estimate immediately under load; decay slowly when GPU contention clears.
        self.cost_ns = max(measured, (3 * self.cost_ns + measured) // 4)
        budget_ns = self.budget_ms * 1_000_000
        frames = min(self.fps, max(1, (self.cost_ns + budget_ns - 1) // budget_ns))
        self.next_due_ns = now_ns + frames * (1_000_000_000 // self.fps)


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
    """Renders the camera into `slot` (a `vcam_native.FrameSlot`), one tick behind."""

    def __init__(self, slot, width: int = 960, height: int = 540, shading: str = 'SOLID') -> None:
        self.slot = slot
        self.width = width
        self.height = height
        self.shading = shading
        self._offscreen = None
        # (pose_seq, render_time_ns) of the frame drawn but not read yet.
        self._pending = None
        self.read_ns = 0
        self.draw_ns = 0

    def configure(self, width: int, height: int, shading: str) -> bool:
        """Discard the old setting's pending frame before drawing with the new one."""
        if (width, height, shading) == (self.width, self.height, self.shading):
            return False
        self.free()
        self.width, self.height, self.shading = width, height, shading
        return True

    def tick(self, scene, view_layer, depsgraph, camera, pose_seq: int, now_ns: int):
        """Submits the frame drawn on the previous tick, then draws `camera` for the next one.

        `depsgraph` must be evaluated (`context.evaluated_depsgraph_get()`), so the camera's
        matrix includes this tick's pose. With `camera` None nothing new is drawn. Returns the
        submitted `frame_id`, or None. Raises `RuntimeError` when no screen has a 3D view.
        """
        import gpu

        if self._offscreen is None:
            self._offscreen = gpu.types.GPUOffScreen(self.width, self.height, format='RGBA8')
        self.read_ns = self.draw_ns = 0
        submitted = None
        if self._pending is not None:
            seq, drawn_ns = self._pending
            self._pending = None
            started = time.perf_counter_ns()
            submitted = self.slot.submit(self._offscreen.texture_color.read(), seq, drawn_ns)
            self.read_ns = time.perf_counter_ns() - started
        if camera is not None:
            started = time.perf_counter_ns()
            self._draw(scene, view_layer, depsgraph, camera)
            self.draw_ns = time.perf_counter_ns() - started
            self._pending = (pose_seq, now_ns)
        return submitted

    def _draw(self, scene, view_layer, depsgraph, camera) -> None:
        view = stream_view()
        if view is None:
            raise RuntimeError("No 3D view to render the stream from")
        space, region = view
        shading, overlay = space.shading, space.overlay
        display = scene.display_settings
        saved = shading.type, overlay.show_overlays
        saved_device = display.display_device
        shading.type, overlay.show_overlays = self.shading, False
        try:
            if saved_device != 'sRGB':
                display.display_device = 'sRGB'  # the frame is tagged sRGB, not the user's monitor gamut
            view_matrix = camera.evaluated_get(depsgraph).matrix_world.inverted()
            projection = camera.calc_matrix_camera(depsgraph, x=self.width, y=self.height)
            self._offscreen.draw_view3d(
                scene, view_layer, space, region, view_matrix, projection, do_color_management=True
            )
        finally:
            try:
                if saved_device != 'sRGB':
                    display.display_device = saved_device
            finally:
                shading.type, overlay.show_overlays = saved

    def free(self) -> None:
        """Releases the GPU buffer; a frame drawn but not read yet is dropped."""
        if self._offscreen is not None:
            self._offscreen.free()
            self._offscreen = None
        self._pending = None


class StreamLoop:
    """One connected device's renderer and adaptive fps schedule."""

    def __init__(self, slot) -> None:
        self.renderer = StreamRenderer(slot)
        self.pacer = FramePacer()

    def tick(self, context, camera, pose_seq: int, clock_ns, budget_ms: int,
             fps: int, resolution: tuple[int, int], shading: str):
        if self.renderer.configure(*resolution, shading):
            self.pacer.next_due_ns = 0
            self.pacer.cost_ns = 0  # a new mode's GPU cost may be very different
        if not self.pacer.due(clock_ns(), budget_ms, fps):
            return None
        depsgraph = context.evaluated_depsgraph_get()
        now_ns = clock_ns()  # same host clock as CLOCK; after evaluation, just before drawing
        submitted = self.renderer.tick(context.scene, context.view_layer, depsgraph, camera, pose_seq, now_ns)
        self.pacer.record(now_ns, self.renderer.read_ns, self.renderer.draw_ns)
        return submitted

    def free(self) -> None:
        self.renderer.free()
