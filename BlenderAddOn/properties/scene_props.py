# SPDX-License-Identifier: GPL-3.0-or-later
"""Scene-level VCam settings. Live session state lives in `core/session.py`, not in the file."""

from __future__ import annotations

import bpy

from ..core import session
from ..core.render import DEFAULT_BUDGET_MS
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
