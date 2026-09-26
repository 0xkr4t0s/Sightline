# SPDX-License-Identifier: GPL-3.0-or-later
"""Host session lifecycle (tasks 1.2.5b, 1.3.1; C-2, NFR-REL-002, NFR-SEC-003, FR-BL-002).

At most one `vcam_native.Session` per Blender process. It starts only on request (NFR-SEC-003:
listen only while a session is active), never when the add-on is enabled, and the add-on's
`unregister()` always stops it (NFR-REL-002). Networking runs on native threads. This module
touches `bpy` only on the main thread, from operators and a `bpy.app.timers` poll, which also
applies the newest pose to the target camera (`core/apply.py`).

File reload, undo and redo (FR-BL-007, NET-004): the session and its timer are persistent, so
they survive `load_post`; nothing here holds `bpy` data across ticks (reload and undo free it),
and after either the current pose is re-applied to whatever camera the restored file names.

`bpy` and `vcam_native` are imported lazily so the pure helpers can be tested outside Blender.
"""

from __future__ import annotations

import os
import platform
import socket
import sys
import time
from dataclasses import dataclass

from .apply import Applier, clear_zero, find_origin, target_camera
from .latency import LatencyLog
from .render import DEFAULT_BUDGET_MS, StreamLoop
from .status import pose_latency_ms

HOST_ID_FILE = "host_id"
HOST_ID_LEN = 16
DEFAULT_PORT = 47000
# The poll also applies poses, so it runs at the tracking rate.
POLL_INTERVAL = 1.0 / 60.0
# Events drained per poll; the rest wait for the next tick so one poll stays short.
MAX_EVENTS_PER_POLL = 64
# The N-panel only redraws on user events; the poll refreshes it at this interval (seconds).
REDRAW_INTERVAL = 0.25


@dataclass
class SessionState:
    """Main-thread view of the session, updated by `_poll` and read by the N-panel."""

    device_id: str | None = None
    device_name: str | None = None
    session_id: int | None = None
    last_error: str | None = None
    # From the last applied pose (vcp.md §6.1) and the clock estimate (NET-003).
    latency_ms: float | None = None
    clock_jitter_ms: float | None = None
    stream_error: str | None = None


_package: str | None = None
_session = None
state = SessionState()
_applier = Applier()
_latency = LatencyLog()
# The CLOCK estimate behind the newest pose-leg sample, for the report.
_latency_clock: dict | None = None
_last_redraw = float("-inf")
_stream: StreamLoop | None = None
_stream_enabled = False
_stream_failed = False


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
        raise RuntimeError("Sightline add-on is not registered")
    path = bpy.utils.extension_path_user(_package, create=True)
    if not path:
        raise OSError("could not create the Sightline user directory")
    return path


def running() -> bool:
    return _session is not None and _session.running()


def current():
    """The running `vcam_native.Session`, or None."""
    return _session if running() else None


def _close_stream() -> None:
    global _stream
    stream, _stream = _stream, None
    if stream is not None:
        try:
            stream.free()
        except Exception as e:  # noqa: BLE001 - cleanup must not prevent session shutdown
            state.stream_error = f"Stream cleanup: {e}"


def start(port: int = DEFAULT_PORT, bind: str = "0.0.0.0", *, stream: bool | None = None) -> None:
    """Start the host. Background Blender needs stream=True after gpu.init()."""
    global _session, _applier, _latency, _latency_clock, _stream_enabled, _stream_failed
    import bpy
    import vcam_native

    if running():
        raise RuntimeError("session already running")
    directory = config_dir()
    session = vcam_native.Session.start(port, directory, load_or_create_host_id(directory), bind=bind)
    vars(state).update(vars(SessionState()))  # reset in place: importers keep the object
    _applier = Applier()
    _latency, _latency_clock = LatencyLog(), None
    _stream_enabled = not bpy.app.background if stream is None else stream
    _stream_failed = False
    try:
        session.advertise(socket.gethostname(), bpy.path.basename(bpy.data.filepath))
    except (OSError, ValueError) as e:
        # Discovery is a convenience; manual host entry still works (FR-UX-001).
        state.last_error = f"DNS-SD: {e}"
    smoothing = getattr(getattr(bpy.context.scene, "vcam_props", None), "smoothing", False)
    session.set_smoothing(bool(smoothing))
    _session = session
    if not bpy.app.timers.is_registered(_poll):
        bpy.app.timers.register(_poll, first_interval=POLL_INTERVAL, persistent=True)


def stop() -> None:
    """Stops the session and its poll. Never raises; a DNS-SD withdrawal error is recorded."""
    global _session, _stream_enabled
    import bpy

    if bpy.app.timers.is_registered(_poll):
        bpy.app.timers.unregister(_poll)
    _close_stream()
    _stream_enabled = False
    session, _session = _session, None
    if session is None:
        return
    try:
        session.stop()  # sockets are closed and threads joined even if this raises
    except Exception as e:  # noqa: BLE001 - unregister must always complete
        state.last_error = f"stop: {e}"
        print(f"Sightline: {state.last_error}")


def applier() -> Applier:
    """The current session's apply state (controls, applied seq), for the N-panel."""
    return _applier


def latency_log() -> LatencyLog:
    """Pose-leg and apply-cost samples of the current device session (task 1.5.1)."""
    return _latency


def latency_report() -> dict:
    """The NFR-LAT-001 report of the current device session as a JSON-ready dict."""
    import bpy

    return _latency.report(
        date=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        platform=f"{sys.platform}-{platform.machine()}",
        blender=bpy.app.version_string,
        device_name=state.device_name,
        poll_interval_s=POLL_INTERVAL,
        clock=_latency_clock,
    )


def set_origin() -> None:
    """Set origin from Blender: re-zero the rig at the next applied pose (FR-TRK-003)."""
    _applier.request_set_origin()


def clear_origin() -> None:
    """Drop the stored zero, so the rig follows the device's own world origin again."""
    import bpy

    origin = find_origin(target_camera(bpy.context.scene))
    if origin is not None:
        clear_zero(origin)
    _applier.reapply()


def set_smoothing(enabled: bool) -> None:
    """FR-BL-006 toggle; applies to the running session (and to later ones via the scene)."""
    if running():
        _session.set_smoothing(enabled)


def _tag_redraw(now: float) -> None:
    global _last_redraw
    import bpy

    if now - _last_redraw < REDRAW_INTERVAL:
        return
    _last_redraw = now
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()


def _render_frame(session, context) -> None:
    """After applying the live pose, draw only when a frame is due; never block for a skipped one."""
    global _stream, _stream_failed
    if not _stream_enabled or _stream_failed or state.session_id is None:
        _close_stream()
        return
    scene = context.scene
    camera = target_camera(scene)
    if camera is None or _applier.applied_seq == 0:
        _close_stream()
        return
    props = getattr(scene, "vcam_props", None)
    budget_ms = getattr(props, "render_budget_ms", DEFAULT_BUDGET_MS)
    try:
        if _stream is None:
            import vcam_native

            _stream = StreamLoop(vcam_native.FrameSlot())
        _stream.tick(context, camera, _applier.applied_seq, session.host_clock_ns, budget_ms)
    except Exception as e:  # noqa: BLE001 - a broken GPU must not interrupt pose tracking
        state.stream_error = f"Stream: {e}"
        _stream_failed = True
        _close_stream()


def _poll() -> float | None:
    """Timer callback on the main thread: drains events, applies the pose. Never raises."""
    global _latency_clock, _stream_failed
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
                _close_stream()  # do not carry a frame or GPU resource across device sessions
                _stream_failed = False
                state.stream_error = None
                state.device_id = event["device_id"]
                state.device_name = event["device_name"]
                state.session_id = event["session_id"]
            elif kind == "session_ended" and event["session_id"] == state.session_id:
                state.session_id = None
                _close_stream()
            elif kind == "pairing_storage_failed":
                state.last_error = f"pairing not saved: {event['error']}"
        error = session.discovery_error()
        if error:
            state.last_error = f"DNS-SD: {error}"
        now = time.monotonic()
        started = time.perf_counter()
        applied = _applier.tick(session, state.session_id, bpy.context.scene, now)
        if applied is not None:
            # Host clock at the apply, read before anything else so the pose leg ends here.
            applied_at_ns = session.host_clock_ns()
            apply_ms = (time.perf_counter() - started) * 1e3
            state.tracking_state = applied["tracking_state"]
            clock = session.stats()["clock"]
            pose_leg = None
            if clock is not None:
                pose_leg = pose_latency_ms(applied["capture_time_ns"], clock["offset_ns"], applied_at_ns)
                state.latency_ms = pose_leg
                state.clock_jitter_ms = clock["jitter_ns"] / 1e6
                _latency_clock = dict(clock)
            if state.session_id is not None:  # a re-apply after the device left isn't a sample
                _latency.record(state.session_id, applied["seq"], apply_ms, pose_leg)
        _render_frame(session, bpy.context)
        _tag_redraw(now)
    except Exception as e:  # noqa: BLE001 - an exception would silently unregister the timer
        state.last_error = str(e)
    return POLL_INTERVAL


def _on_load_post(*_args) -> None:
    """A new file keeps the running session: take its smoothing and name, re-apply the pose."""
    import bpy

    _close_stream()
    _applier.reapply()
    if not running():
        return
    props = getattr(bpy.context.scene, "vcam_props", None)
    try:
        set_smoothing(bool(props.smoothing) if props is not None else False)
    except Exception as e:  # noqa: BLE001 - a handler must not break file loading
        state.last_error = f"smoothing: {e}"
    try:
        _session.advertise(socket.gethostname(), bpy.path.basename(bpy.data.filepath))
    except Exception as e:  # noqa: BLE001 - discovery is a convenience (FR-UX-001)
        state.last_error = f"DNS-SD: {e}"


def _on_undo_redo(*_args) -> None:
    """Undo restored an older camera transform and zero; show the live pose under that zero."""
    _close_stream()
    _applier.reapply()


_HANDLERS = (("load_post", _on_load_post), ("undo_post", _on_undo_redo), ("redo_post", _on_undo_redo))


def register(package: str) -> None:
    global _package
    import bpy

    _package = package
    for name, handler in _HANDLERS:
        bpy.app.handlers.persistent(handler)  # keep it across file loads
        handlers = getattr(bpy.app.handlers, name)
        if handler not in handlers:
            handlers.append(handler)


def unregister() -> None:
    global _package
    import bpy

    stop()
    for name, handler in _HANDLERS:
        handlers = getattr(bpy.app.handlers, name)
        if handler in handlers:
            handlers.remove(handler)
    _package = None
