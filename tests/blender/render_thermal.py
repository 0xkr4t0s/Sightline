# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender: fake iPhone thermal transitions change actual streamed frames and pace."""

import importlib
import os
import subprocess
import tempfile
import time

import addon_utils
import bpy
import gpu

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
gpu.init()
addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")
status = importlib.import_module(MODULE + ".core.status")
scene = bpy.context.scene
scene.vcam_props.stream_resolution = '540p'
scene.vcam_props.stream_fps = '30'
session.start(port=0, bind="127.0.0.1", stream=True)
live = session.current()
child = None


def poll_until(label, condition, timeout=20):
    deadline = time.monotonic() + timeout
    while not condition():
        assert time.monotonic() < deadline, (label, live.video_stats())
        assert child.poll() is None, (label, child.returncode)
        session._poll()
        assert session.state.stream_error is None, session.state.stream_error
        time.sleep(0.004)


def launch(key, frame, *thermal):
    return subprocess.Popen(
        [
            os.environ["FAKE_IPHONE"],
            "--host",
            f"127.0.0.1:{live.port()}",
            "--state",
            key,
            "--motion",
            os.path.join(ROOT, "testdata/motion/scripted.bin"),
            "--rate",
            "120",
            "--linger",
            "12",
            "--video-out",
            frame,
            *thermal,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def sent_width():
    stats = live.video_stats()
    return ((stats or {}).get("last_sent") or {}).get("width")


try:
    with tempfile.TemporaryDirectory() as tmp:
        key, frame = os.path.join(tmp, "thermal.key"), os.path.join(tmp, "thermal.jpg")
        child = launch(key, frame, "--code", live.enable_pairing(), "--thermal", "2", "--thermal-at", "120")
        poll_until("nominal stream", lambda: session.applier().controls.thermal_state == 0 and sent_width() == 960)
        assert session._stream.pacer.fps == 30
        nominal = live.video_stats()["sent"]
        poll_until(
            "serious control and reduced stream",
            lambda: session.applier().controls.thermal_state == 2 and sent_width() == 640,
        )
        assert live.video_stats()["last_sent"]["height"] == 360
        assert session._stream.pacer.fps == 24
        assert status.thermal_label(2, (640, 360), 24) == (
            "Device thermal: serious — stream reduced to 640×360 @ 24 fps"
        )
        assert session.applier().controls.state_seq >= 2
        poll_until("serious frames delivered", lambda: live.video_stats()["sent"] >= nominal + 12)
        # FrameSlot sees only paced frames; the sender may skip frames, never add extra ones.
        sent, start = live.video_stats()["sent"], time.monotonic()
        while time.monotonic() - start < 1.2:
            session._poll()
            time.sleep(0.004)
        elapsed = time.monotonic() - start
        assert live.video_stats()["sent"] - sent <= 24 * elapsed + 1, live.video_stats()
        child.terminate()
        child.communicate(timeout=5)
        # New device session, still using the same pairing and host, restores nominal policy.
        old_session = session.state.session_id
        child = launch(key, frame, "--thermal", "0")
        poll_until(
            "nominal restored",
            lambda: (
                session.state.session_id not in (None, old_session)
                and session.applier().controls.thermal_state == 0
                and sent_width() == 960
            ),
        )
        assert session._stream.pacer.fps == 30
        assert status.thermal_label(0, (960, 540), 30) == "Device thermal: nominal"
        child.terminate()
        child.communicate(timeout=5)
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        child.communicate(timeout=5)
    session.stop()
    addon_utils.disable(MODULE, default_set=True)

print("VCAM_RENDER_THERMAL_OK nominal=960x540@30 serious=640x360@24 restored=960x540@30")
