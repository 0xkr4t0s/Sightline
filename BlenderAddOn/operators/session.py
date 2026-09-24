# SPDX-License-Identifier: GPL-3.0-or-later
"""Start/stop the VCam host session (task 1.2.5b). The N-panel toggle comes in 1.3.3."""

from __future__ import annotations

import bpy

from ..core import session


class VCAM_OT_session_start(bpy.types.Operator):
    """Start listening for the VCam iPhone app and advertise this Blender session"""

    bl_idname = "vcam.session_start"
    bl_label = "Start VCam Session"
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
            self.report({'ERROR'}, f"VCam session not started: {e}")
            return {'CANCELLED'}
        self.report({'INFO'}, f"VCam session listening on TCP port {session.current().port()}")
        return {'FINISHED'}


class VCAM_OT_session_stop(bpy.types.Operator):
    """Stop the VCam session and close its network ports"""

    bl_idname = "vcam.session_stop"
    bl_label = "Stop VCam Session"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        return session.running()

    def execute(self, context):
        session.stop()
        return {'FINISHED'}
