# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel UI for VCam tracking controls."""

from __future__ import annotations

import bpy


class VCAM_PT_main_panel(bpy.types.Panel):
    """VCam tracking connection and settings."""

    bl_label = "VCam Tracking"
    bl_idname = "VCAM_PT_main_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "VCam"

    def draw(self, context):
        layout = self.layout
        props = context.scene.vcam_props

        # Connection section
        box = layout.box()
        box.label(text="Connection", icon='URL')

        col = box.column(align=True)
        row = col.row(align=True)
        row.prop(props, "host", text="Host")
        row.prop(props, "port", text="Port")
        row.enabled = not props.is_tracking

        # Target camera
        col.prop(props, "target_camera", text="Camera", icon='CAMERA_DATA')

        # Connect / Disconnect button
        layout.separator()
        if props.is_tracking:
            layout.operator("vcam.stop_tracking", text="Disconnect", icon='CANCEL')
        else:
            layout.operator("vcam.start_tracking", text="Connect", icon='PLAY')

        # Transform settings
        box = layout.box()
        box.label(text="Transform", icon='ORIENTATION_GIMBAL')
        box.prop(props, "euler_order")

        # Lens mapping
        box = layout.box()
        box.label(text="Lens Mapping", icon='CAMERA_DATA')
        col = box.column(align=True)
        col.prop(props, "zoom_min_focal")
        col.prop(props, "zoom_max_focal")
        col.separator()
        col.prop(props, "focus_min_distance")
        col.prop(props, "focus_max_distance")


class VCAM_PT_status_panel(bpy.types.Panel):
    """Live tracking data readback for debugging."""

    bl_label = "Status"
    bl_idname = "VCAM_PT_status_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "VCam"
    bl_parent_id = "VCAM_PT_main_panel"
    bl_options = {'DEFAULT_CLOSED'}

    def draw(self, context):
        layout = self.layout
        props = context.scene.vcam_props

        if not props.is_tracking:
            layout.label(text="Not connected", icon='INFO')
            return

        # Position
        box = layout.box()
        box.label(text="Position (m)", icon='EMPTY_ARROWS')
        row = box.row()
        row.prop(props, "last_pos_x", text="X")
        row.prop(props, "last_pos_y", text="Y")
        row.prop(props, "last_pos_z", text="Z")

        # Rotation
        box = layout.box()
        box.label(text="Rotation (deg)", icon='DRIVER_ROTATIONAL_DIFFERENCE')
        row = box.row()
        row.prop(props, "last_pitch", text="P")
        row.prop(props, "last_yaw", text="Y")
        row.prop(props, "last_roll", text="R")

        # Stats
        box = layout.box()
        box.label(text="Network", icon='WORLD_DATA')
        col = box.column(align=True)
        col.label(text=f"Received: {props.packets_received}")
        col.label(text=f"Dropped: {props.packets_dropped}")
