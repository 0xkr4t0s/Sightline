# SPDX-License-Identifier: GPL-3.0-or-later
"""VCam session operators: start/stop (1.2.5b), pairing and Set/Clear origin (1.3.3), and the
pose-leg latency report (1.5.1)."""

from __future__ import annotations

import json
import time

import bpy
from bpy_extras.io_utils import ExportHelper

from ..core import session
from ..core.apply import ZERO_YAW_KEY, find_origin, target_camera
from ..core.status import code_label


class VCAM_OT_session_start(bpy.types.Operator):
    """Start listening for the Sightline app and advertise this Blender session"""

    bl_idname = "vcam.session_start"
    bl_label = "Start Sightline Session"
    bl_options = {'REGISTER'}

    port: bpy.props.IntProperty(
        name="Port",
        description="TCP control port (0 picks a free port)",
        default=session.DEFAULT_PORT,
        min=0,
        max=65535,
    )
    bind: bpy.props.StringProperty(
        name="Bind Address",
        description="Local address to listen on (0.0.0.0 for all interfaces)",
        default="0.0.0.0",
    )

    @classmethod
    def poll(cls, context):
        return not session.running()

    def execute(self, context):
        try:
            session.start(self.port, self.bind)
        except (OSError, ValueError, RuntimeError) as e:
            self.report({'ERROR'}, f"Sightline session not started: {e}")
            return {'CANCELLED'}
        self.report({'INFO'}, f"Sightline session listening on TCP port {session.current().port()}")
        return {'FINISHED'}


class VCAM_OT_session_stop(bpy.types.Operator):
    """Stop the Sightline session and close its network ports"""

    bl_idname = "vcam.session_stop"
    bl_label = "Stop Sightline Session"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        return session.running()

    def execute(self, context):
        session.stop()
        return {'FINISHED'}


class VCAM_OT_pairing_start(bpy.types.Operator):
    """Show a 6-digit code to type on the device (valid for 5 minutes, one pairing)"""

    bl_idname = "vcam.pairing_start"
    bl_label = "Pair Device"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        live = session.current()
        return live is not None and live.pairing_code() is None

    def execute(self, context):
        try:
            code = session.current().enable_pairing()
        except (OSError, RuntimeError) as e:
            self.report({'ERROR'}, f"Pairing not started: {e}")
            return {'CANCELLED'}
        self.report({'INFO'}, f"Pairing code {code_label(code)}")
        return {'FINISHED'}


class VCAM_OT_pairing_cancel(bpy.types.Operator):
    """Stop accepting the current pairing code"""

    bl_idname = "vcam.pairing_cancel"
    bl_label = "Cancel Pairing"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        live = session.current()
        return live is not None and live.pairing_code() is not None

    def execute(self, context):
        session.current().disable_pairing()
        return {'FINISHED'}


class VCAM_OT_origin_set(bpy.types.Operator):
    """Re-zero position and heading at the current pose (same as Set origin on the device)"""

    bl_idname = "vcam.origin_set"
    bl_label = "Set Origin"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        return session.state.session_id is not None and session.current() is not None

    def execute(self, context):
        session.set_origin()
        return {'FINISHED'}


class VCAM_OT_origin_clear(bpy.types.Operator):
    """Forget the Set-origin zero: follow the device's own start position and heading"""

    bl_idname = "vcam.origin_clear"
    bl_label = "Clear Origin"
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        origin = find_origin(target_camera(context.scene))
        return origin is not None and ZERO_YAW_KEY in origin

    def execute(self, context):
        session.clear_origin()
        return {'FINISHED'}


class VCAM_OT_latency_report_save(bpy.types.Operator, ExportHelper):
    """Save the pose-leg latency histograms and p50/p95/p99 of this device session (NFR-LAT-001)"""

    bl_idname = "vcam.latency_report_save"
    bl_label = "Save Latency Report"
    bl_options = {'REGISTER'}

    filename_ext = ".json"
    filter_glob: bpy.props.StringProperty(default="*.json", options={'HIDDEN'})

    @classmethod
    def poll(cls, context):
        return len(session.latency_log().apply_ms) > 0

    def invoke(self, context, event):
        self.filepath = time.strftime("latency-%Y-%m-%d.json")
        return super().invoke(context, event)

    def execute(self, context):
        try:
            with open(self.filepath, "w", encoding="utf-8") as f:
                json.dump(session.latency_report(), f, indent=1)
                f.write("\n")
        except OSError as e:
            self.report({'ERROR'}, f"Could not save the latency report: {e}")
            return {'CANCELLED'}
        print(f"Sightline latency: {session.latency_log().summary_line()}")
        self.report({'INFO'}, f"Saved {self.filepath}")
        return {'FINISHED'}
