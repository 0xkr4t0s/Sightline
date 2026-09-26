# SPDX-License-Identifier: GPL-3.0-or-later
"""N-panel (tasks 1.3.3, 1.3.6; FR-BL-004, FR-TRK-002): session on/off, pairing code, connected
device, pose rate, loss, latency, tracking state and hold, camera selection, and
origin/scale/lock settings.

Scale and locks come from the iPhone (`CONTROL_STATE` is the device's idempotent state,
FR-CTL-009), so they are shown, not edited, here. Set/Clear origin act on the host-side zero.
Values refresh from the session poll (`core/session.py`, 4 Hz redraw).
"""

from __future__ import annotations

import bpy

from ..core import session
from ..core.apply import camera_status, find_origin
from ..core.status import code_label, hold_label, locks_label, scale_label, tracking_label


class VCAM_PT_main_panel(bpy.types.Panel):
    """VCam session, device and rig."""

    bl_label = "Sightline"
    bl_idname = "VCAM_PT_main_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Sightline"

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
        camera, warning = camera_status(context.scene)
        if warning:
            col.label(text=warning, icon='ERROR')  # FR-BL-007
        col.prop(props, "smoothing")
        col.prop(props, "hold_last_good")

        if live is None:
            op = layout.operator("vcam.session_start", text="Start Session", icon='PLAY')
            op.port = props.port
            op.bind = props.bind_address
            return
        layout.operator("vcam.session_stop", text="Stop Session", icon='CANCEL')

        state = session.state
        box = layout.box()
        box.label(text=f"Listening on TCP {live.port()}", icon='WORLD_DATA')
        code = live.pairing_code()
        if code is not None:
            row = box.row()
            row.scale_y = 1.6
            row.label(text=f"Pairing code  {code_label(code)}", icon='LOCKED')
            box.operator("vcam.pairing_cancel", icon='X')
        else:
            box.operator("vcam.pairing_start", icon='LINKED')

        box = layout.box()
        if state.session_id is None:
            box.label(text="Waiting for a device", icon='INFO')
        else:
            stats = live.stats()
            box.label(text=state.device_name or "Device", icon='CAMERA_DATA')
            col = box.column(align=True)
            col.label(text=f"Tracking: {tracking_label(state.tracking_state)}")
            applier = session.applier()
            if applier.holding:
                col.label(text=hold_label(state.tracking_state, applier.hold.good is not None), icon='PAUSE')
            col.label(text=f"Poses: {stats['rate_hz']:.0f} Hz, loss {stats['loss'] * 100:.1f} %")
            if state.latency_ms is None:
                col.label(text="Latency: waiting for clock sync")
            else:
                col.label(text=f"Latency: {state.latency_ms:.1f} ms (clock jitter {state.clock_jitter_ms:.2f} ms)")
        samples = len(session.latency_log().pose_leg_ms)
        if samples:  # kept after the device leaves, until the next device session
            box.operator("vcam.latency_report_save", text=f"Save Latency Report ({samples} poses)", icon='EXPORT')

        box = layout.box()
        box.label(text="Rig", icon='EMPTY_AXIS')
        controls = session.applier().controls
        col = box.column(align=True)
        col.label(text=f"Motion scale: {scale_label(controls.motion_scale)}")
        col.label(text=f"Locks: {locks_label(controls.lock_flags)}")
        origin = find_origin(camera)
        if origin is not None:
            col.label(text=f"Origin object: {origin.name}")
        row = box.row(align=True)
        row.operator("vcam.origin_set", icon='PIVOT_CURSOR')
        row.operator("vcam.origin_clear", icon='LOOP_BACK')

        if state.last_error:
            layout.label(text=state.last_error, icon='ERROR')
