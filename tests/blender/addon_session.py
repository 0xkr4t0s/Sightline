# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check of the add-on session lifecycle (task 1.2.5b; NFR-REL-002, NFR-SEC-003).

Install the extension exactly as for `smoke_native.py`, then:

    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/addon_session.py

enable (not listening) -> start operator -> disable (stops < 1 s, ports closed, poll removed)
-> re-enable -> start on the same port with the same host ID -> stop operator.
"""

import importlib
import os
import socket
import time

import addon_utils
import bpy

MODULE = "bl_ext.user_default.vcam_blender"


def enable():
    addon_utils.enable(MODULE, default_set=True, handle_error=None)
    assert MODULE in bpy.context.preferences.addons, f"{MODULE} not enabled"
    return importlib.import_module(MODULE + ".core.session")


def refused(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
    except OSError:
        return True
    return False


session = enable()
# NFR-SEC-003: enabling the add-on does not listen.
assert not session.running() and session.current() is None

assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
s = session.current()
port, udp_port = s.port(), s.udp_port()
assert not refused(port)
config = session.config_dir()
assert config.startswith(os.environ["BLENDER_USER_RESOURCES"]), config
host_id_path = os.path.join(config, session.HOST_ID_FILE)
with open(host_id_path, "rb") as f:
    host_id = f.read()
assert len(host_id) == 16
if os.name == "posix":
    assert os.stat(host_id_path).st_mode & 0o777 == 0o600, oct(os.stat(host_id_path).st_mode)
assert os.path.isdir(os.path.join(config, "vcam-pairings"))
poll = session._poll
assert bpy.app.timers.is_registered(poll)
assert poll() == session.POLL_INTERVAL  # drains nothing, keeps polling, never raises
assert session.state.session_id is None

# A second start is refused by the operator's poll, not by opening a second port.
try:
    bpy.ops.vcam.session_start(port=0)
except RuntimeError:
    pass
else:
    raise AssertionError("second session_start was allowed")

# NFR-REL-002: disabling the add-on stops everything within 1 s.
t0 = time.perf_counter()
addon_utils.disable(MODULE, default_set=True)
disable_ms = (time.perf_counter() - t0) * 1000
assert disable_ms < 1000, disable_ms
assert not s.running()
assert not bpy.app.timers.is_registered(poll)
assert refused(port)

# Re-enable without restarting Blender: same identity, same ports.
session = enable()
assert not session.running()
assert bpy.ops.vcam.session_start(port=port, bind="127.0.0.1") == {'FINISHED'}
assert session.current().port() == port
with open(host_id_path, "rb") as f:
    assert f.read() == host_id, "host ID changed across re-enable"
assert bpy.ops.vcam.session_stop() == {'FINISHED'}
assert not session.running() and refused(port)
assert not bpy.app.timers.is_registered(session._poll)
addon_utils.disable(MODULE, default_set=True)

print(f"VCAM_ADDON_SESSION_OK tcp={port} udp={udp_port} disable_ms={disable_ms:.0f} "
      f"host_id_stable=true")
