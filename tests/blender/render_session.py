# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender: the live session renders budgeted frames with applied pose/host-clock metadata.

Requires an installed extension, a GPU (gpu.init()), and FAKE_IPHONE built in native/.
"""

import importlib
import os
import subprocess
import time

import addon_utils
import bpy
import gpu

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

gpu.init()
addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")
scene = bpy.context.scene
camera = scene.camera
assert scene.vcam_props.render_budget_ms == 12
session.start(port=0, bind="127.0.0.1", stream=True)
live = session.current()
child = subprocess.Popen(
    [os.environ["FAKE_IPHONE"], "--host", f"127.0.0.1:{live.port()}",
     "--state", os.path.join(session.config_dir(), "stream-test.key"),
     "--code", live.enable_pairing(), "--motion", os.path.join(ROOT, "testdata/motion/scripted.bin"),
     "--rate", "120", "--linger", "4"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)

try:
    frames = []
    deadline = time.monotonic() + 20
    while len(frames) < 3:
        assert time.monotonic() < deadline, "no streamed frames from the live session"
        old_stream = session._stream
        pending = old_stream.renderer._pending if old_stream is not None else None
        assert session._poll() == session.POLL_INTERVAL
        assert session.state.stream_error is None, session.state.stream_error
        stream = session._stream
        if stream is not None:
            frame = stream.renderer.slot._take()
            if frame is not None:
                assert pending == (frame["pose_seq"], frame["render_time_ns"]), (pending, frame["pose_seq"])
                assert frame["pose_seq"] > 0
                assert 0 <= live.host_clock_ns() - frame["render_time_ns"] < 10_000_000_000
                assert (frame["width"], frame["height"]) == (960, 540)
                assert len(frame["pixels"]) == 960 * 540 * 4
                frames.append(frame["frame_id"])
        time.sleep(0.003)
    assert frames == [1, 2, 3], frames
    assert session._stream.pacer.budget_ms == 12
    assert session._stream.renderer.read_ns > 0 and session._stream.renderer.draw_ns > 0

    scene.vcam_props.render_budget_ms = 2
    session._poll()
    assert session._stream.pacer.budget_ms == 2

    scene.camera = None
    session._poll()
    assert session._stream is None, "deleted camera kept its pending GPU frame"
    scene.camera = camera
    deadline = time.monotonic() + 10
    while session._stream is None:
        assert time.monotonic() < deadline, "stream did not resume when the camera returned"
        session._poll()
        time.sleep(0.003)
    assert session._stream.renderer._pending[0] == session.applier().applied_seq
    assert session.state.stream_error is None
finally:
    session.stop()
    assert session._stream is None
    if child.poll() is None:
        child.terminate()
    child.communicate(timeout=5)
    addon_utils.disable(MODULE, default_set=True)

print(f"VCAM_RENDER_SESSION_OK frames={frames} budget_ms=2 restored_camera=true stopped=true")
