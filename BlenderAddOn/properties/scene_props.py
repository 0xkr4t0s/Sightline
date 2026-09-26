# SPDX-License-Identifier: GPL-3.0-or-later
"""Scene-level VCam settings. Live session state lives in `core/session.py`, not in the file."""

from __future__ import annotations

import bpy

from ..core import session
from ..core.render import DEFAULT_BUDGET_MS, STREAM_FPS_CAPS, STREAM_RESOLUTIONS
from ..core.session import DEFAULT_PORT


def _smoothing_changed(self, _context):
    session.set_smoothing(self.smoothing)


def _hold_changed(_self, _context):
    session.applier().reapply()  # show the degraded or the held pose at once


class VCamProperties(bpy.types.PropertyGroup):
    """Persistent VCam settings saved with the .blend."""

    bind_address: bpy.props.StringProperty(
        name="Bind Address",
        description="Local address to listen on (0.0.0.0 for all interfaces)",
        default="0.0.0.0",
    )
    port: bpy.props.IntProperty(
        name="Port",
        description="TCP control port the device connects to (shown to it over Bonjour)",
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
    smoothing: bpy.props.BoolProperty(
        name="Smoothing",
        description="Smooth the incoming pose (One-Euro filter). Raw poses are always kept",
        default=False,
        update=_smoothing_changed,
    )
    hold_last_good: bpy.props.BoolProperty(
        name="Hold Last Good Pose",
        description="While device tracking is limited, keep the camera at the last normal pose",
        default=True,
        update=_hold_changed,
    )
    render_budget_ms: bpy.props.IntProperty(
        name="Stream Budget (ms)",
        description="Main-thread draw/read target; expensive frames reduce the stream frame rate",
        default=DEFAULT_BUDGET_MS,
        min=1,
        max=50,
    )
    stream_resolution: bpy.props.EnumProperty(
        name="Stream Resolution",
        description="Offscreen viewfinder resolution",
        items=[(key, f"{w} × {h}", f"Stream at {w} × {h}")
               for key, (w, h) in STREAM_RESOLUTIONS.items()],
        default='540p',
    )
    stream_fps: bpy.props.EnumProperty(
        name="Stream FPS",
        description="Maximum number of viewfinder frames per second",
        items=[(str(fps), f"{fps} fps", f"Cap the stream at {fps} fps") for fps in STREAM_FPS_CAPS],
        default='30',
    )
    stream_shading: bpy.props.EnumProperty(
        name="Stream Shading",
        description="Shading mode for the viewfinder; EEVEE may slow Blender",
        items=[('SOLID', "Solid", "Fast viewport shading"),
               ('MATERIAL', "Material Preview", "Preview materials and lighting"),
               ('RENDERED', "Rendered (EEVEE)", "Preview EEVEE; the UI may lag and stream fps may drop")],
        default='SOLID',
    )
