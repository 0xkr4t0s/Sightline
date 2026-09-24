# SPDX-License-Identifier: GPL-3.0-or-later
"""Coordinate system conversion from FreeD to Blender.

FreeD uses a broadcast-standard coordinate system where axes and rotation
conventions vary by tracking system vendor. This module provides configurable
axis mapping with a sensible default for the most common convention:

    FreeD:   Y-up, right-handed (broadcast standard)
    Blender: Z-up, right-handed

The default mapping swaps Y→Z and Z→-Y for position, and adjusts rotation
signs accordingly. Users can override via the calibration UI (Phase 4).
"""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .freed_parser import FreeDFrame

try:
    import mathutils
except ImportError:
    mathutils = None  # type: ignore[assignment]


def freed_to_blender_matrix(
    frame: "FreeDFrame",
    euler_order: str = "YXZ",
) -> "mathutils.Matrix":
    """Convert a FreeDFrame to a Blender 4x4 world matrix.

    Args:
        frame: Decoded FreeD tracking data.
        euler_order: Euler rotation order. Default 'YXZ' matches most
            broadcast tracking systems.

    Returns:
        4x4 transformation matrix suitable for assignment to
        ``object.matrix_world``.
    """
    # Position: FreeD (X, Y-up, Z) → Blender (X, -Z, Y) for Z-up
    loc = mathutils.Vector((
        frame.pos_x,
        -frame.pos_z,
        frame.pos_y,
    ))

    # Rotation: convert degrees to radians, flip yaw for handedness
    rot = mathutils.Euler((
        math.radians(frame.pitch),
        math.radians(frame.roll),
        math.radians(-frame.yaw),
    ), euler_order)

    mat_rot = rot.to_matrix().to_4x4()
    mat_loc = mathutils.Matrix.Translation(loc)

    return mat_loc @ mat_rot


def zoom_to_focal_length(
    zoom_value: int,
    min_focal: float = 12.0,
    max_focal: float = 300.0,
) -> float:
    """Map FreeD zoom encoder value (0-4095) to focal length in mm.

    Default range covers typical cinema zoom lenses. Users should calibrate
    these bounds for their specific lens via the calibration UI.

    Args:
        zoom_value: Raw zoom encoder (0-4095).
        min_focal: Focal length at zoom=0 (mm).
        max_focal: Focal length at zoom=4095 (mm).

    Returns:
        Interpolated focal length in mm.
    """
    t = max(0.0, min(1.0, zoom_value / 4095.0))
    return min_focal + t * (max_focal - min_focal)


def focus_to_distance(
    focus_value: int,
    min_distance: float = 0.3,
    max_distance: float = 100.0,
) -> float:
    """Map FreeD focus encoder value (0-4095) to focus distance in meters.

    Args:
        focus_value: Raw focus encoder (0-4095).
        min_distance: Minimum focus distance (meters).
        max_distance: Maximum focus distance (meters).

    Returns:
        Interpolated focus distance in meters.
    """
    t = max(0.0, min(1.0, focus_value / 4095.0))
    return min_distance + t * (max_distance - min_distance)
