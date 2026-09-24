# SPDX-License-Identifier: GPL-3.0-or-later
"""Host session lifecycle (tasks 1.2.5b, 1.3.1; C-2, NFR-REL-002, NFR-SEC-003, FR-BL-002).

At most one `vcam_native.Session` per Blender process. It starts only on request (NFR-SEC-003:
listen only while a session is active), never when the add-on is enabled, and the add-on's
`unregister()` always stops it (NFR-REL-002). Networking runs on native threads. This module
touches `bpy` only on the main thread, from operators and a `bpy.app.timers` poll, which also
applies the newest pose to the target camera (`core/apply.py`).

`bpy` and `vcam_native` are imported lazily so the pure helpers can be tested outside Blender.
"""

from __future__ import annotations

import os
import socket
import time
from dataclasses import dataclass

from .apply import Applier

HOST_ID_FILE = "host_id"
HOST_ID_LEN = 16
DEFAULT_PORT = 47000
# The poll also applies poses, so it runs at the tracking rate.
POLL_INTERVAL = 1.0 / 60.0
# Events drained per poll; the rest wait for the next tick so one poll stays short.
MAX_EVENTS_PER_POLL = 64


@dataclass
class SessionState:
    """Main-thread view of the session, updated by `_poll` (read by the N-panel in 1.3.3)."""

    device_id: str | None = None
    device_name: str | None = None
    session_id: int | None = None
    last_error: str | None = None


_package: str | None = None
_session = None
state = SessionState()
_applier = Applier()


def load_or_create_host_id(directory: str) -> bytes:
    """The install's stable 16-byte host ID (vcp.md §9.3), created once with mode 0600.

    A damaged file raises ValueError instead of being replaced: a new ID would silently
    invalidate every paired device.
    """
    path = os.path.join(directory, HOST_ID_FILE)
    try:
        with open(path, "rb") as f:
            host_id = f.read()
    except FileNotFoundError:
        host_id = os.urandom(HOST_ID_LEN)
        tmp = f"{path}.tmp{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(host_id)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        return host_id
    if len(host_id) != HOST_ID_LEN:
        raise ValueError(f"{path} is damaged ({len(host_id)} bytes, expected {HOST_ID_LEN})")
    return host_id


def config_dir() -> str:
    """The extension's user directory (kept across extension updates): host ID + pairings."""
    import bpy

    if _package is None:
        raise RuntimeError("VCam add-on is not registered")
    path = bpy.utils.extension_path_user(_package, create=True)
    if not path:
        raise OSError("could not create the VCam user directory")
    return path


def running() -> bool:
    return _session is not None and _session.running()


def current():
    """The running `vcam_native.Session`, or None."""
    return _session if running() else None


def start(port: int = DEFAULT_PORT, bind: str = "0.0.0.0") -> None:
    """Starts listening and advertising. Raises OSError/ValueError on failure, nothing started."""
    global _session, _applier
    import bpy
    import vcam_native

    if running():
        raise RuntimeError("session already running")
    directory = config_dir()
    session = vcam_native.Session.start(port, directory, load_or_create_host_id(directory), bind=bind)
    vars(state).update(vars(SessionState()))  # reset in place: importers keep the object
    _applier = Applier()
    try:
        session.advertise(socket.gethostname(), bpy.path.basename(bpy.data.filepath))
    except (OSError, ValueError) as e:
        # Discovery is a convenience; manual host entry still works (FR-UX-001).
        state.last_error = f"DNS-SD: {e}"
    _session = session
    if not bpy.app.timers.is_registered(_poll):
        bpy.app.timers.register(_poll, first_interval=POLL_INTERVAL, persistent=True)


def stop() -> None:
    """Stops the session and its poll. Never raises; a DNS-SD withdrawal error is recorded."""
    global _session
    import bpy

    if bpy.app.timers.is_registered(_poll):
        bpy.app.timers.unregister(_poll)
    session, _session = _session, None
    if session is None:
        return
    try:
        session.stop()  # sockets are closed and threads joined even if this raises
    except Exception as e:  # noqa: BLE001 - unregister must always complete
        state.last_error = f"stop: {e}"
        print(f"VCam: {state.last_error}")


def _poll() -> float | None:
    """Timer callback on the main thread: drains events, applies the pose. Never raises."""
    import bpy

    session = _session
    if session is None:
        return None
    try:
        for _ in range(MAX_EVENTS_PER_POLL):
            event = session.poll_event()
            if event is None:
                break
            kind = event["type"]
            if kind == "session_started":
                state.device_id = event["device_id"]
                state.device_name = event["device_name"]
                state.session_id = event["session_id"]
            elif kind == "session_ended" and event["session_id"] == state.session_id:
                state.session_id = None
            elif kind == "pairing_storage_failed":
                state.last_error = f"pairing not saved: {event['error']}"
        error = session.discovery_error()
        if error:
            state.last_error = f"DNS-SD: {error}"
        _applier.tick(session, state.session_id, bpy.context.scene, time.monotonic())
    except Exception as e:  # noqa: BLE001 - an exception would silently unregister the timer
        state.last_error = str(e)
    return POLL_INTERVAL


def register(package: str) -> None:
    global _package
    _package = package


def unregister() -> None:
    global _package
    stop()
    _package = None
