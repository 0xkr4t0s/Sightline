# SPDX-License-Identifier: GPL-3.0-or-later
"""Non-blocking UDP tracking data receiver.

Runs a daemon thread that continuously receives UDP packets and stores
only the most recent one. The main thread (Blender's modal operator)
reads the latest packet without blocking.

IMPORTANT: The background thread NEVER touches any bpy.* API.
All Blender API interaction must happen on the main thread.
"""

from __future__ import annotations

import json
import socket
import threading
import time

from .freed_parser import FreeDFrame, parse_d1

# Relay message format from the C++ Desktop Receiver (JSON-over-UDP)
RELAY_TYPE_FREED = "freed"


class UDPTrackingClient:
    """Receives FreeD or relay tracking data over UDP.

    Supports two input formats:
    1. Raw FreeD D1 packets (29 bytes) — direct from tracking hardware
    2. JSON relay packets — from the C++ Desktop Receiver (GPL firewall)
    """

    def __init__(self, host: str = "0.0.0.0", port: int = 6000) -> None:
        self._host = host
        self._port = port
        self._sock: socket.socket | None = None
        self._latest_frame: FreeDFrame | None = None
        self._lock = threading.Lock()
        self._running = False
        self._thread: threading.Thread | None = None
        self._packets_received: int = 0
        self._packets_dropped: int = 0

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def packets_received(self) -> int:
        return self._packets_received

    @property
    def packets_dropped(self) -> int:
        return self._packets_dropped

    def start(self) -> None:
        """Bind the socket and start the receiver thread."""
        if self._running:
            return

        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.setblocking(False)
        self._sock.bind((self._host, self._port))

        self._running = True
        self._packets_received = 0
        self._packets_dropped = 0
        self._thread = threading.Thread(
            target=self._recv_loop,
            daemon=True,
            name="vcam-udp-receiver",
        )
        self._thread.start()

    def _recv_loop(self) -> None:
        """Background thread: drain socket, keep only newest packet."""
        while self._running:
            try:
                data, _ = self._sock.recvfrom(4096)
            except BlockingIOError:
                # No data available — brief sleep to avoid busy-spinning
                time.sleep(0.0005)  # 500us
                continue
            except OSError:
                break

            frame = self._parse_packet(data)
            if frame is not None:
                with self._lock:
                    if self._latest_frame is not None:
                        self._packets_dropped += 1
                    self._latest_frame = frame
                    self._packets_received += 1

    def _parse_packet(self, data: bytes) -> FreeDFrame | None:
        """Parse either raw FreeD D1 or JSON relay format."""
        # Try raw FreeD D1 first (starts with 0xD1, exactly 29 bytes)
        if len(data) == 29 and data[0] == 0xD1:
            return parse_d1(data)

        # Try JSON relay format from Desktop Receiver
        try:
            msg = json.loads(data)
            if msg.get("type") == RELAY_TYPE_FREED:
                return FreeDFrame(
                    camera_id=msg.get("cam", 1),
                    pitch=msg.get("pitch", 0.0),
                    yaw=msg.get("yaw", 0.0),
                    roll=msg.get("roll", 0.0),
                    pos_x=msg.get("px", 0.0),
                    pos_y=msg.get("py", 0.0),
                    pos_z=msg.get("pz", 0.0),
                    zoom=msg.get("zoom", 0),
                    focus=msg.get("focus", 0),
                    timestamp=msg.get("t", time.monotonic()),
                )
        except (json.JSONDecodeError, UnicodeDecodeError, KeyError):
            pass

        return None

    def get_latest(self) -> FreeDFrame | None:
        """Get the most recent tracking frame (called from main thread).

        Returns:
            The latest FreeDFrame, or None if no new data is available.
            Consuming the frame clears the slot.
        """
        with self._lock:
            frame = self._latest_frame
            self._latest_frame = None
            return frame

    def stop(self) -> None:
        """Stop the receiver thread and close the socket."""
        self._running = False
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
