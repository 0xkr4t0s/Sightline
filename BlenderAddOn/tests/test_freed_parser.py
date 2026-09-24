#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for the FreeD D1 parser."""

import sys
from pathlib import Path

# Allow running tests standalone outside Blender
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.freed_parser import (
    FreeDFrame,
    encode_d1,
    parse_d1,
    FREED_D1_LENGTH,
    FREED_D1_MARKER,
)


def test_roundtrip_zero_frame():
    """A zeroed-out frame should encode and decode cleanly."""
    frame = FreeDFrame(
        camera_id=0, pitch=0.0, yaw=0.0, roll=0.0,
        pos_x=0.0, pos_y=0.0, pos_z=0.0,
        zoom=0, focus=0, timestamp=0.0,
    )
    packet = encode_d1(frame)
    assert len(packet) == FREED_D1_LENGTH
    assert packet[0] == FREED_D1_MARKER

    decoded = parse_d1(packet, timestamp=0.0)
    assert decoded is not None
    assert decoded.camera_id == 0
    assert abs(decoded.pitch) < 0.01
    assert abs(decoded.pos_x) < 0.001


def test_roundtrip_positive_values():
    """Positive rotation and position values should survive encode/decode."""
    frame = FreeDFrame(
        camera_id=1, pitch=15.5, yaw=30.0, roll=5.25,
        pos_x=1.5, pos_y=0.75, pos_z=2.0,
        zoom=2048, focus=1024, timestamp=0.0,
    )
    packet = encode_d1(frame)
    decoded = parse_d1(packet, timestamp=0.0)
    assert decoded is not None
    assert decoded.camera_id == 1
    assert abs(decoded.pitch - 15.5) < 0.01
    assert abs(decoded.yaw - 30.0) < 0.01
    assert abs(decoded.roll - 5.25) < 0.01
    assert abs(decoded.pos_x - 1.5) < 0.001
    assert abs(decoded.pos_y - 0.75) < 0.001
    assert abs(decoded.pos_z - 2.0) < 0.001
    assert decoded.zoom == 2048
    assert decoded.focus == 1024


def test_roundtrip_negative_values():
    """Negative rotation and position values should survive encode/decode."""
    frame = FreeDFrame(
        camera_id=5, pitch=-45.0, yaw=-180.0, roll=-90.0,
        pos_x=-10.0, pos_y=-20.0, pos_z=-5.0,
        zoom=0, focus=0, timestamp=0.0,
    )
    packet = encode_d1(frame)
    decoded = parse_d1(packet, timestamp=0.0)
    assert decoded is not None
    assert abs(decoded.pitch - (-45.0)) < 0.01
    assert abs(decoded.yaw - (-180.0)) < 0.01
    assert abs(decoded.pos_x - (-10.0)) < 0.01


def test_rejects_empty():
    assert parse_d1(b"") is None


def test_rejects_truncated():
    assert parse_d1(b"\xD1" + b"\x00" * 10) is None


def test_rejects_wrong_marker():
    packet = b"\xD2" + b"\x00" * 28
    assert parse_d1(packet) is None


def test_rejects_bad_checksum():
    frame = FreeDFrame(
        camera_id=1, pitch=10.0, yaw=-5.0, roll=0.0,
        pos_x=0.0, pos_y=0.0, pos_z=0.0,
        zoom=0, focus=0, timestamp=0.0,
    )
    packet = bytearray(encode_d1(frame))
    packet[28] = (packet[28] + 1) & 0xFF  # Corrupt checksum
    assert parse_d1(bytes(packet)) is None


if __name__ == "__main__":
    test_roundtrip_zero_frame()
    test_roundtrip_positive_values()
    test_roundtrip_negative_values()
    test_rejects_empty()
    test_rejects_truncated()
    test_rejects_wrong_marker()
    test_rejects_bad_checksum()
    print("All FreeD parser tests passed!")
