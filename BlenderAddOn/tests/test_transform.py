#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for coordinate transform.

NOTE: These tests require mathutils (Blender Python module).
Run inside Blender's Python or with a standalone mathutils install.
When run outside Blender, tests that import mathutils will be skipped.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.freed_parser import FreeDFrame
from core.transform import zoom_to_focal_length, focus_to_distance

# mathutils-dependent tests are guarded
try:
    import mathutils
    from core.transform import freed_to_blender_matrix
    HAS_MATHUTILS = True
except ImportError:
    HAS_MATHUTILS = False


def test_zoom_to_focal_length_bounds():
    assert abs(zoom_to_focal_length(0) - 12.0) < 0.01
    assert abs(zoom_to_focal_length(4095) - 300.0) < 0.1
    assert abs(zoom_to_focal_length(2048) - 156.0) < 1.0


def test_focus_to_distance_bounds():
    assert abs(focus_to_distance(0) - 0.3) < 0.01
    assert abs(focus_to_distance(4095) - 100.0) < 0.1


def test_zoom_clamping():
    # Values outside 0-4095 should be clamped
    assert zoom_to_focal_length(-100) == 12.0
    assert abs(zoom_to_focal_length(5000) - 300.0) < 0.01


def test_transform_identity():
    """Identity FreeD frame should produce a known Blender matrix."""
    if not HAS_MATHUTILS:
        print("  SKIPPED (no mathutils)")
        return

    frame = FreeDFrame(
        camera_id=1, pitch=0.0, yaw=0.0, roll=0.0,
        pos_x=0.0, pos_y=0.0, pos_z=0.0,
        zoom=0, focus=0, timestamp=0.0,
    )
    mat = freed_to_blender_matrix(frame)
    # Origin position
    assert abs(mat[0][3]) < 0.001
    assert abs(mat[1][3]) < 0.001
    assert abs(mat[2][3]) < 0.001


def test_transform_translation():
    """Pure translation should map correctly."""
    if not HAS_MATHUTILS:
        print("  SKIPPED (no mathutils)")
        return

    frame = FreeDFrame(
        camera_id=1, pitch=0.0, yaw=0.0, roll=0.0,
        pos_x=1.0, pos_y=2.0, pos_z=3.0,
        zoom=0, focus=0, timestamp=0.0,
    )
    mat = freed_to_blender_matrix(frame)
    # FreeD X→Blender X, FreeD Y→Blender Z, FreeD Z→Blender -Y
    assert abs(mat[0][3] - 1.0) < 0.001  # X
    assert abs(mat[1][3] - (-3.0)) < 0.001  # -Z
    assert abs(mat[2][3] - 2.0) < 0.001  # Y


if __name__ == "__main__":
    test_zoom_to_focal_length_bounds()
    test_focus_to_distance_bounds()
    test_zoom_clamping()
    test_transform_identity()
    test_transform_translation()
    print("All transform tests passed!")
