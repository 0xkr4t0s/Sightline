# SPDX-License-Identifier: GPL-3.0-or-later
"""Modal operators for real-time camera tracking.

The tracking receiver is a modal operator that polls UDP data at ~60Hz
from Blender's main thread and applies transforms to the active camera.
All bpy.* calls happen here on the main thread — never in the background
UDP receiver thread.
"""

from __future__ import annotations

import bpy

from ..core.udp_client import UDPTrackingClient
from ..core.transform import freed_to_blender_matrix, zoom_to_focal_length, focus_to_distance


class VCAM_OT_start_tracking(bpy.types.Operator):
    """Start receiving camera tracking data over UDP"""

    bl_idname = "vcam.start_tracking"
    bl_label = "Start Camera Tracking"
    bl_description = "Begin receiving FreeD camera tracking data over UDP"
    bl_options = {'REGISTER'}

    _timer = None
    _client: UDPTrackingClient | None = None

    @classmethod
    def poll(cls, context):
        props = context.scene.vcam_props
        return not props.is_tracking and context.scene.camera is not None

    def modal(self, context, event):
        props = context.scene.vcam_props

        # Check for stop request
        if not props.is_tracking or event.type == 'ESC':
            self._shutdown(context)
            return {'CANCELLED'}

        if event.type != 'TIMER':
            return {'PASS_THROUGH'}

        frame = self._client.get_latest()
        if frame is None:
            return {'PASS_THROUGH'}

        camera_obj = props.target_camera if props.target_camera else context.scene.camera
        if camera_obj is None:
            return {'PASS_THROUGH'}

        # Apply 6DOF transform
        mat = freed_to_blender_matrix(frame, euler_order=props.euler_order)
        camera_obj.matrix_world = mat

        # Apply lens properties if camera has data
        if camera_obj.data and hasattr(camera_obj.data, 'lens'):
            if frame.zoom > 0:
                camera_obj.data.lens = zoom_to_focal_length(
                    frame.zoom,
                    min_focal=props.zoom_min_focal,
                    max_focal=props.zoom_max_focal,
                )
            if frame.focus > 0 and camera_obj.data.dof.use_dof:
                camera_obj.data.dof.focus_distance = focus_to_distance(
                    frame.focus,
                    min_distance=props.focus_min_distance,
                    max_distance=props.focus_max_distance,
                )

        # Store debug info
        props.last_pos_x = frame.pos_x
        props.last_pos_y = frame.pos_y
        props.last_pos_z = frame.pos_z
        props.last_pitch = frame.pitch
        props.last_yaw = frame.yaw
        props.last_roll = frame.roll
        props.packets_received = self._client.packets_received
        props.packets_dropped = self._client.packets_dropped

        # Force viewport redraw
        for area in context.screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()

        return {'PASS_THROUGH'}

    def execute(self, context):
        props = context.scene.vcam_props

        self._client = UDPTrackingClient(props.host, props.port)
        try:
            self._client.start()
        except OSError as e:
            self.report({'ERROR'}, f"Failed to bind UDP socket: {e}")
            return {'CANCELLED'}

        self._timer = context.window_manager.event_timer_add(
            1.0 / 60.0, window=context.window
        )
        context.window_manager.modal_handler_add(self)
        props.is_tracking = True

        self.report({'INFO'}, f"VCam tracking started on {props.host}:{props.port}")
        return {'RUNNING_MODAL'}

    def _shutdown(self, context):
        """Clean up timer and UDP client."""
        props = context.scene.vcam_props
        if self._timer is not None:
            context.window_manager.event_timer_remove(self._timer)
            self._timer = None
        if self._client is not None:
            self._client.stop()
            self._client = None
        props.is_tracking = False
        self.report({'INFO'}, "VCam tracking stopped")

    def cancel(self, context):
        self._shutdown(context)


class VCAM_OT_stop_tracking(bpy.types.Operator):
    """Stop receiving camera tracking data"""

    bl_idname = "vcam.stop_tracking"
    bl_label = "Stop Camera Tracking"
    bl_description = "Stop receiving tracking data and release the UDP socket"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        return context.scene.vcam_props.is_tracking

    def execute(self, context):
        context.scene.vcam_props.is_tracking = False
        return {'FINISHED'}
