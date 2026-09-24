# SPDX-License-Identifier: GPL-3.0-or-later
"""FreeD D1 protocol parser.

Parses 29-byte FreeD D1 camera tracking packets as specified in the
BBC FreeD protocol. Used across the broadcast industry for 8-axis
camera tracking data over UDP.

D1 Message Layout (29 bytes):
    Byte 0:     Message identifier (0xD1)
    Byte 1:     Camera ID (8-bit integer)
    Bytes 2:5   Pitch/Tilt (24-bit signed, degrees * 32768)
    Bytes 5:8   Yaw/Pan (24-bit signed, degrees * 32768)
    Bytes 8:11  Roll (24-bit signed, degrees * 32768)
    Bytes 11:14 Position Z (24-bit signed, mm * 64)
    Bytes 14:17 Position Y (24-bit signed, mm * 64)
    Bytes 17:20 Position X (24-bit signed, mm * 64)
    Bytes 20:23 Lens Zoom (24-bit unsigned, 0-4095 after offset)
    Bytes 23:26 Lens Focus (24-bit unsigned, 0-4095 after offset)
    Bytes 26:28 Reserved / spare
    Byte 28:    Checksum
"""

from __future__ import annotations

import dataclasses
import time

FREED_D1_MARKER = 0xD1
FREED_D1_LENGTH = 29
ROTATION_DIVISOR = 32768.0
POSITION_DIVISOR = 64.0
MM_TO_METERS = 0.001
LENS_OFFSET = 524288


@dataclasses.dataclass
class FreeDFrame:
    """Decoded FreeD D1 camera tracking frame."""
    camera_id: int
    pitch: float      # degrees
    yaw: float        # degrees
    roll: float       # degrees
    pos_x: float      # meters
    pos_y: float      # meters
    pos_z: float      # meters
    zoom: int          # raw encoder value 0-4095
    focus: int         # raw encoder value 0-4095
    timestamp: float   # time.monotonic() at receive


def _decode_24bit_signed(data: bytes, offset: int) -> int:
    """Decode 3 bytes big-endian as a signed 24-bit integer."""
    val = (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2]
    if val & 0x800000:
        val -= 0x1000000
    return val


def _decode_24bit_unsigned(data: bytes, offset: int) -> int:
    """Decode 3 bytes big-endian as an unsigned 24-bit integer."""
    return (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2]


def _validate_checksum(data: bytes) -> bool:
    """Validate FreeD D1 checksum (byte 28).

    Checksum = (0x40 - sum(bytes[0:28])) & 0xFF
    """
    expected = (0x40 - sum(data[:28])) & 0xFF
    return expected == data[28]


def parse_d1(data: bytes, timestamp: float | None = None) -> FreeDFrame | None:
    """Parse a 29-byte FreeD D1 message.

    Args:
        data: Raw 29-byte UDP payload.
        timestamp: Optional monotonic timestamp. Defaults to time.monotonic().

    Returns:
        FreeDFrame if valid, None if the packet is malformed or fails checksum.
    """
    if len(data) < FREED_D1_LENGTH:
        return None
    if data[0] != FREED_D1_MARKER:
        return None
    if not _validate_checksum(data):
        return None

    if timestamp is None:
        timestamp = time.monotonic()

    camera_id = data[1]

    pitch_raw = _decode_24bit_signed(data, 2)
    yaw_raw = _decode_24bit_signed(data, 5)
    roll_raw = _decode_24bit_signed(data, 8)

    pos_z_raw = _decode_24bit_signed(data, 11)
    pos_y_raw = _decode_24bit_signed(data, 14)
    pos_x_raw = _decode_24bit_signed(data, 17)

    zoom_raw = _decode_24bit_unsigned(data, 20)
    focus_raw = _decode_24bit_unsigned(data, 23)

    return FreeDFrame(
        camera_id=camera_id,
        pitch=pitch_raw / ROTATION_DIVISOR,
        yaw=yaw_raw / ROTATION_DIVISOR,
        roll=roll_raw / ROTATION_DIVISOR,
        pos_x=(pos_x_raw / POSITION_DIVISOR) * MM_TO_METERS,
        pos_y=(pos_y_raw / POSITION_DIVISOR) * MM_TO_METERS,
        pos_z=(pos_z_raw / POSITION_DIVISOR) * MM_TO_METERS,
        zoom=max(0, zoom_raw - LENS_OFFSET),
        focus=max(0, focus_raw - LENS_OFFSET),
        timestamp=timestamp,
    )


def encode_d1(frame: FreeDFrame) -> bytes:
    """Encode a FreeDFrame into a 29-byte FreeD D1 packet.

    Useful for testing and for the test sender script.
    """
    buf = bytearray(FREED_D1_LENGTH)
    buf[0] = FREED_D1_MARKER
    buf[1] = frame.camera_id & 0xFF

    def _encode_24bit_signed(val: int, offset: int) -> None:
        if val < 0:
            val += 0x1000000
        buf[offset] = (val >> 16) & 0xFF
        buf[offset + 1] = (val >> 8) & 0xFF
        buf[offset + 2] = val & 0xFF

    def _encode_24bit_unsigned(val: int, offset: int) -> None:
        buf[offset] = (val >> 16) & 0xFF
        buf[offset + 1] = (val >> 8) & 0xFF
        buf[offset + 2] = val & 0xFF

    _encode_24bit_signed(int(frame.pitch * ROTATION_DIVISOR), 2)
    _encode_24bit_signed(int(frame.yaw * ROTATION_DIVISOR), 5)
    _encode_24bit_signed(int(frame.roll * ROTATION_DIVISOR), 8)

    _encode_24bit_signed(int(frame.pos_z / MM_TO_METERS * POSITION_DIVISOR), 11)
    _encode_24bit_signed(int(frame.pos_y / MM_TO_METERS * POSITION_DIVISOR), 14)
    _encode_24bit_signed(int(frame.pos_x / MM_TO_METERS * POSITION_DIVISOR), 17)

    _encode_24bit_unsigned(frame.zoom + LENS_OFFSET, 20)
    _encode_24bit_unsigned(frame.focus + LENS_OFFSET, 23)

    # Checksum
    buf[28] = (0x40 - sum(buf[:28])) & 0xFF

    return bytes(buf)
