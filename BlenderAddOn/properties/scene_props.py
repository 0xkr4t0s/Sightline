# SPDX-License-Identifier: GPL-3.0-or-later
"""Scene-level properties for VCam tracking state."""

from __future__ import annotations

import bpy


class VCamProperties(bpy.types.PropertyGroup):
    """Persistent properties for VCam tracking configuration."""

    # Connection settings
    host: bpy.props.StringProperty(
        name="Host",
        description="UDP bind address (0.0.0.0 for all interfaces)",
        default="0.0.0.0",
    )
    port: bpy.props.IntProperty(
        name="Port",
        description="UDP port to listen on",
        default=6000,
        min=1024,
        max=65535,
    )

    # Tracking state
    is_tracking: bpy.props.BoolProperty(
        name="Tracking Active",
        default=False,
    )
    target_camera: bpy.props.PointerProperty(
        name="Target Camera",
        description="Camera object to drive (defaults to scene camera)",
        type=bpy.types.Object,
        poll=lambda self, obj: obj.type == 'CAMERA',
    )

    # Coordinate transform settings
    euler_order: bpy.props.EnumProperty(
        name="Euler Order",
        description="Rotation order for FreeD angle interpretation",
        items=[
            ('XYZ', 'XYZ', ''),
            ('XZY', 'XZY', ''),
            ('YXZ', 'YXZ', 'Default for most broadcast tracking systems'),
            ('YZX', 'YZX', ''),
            ('ZXY', 'ZXY', ''),
            ('ZYX', 'ZYX', ''),
        ],
        default='YXZ',
    )

    # Lens mapping
    zoom_min_focal: bpy.props.FloatProperty(
        name="Min Focal Length",
        description="Focal length (mm) at zoom encoder 0",
        default=12.0,
        min=1.0,
        max=2000.0,
        unit='CAMERA',
    )
    zoom_max_focal: bpy.props.FloatProperty(
        name="Max Focal Length",
        description="Focal length (mm) at zoom encoder 4095",
        default=300.0,
        min=1.0,
        max=2000.0,
        unit='CAMERA',
    )
    focus_min_distance: bpy.props.FloatProperty(
        name="Min Focus Distance",
        description="Focus distance (m) at focus encoder 0",
        default=0.3,
        min=0.01,
        max=1000.0,
        unit='LENGTH',
    )
    focus_max_distance: bpy.props.FloatProperty(
        name="Max Focus Distance",
        description="Focus distance (m) at focus encoder 4095",
        default=100.0,
        min=0.01,
        max=1000.0,
        unit='LENGTH',
    )

    # Debug / status readback (updated by modal operator)
    last_pos_x: bpy.props.FloatProperty(name="X", precision=4)
    last_pos_y: bpy.props.FloatProperty(name="Y", precision=4)
    last_pos_z: bpy.props.FloatProperty(name="Z", precision=4)
    last_pitch: bpy.props.FloatProperty(name="Pitch", precision=2)
    last_yaw: bpy.props.FloatProperty(name="Yaw", precision=2)
    last_roll: bpy.props.FloatProperty(name="Roll", precision=2)
    packets_received: bpy.props.IntProperty(name="Packets Received")
    packets_dropped: bpy.props.IntProperty(name="Packets Dropped")
