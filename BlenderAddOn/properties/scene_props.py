# SPDX-License-Identifier: GPL-3.0-or-later
"""Scene-level VCam settings. Live session state lives in `core/session.py`, not in the file."""

from __future__ import annotations

import bpy

from ..core.session import DEFAULT_PORT


class VCamProperties(bpy.types.PropertyGroup):
    """Persistent VCam settings saved with the .blend."""

    bind_address: bpy.props.StringProperty(
        name="Bind Address",
        description="Local address to listen on (0.0.0.0 for all interfaces)",
        default="0.0.0.0",
    )
    port: bpy.props.IntProperty(
        name="Port",
        description="TCP control port the iPhone connects to (shown to it over Bonjour)",
        default=DEFAULT_PORT,
        min=1024,
        max=65535,
    )
    target_camera: bpy.props.PointerProperty(
        name="Target Camera",
        description="Camera object to drive (defaults to the scene camera)",
        type=bpy.types.Object,
        poll=lambda self, obj: obj.type == 'CAMERA',
    )
