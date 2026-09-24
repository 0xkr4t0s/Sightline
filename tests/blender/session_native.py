# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check of `vcam_native.Session` (task 1.2.5a; C-2, NFR-REL-001/002).

Install the extension exactly as for `smoke_native.py`, then:

    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/session_native.py

Exercises the installed native module inside Blender's Python: start/stop on real sockets,
argument validation, pairing code, stats/pose/event shapes before a device connects, DNS-SD
advertise, panic conversion at the FFI boundary, and same-port restart after stop.
"""

import os
import socket
import tempfile
import time

import addon_utils
import bpy

MODULE = "bl_ext.user_default.vcam_blender"
addon_utils.enable(MODULE, default_set=True, handle_error=None)
assert MODULE in bpy.context.preferences.addons, f"{MODULE} not enabled"

import vcam_native  # noqa: E402

Session = vcam_native.Session


def raises(exc, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except exc as e:
        return e
    raise AssertionError(f"{fn} did not raise {exc.__name__}")


with tempfile.TemporaryDirectory() as config_dir:
    host_id = os.urandom(16)
    s = Session.start(0, config_dir, host_id, bind="127.0.0.1")
    assert s.running()
    port, udp_port = s.port(), s.udp_port()
    assert port > 0 and udp_port > 0, (port, udp_port)
    # The TCP listener is real.
    socket.create_connection(("127.0.0.1", port), timeout=1).close()
    assert os.path.isdir(os.path.join(config_dir, "vcam-pairings"))

    # Argument validation raises ordinary Python exceptions.
    raises(ValueError, Session.start, 0, config_dir, b"short", bind="127.0.0.1")
    raises(ValueError, Session.start, 0, config_dir, host_id, bind="not-an-ip")
    raises(OSError, Session.start, port, config_dir, host_id, bind="127.0.0.1")  # port in use

    # Before any device: empty samples and a stats dict with the documented keys.
    stats = s.stats()
    expected = {"session_id", "last_datagram_age_s", "poses_applied", "poses_stale", "dropped",
                "rate_hz", "loss", "last_pose_age_s", "source", "clock", "clock_rejected"}
    assert set(stats) == expected, sorted(stats)
    assert stats["session_id"] is None and stats["clock"] is None and stats["poses_applied"] == 0
    assert s.latest_pose() is None
    assert s.poll_event() is None
    assert isinstance(s.host_clock_ns(), int)
    # No active device session: publishing applied state is refused.
    raises(OSError, s.update_status, 1, 0, 0, 0, "Camera")

    # Pairing code (vcp.md §9.4).
    code = s.enable_pairing()
    assert len(code) == 6 and code.isdigit(), code
    assert s.pairing_code() == code
    s.disable_pairing()
    assert s.pairing_code() is None
    raises(ValueError, s.update_status, 1, 0, 0, 0, "x" * 64)  # camera name over 63 bytes

    # DNS-SD: records are queued; asynchronous errors are pollable, never raised later.
    s.advertise("Blender session test", "")
    s.advertise("Blender session test", "Updated.blend")
    raises(ValueError, s.advertise, "x" * 300, "")  # TXT entry over 255 bytes
    s.discovery_error()

    # NFR-REL-001: a Rust panic is a catchable RuntimeError subclass, not BaseException.
    try:
        vcam_native._panic_probe()
    except Exception as e:  # noqa: BLE001 - the point is that plain `except Exception` works
        assert isinstance(e, vcam_native.NativeError) and isinstance(e, RuntimeError), type(e)
        assert "panic probe" in str(e), str(e)
    else:
        raise AssertionError("panic probe did not raise")
    assert s.running() and s.pairing_code() is None  # the session survives

    # NFR-REL-002: stop within 1 s, idempotent, then every call reports the stopped session.
    t0 = time.perf_counter()
    s.stop()
    stop_ms = (time.perf_counter() - t0) * 1000
    assert stop_ms < 1000, stop_ms
    assert not s.running()
    s.stop()
    raises(RuntimeError, s.stats)
    raises(RuntimeError, s.enable_pairing)
    raise_refused = raises(OSError, socket.create_connection, ("127.0.0.1", port), timeout=1)

    # Re-enable without restarting Blender: same TCP and UDP ports bind again at once.
    again = Session.start(port, config_dir, host_id, bind="127.0.0.1", udp_port=udp_port)
    assert (again.port(), again.udp_port()) == (port, udp_port)
    again.stop()

print(f"VCAM_SESSION_OK tcp={port} udp={udp_port} stop_ms={stop_ms:.0f} "
      f"panic=NativeError refused={type(raise_refused).__name__}")
