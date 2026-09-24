# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel: session start/stop, connection settings and live status (task 1.3.1).

The full panel (pairing code, device, latency, origin/scale/locks) is task 1.3.3.
"""

from __future__ import annotations

import bpy

from ..core import session


class VCAM_PT_main_panel(bpy.types.Panel):
    """VCam session and status."""

    bl_label = "VCam"
    bl_idname = "VCAM_PT_main_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "VCam"

    def draw(self, context):
        layout = self.layout
        props = context.scene.vcam_props
        live = session.current()

        box = layout.box()
        box.label(text="Connection", icon='URL')
        col = box.column(align=True)
        row = col.row(align=True)
        row.prop(props, "bind_address", text="Bind")
        row.prop(props, "port", text="Port")
        row.enabled = live is None
        col.prop(props, "target_camera", text="Camera", icon='CAMERA_DATA')

        layout.separator()
        if live is None:
            op = layout.operator("vcam.session_start", text="Start Session", icon='PLAY')
            op.port = props.port
            op.bind = props.bind_address
            return
        layout.operator("vcam.session_stop", text="Stop Session", icon='CANCEL')

        state = session.state
        stats = live.stats()
        box = layout.box()
        box.label(text=f"Listening on TCP {live.port()}", icon='WORLD_DATA')
        col = box.column(align=True)
        if state.session_id is None:
            col.label(text="Waiting for the iPhone", icon='INFO')
        else:
            col.label(text=f"Device: {state.device_name}", icon='CAMERA_DATA')
            col.label(text=f"Poses: {stats['rate_hz']:.0f} Hz, loss {stats['loss'] * 100:.1f} %")
        if state.last_error:
            col.label(text=state.last_error, icon='ERROR')
