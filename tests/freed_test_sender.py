#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Standalone FreeD D1 test sender.

Sends synthetic FreeD D1 packets over UDP with a smooth circular camera
motion. Used to validate the Blender add-on and Desktop Receiver without
any tracking hardware.

Usage:
    python3 freed_test_sender.py [--host HOST] [--port PORT] [--fps FPS]
"""

from __future__ import annotations

import argparse
import math
import socket
import sys
import time

# Add the BlenderAddOn to path for encoder access
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent.parent / 'BlenderAddOn'))

from core.freed_parser import FreeDFrame, encode_d1


def generate_circular_motion(t: float, radius: float = 3.0, height: float = 1.5) -> FreeDFrame:
    """Generate a smooth circular camera orbit.

    Args:
        t: Time in seconds.
        radius: Orbit radius in meters.
        height: Camera height in meters.

    Returns:
        FreeDFrame with position on a circle and camera looking at origin.
    """
    angle = t * 0.5  # 0.5 rad/s = ~12 second full orbit

    pos_x = radius * math.cos(angle)
    pos_y = radius * math.sin(angle)
    pos_z = height

    # Camera looks toward origin
    yaw = -math.degrees(angle) + 90.0  # Face center
    pitch = -math.degrees(math.atan2(height, radius))  # Tilt down
    roll = 0.0

    # Gentle zoom oscillation
    zoom = int(2048 + 1000 * math.sin(t * 0.3))
    focus = int(2048 + 500 * math.cos(t * 0.2))

    return FreeDFrame(
        camera_id=1,
        pitch=pitch,
        yaw=yaw,
        roll=roll,
        pos_x=pos_x,
        pos_y=pos_y,
        pos_z=pos_z,
        zoom=max(0, min(4095, zoom)),
        focus=max(0, min(4095, focus)),
        timestamp=time.monotonic(),
    )


def main():
    parser = argparse.ArgumentParser(description="FreeD D1 test sender")
    parser.add_argument("--host", default="127.0.0.1", help="Destination host")
    parser.add_argument("--port", type=int, default=6000, help="Destination UDP port")
    parser.add_argument("--fps", type=int, default=60, help="Packets per second")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dest = (args.host, args.port)
    interval = 1.0 / args.fps
    start_time = time.monotonic()

    print(f"Sending FreeD D1 packets to {args.host}:{args.port} at {args.fps}fps")
    print("Press Ctrl+C to stop\n")

    packet_count = 0
    try:
        while True:
            t = time.monotonic() - start_time
            frame = generate_circular_motion(t)
            packet = encode_d1(frame)
            sock.sendto(packet, dest)
            packet_count += 1

            if packet_count % args.fps == 0:
                print(f"\r  Sent {packet_count} packets | "
                      f"Pos: ({frame.pos_x:.2f}, {frame.pos_y:.2f}, {frame.pos_z:.2f}) | "
                      f"Rot: (P:{frame.pitch:.1f} Y:{frame.yaw:.1f} R:{frame.roll:.1f})",
                      end="", flush=True)

            # Precise timing
            next_time = start_time + packet_count * interval
            sleep_time = next_time - time.monotonic()
            if sleep_time > 0:
                time.sleep(sleep_time)

    except KeyboardInterrupt:
        print(f"\n\nStopped after {packet_count} packets.")
    finally:
        sock.close()


if __name__ == "__main__":
    main()
