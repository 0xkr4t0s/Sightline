# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender: live stream settings change without carrying pending frames across modes, the
video stream (task 2.2c2b) runs exactly while the add-on's stream loop does, and the stream loop
renders at the resolution step the adaptive quality controller asks for (task 2.2d2c).

Requires an installed extension, a GPU (gpu.init()), and FAKE_IPHONE built in native/.
"""

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


class Recorder:
    """Stands in for the stream's FrameSlot: records each submit and passes the frame on to the
    encoder, so the test sees every frame without taking it from the video stream."""

    def __init__(self, slot):
        self.slot, self.frames = slot, []

    def submit(self, pixels, pose_seq, render_time_ns):
        frame_id = self.slot.submit(pixels, pose_seq, render_time_ns)
        self.frames.append({"frame_id": frame_id, "pose_seq": pose_seq, "render_time_ns": render_time_ns,
                            "shape": tuple(pixels.dimensions)})
        return frame_id


def take(stream):
    """The newest frame submitted since the last call, or None."""
    slot = stream.renderer.slot
    if not isinstance(slot, Recorder):
        slot = stream.renderer.slot = Recorder(slot)
    frame = slot.frames[-1] if slot.frames else None
    slot.frames.clear()
    return frame


scene = bpy.context.scene
camera = scene.camera
assert (scene.vcam_props.stream_resolution, scene.vcam_props.stream_fps,
        scene.vcam_props.stream_shading, scene.vcam_props.render_budget_ms) == ('540p', '30', 'SOLID', 12)
session.start(port=0, bind="127.0.0.1", stream=True)
live = session.current()
child = subprocess.Popen(
    [os.environ["FAKE_IPHONE"], "--host", f"127.0.0.1:{live.port()}",
     "--state", os.path.join(session.config_dir(), "stream-test.key"),
     "--code", live.enable_pairing(), "--motion", os.path.join(ROOT, "testdata/motion/scripted.bin"),
     "--rate", "120", "--linger", "8"],
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
            assert live.video_stats() is not None, "stream loop running without its video stream"
            frame = take(stream)
            if frame is not None:
                assert pending == (frame["pose_seq"], frame["render_time_ns"]), (pending, frame["pose_seq"])
                assert frame["pose_seq"] > 0
                assert 0 <= live.host_clock_ns() - frame["render_time_ns"] < 10_000_000_000
                assert frame["shape"] == (540, 960, 4), frame["shape"]
                frames.append(frame["frame_id"])
        else:
            assert live.video_stats() is None, "video stream running without the stream loop"
        time.sleep(0.003)
    assert frames == [1, 2, 3], frames
    # The rendered frames reach the device over the session UDP (NET-VID-001/004).
    deadline = time.monotonic() + 10
    while (live.video_stats()["last_sent"] or {}).get("source_frame_id", 0) < 1:
        assert time.monotonic() < deadline, live.video_stats()
        time.sleep(0.01)
    first_sent = live.video_stats()["last_sent"]
    assert first_sent["pose_seq"] > 0 and (first_sent["width"], first_sent["height"]) == (960, 540), first_sent
    assert first_sent["session_id"] == session.state.session_id, (first_sent, session.state.session_id)
    assert session._stream.pacer.budget_ms == 12
    assert session._stream.renderer.read_ns > 0 and session._stream.renderer.draw_ns > 0

    scene.vcam_props.render_budget_ms = 2
    session._poll()
    assert session._stream.pacer.budget_ms == 2

    def switch_mode(resolution, fps, shading, expected_size):
        stream = session._stream
        take(stream)  # discard an already published old-mode frame
        assert stream.renderer._pending is not None, "need a prior frame to discard"
        scene.vcam_props.stream_resolution = resolution
        scene.vcam_props.stream_fps = fps
        scene.vcam_props.stream_shading = shading
        session._poll()
        assert session.state.stream_error is None, session.state.stream_error
        assert session._stream is stream
        assert stream.renderer._pending is not None
        assert stream.renderer._offscreen is not None
        assert stream.renderer._offscreen.width == expected_size[0]
        assert stream.renderer._offscreen.height == expected_size[1]
        assert stream.renderer.shading == shading
        assert stream.pacer.fps == int(fps)
        assert take(stream) is None, "submitted a pending frame from the previous mode"
        deadline = time.monotonic() + 10
        while True:
            assert time.monotonic() < deadline, "new mode never produced a frame"
            session._poll()
            frame = take(stream)
            if frame is not None:
                assert frame['shape'] == (expected_size[1], expected_size[0], 4), frame['shape']
                return frame['frame_id']
            time.sleep(0.003)

    material_id = switch_mode('720p', '24', 'MATERIAL', (1280, 720))
    eevee_id = switch_mode('360p', '60', 'RENDERED', (640, 360))
    solid_id = switch_mode('1080p', '30', 'SOLID', (1920, 1080))
    assert material_id < eevee_id < solid_id
    # A mode switch keeps the video stream; its frames go out at the new size.
    deadline = time.monotonic() + 10
    while (live.video_stats()["last_sent"] or {}).get("width") != 1920:
        assert time.monotonic() < deadline, live.video_stats()
        session._poll()
        time.sleep(0.003)
    video = live.video_stats()
    assert video["sent"] >= 4 and video["send_failed"] == 0, video

    scene.camera = None
    session._poll()
    assert session._stream is None, "deleted camera kept its pending GPU frame"
    assert live.video_stats() is None, "video stream outlived its stream loop"
    scene.camera = camera
    deadline = time.monotonic() + 10
    while session._stream is None:
        assert time.monotonic() < deadline, "stream did not resume when the camera returned"
        session._poll()
        time.sleep(0.003)
    assert session._stream.renderer._pending[0] == session.applier().applied_seq
    assert session.state.stream_error is None
    restarted = live.video_stats()
    assert restarted is not None and restarted["sent"] == 0 and restarted["last_sent"] is None, restarted

    # NET-VID-005 through the add-on (task 2.2d2c): a device reporting a motion-to-photon p95
    # above 120 ms lowers the quality to the floor (80 → 50), then the stream loop renders one
    # size below the user's. Same pairing, new device session.
    def poll_until(what, done, timeout=30):
        deadline = time.monotonic() + timeout
        while not done():
            assert time.monotonic() < deadline and child.poll() is None, (what, live.video_stats())
            assert session._poll() == session.POLL_INTERVAL
            assert session.state.stream_error is None, session.state.stream_error
            time.sleep(0.003)

    def adapt():
        stats = live.video_stats()
        return (stats or {}).get("adapt") or {}

    child.kill()
    child.communicate()
    scene.vcam_props.stream_resolution = '540p'
    old_session = session.state.session_id
    child = subprocess.Popen(
        [os.environ["FAKE_IPHONE"], "--host", f"127.0.0.1:{live.port()}",
         "--state", os.path.join(session.config_dir(), "stream-test.key"),
         "--motion", os.path.join(ROOT, "testdata/motion/scripted.bin"),
         "--rate", "60", "--linger", "40", "--m2p", "150"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    poll_until("resolution drop", lambda: adapt().get("resolution_drop") == 1)
    assert session.state.session_id not in (None, old_session)
    stream = session._stream
    assert stream.max_resolution_drop == 1
    change = adapt()["last_change"]
    assert (change["from_quality"], change["to_quality"], change["from_resolution_drop"],
            change["to_resolution_drop"], change["reason"]) == (50, 50, 0, 1, "m2p"), change
    poll_until("frame at the lowered size", lambda: (live.video_stats()["last_sent"] or {}).get("width") == 640)
    assert (stream.renderer.width, stream.renderer.height) == (640, 360)
    labels = status.video_labels(live.video_stats(), '540p')
    assert "Adaptive: lowered to q50 640×360" in labels, labels
    assert "Last change: q50 960×540 → q50 640×360 (M2P 150 ms)" in labels, labels
    # The user picks the smallest size: no step below it, so the drop is cut back at once and
    # the stream keeps running at 640×360.
    scene.vcam_props.stream_resolution = '360p'
    poll_until("drop cut back", lambda: adapt().get("resolution_drop") == 0, timeout=1)
    assert session._stream is stream and stream.max_resolution_drop == 0
    changes = adapt()["changes"]
    # A larger size allows steps again; the still-slow link takes one at once.
    scene.vcam_props.stream_resolution = '1080p'
    poll_until("drop below 1080p", lambda: adapt().get("resolution_drop") == 1)
    poll_until("frame one size below 1080p",
               lambda: (live.video_stats()["last_sent"] or {}).get("width") == 1280)
    assert session._stream is stream and stream.max_resolution_drop == 3
    assert adapt()["changes"] == changes + 1, adapt()
    session.stop()
    assert live.video_stats() is None
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "stream-settings.blend")
        bpy.ops.wm.save_as_mainfile(filepath=path)
        scene.vcam_props.stream_resolution = '540p'
        scene.vcam_props.stream_fps = '24'
        scene.vcam_props.stream_shading = 'MATERIAL'
        bpy.ops.wm.open_mainfile(filepath=path)
        props = bpy.context.scene.vcam_props
        assert (props.stream_resolution, props.stream_fps, props.stream_shading) == ('1080p', '30', 'SOLID')
finally:
    session.stop()
    assert session._stream is None
    if child.poll() is None:
        child.terminate()
    child.communicate(timeout=5)
    addon_utils.disable(MODULE, default_set=True)

print(f"VCAM_RENDER_SESSION_OK frames={frames} modes=Material/EEVEE/Solid "
      f"sizes=720p/360p/1080p saved=true budget_ms=2 stopped=true "
      f"video_sent={video['sent']} video_skipped={video['encoded_skipped']} "
      f"video_1080p_jpeg={video['last_sent']['jpeg_bytes']} video_restarted_with_camera=true "
      f"adapt_sizes=960x540>640x360,cap@360p,1920x1080>1280x720 adapt_changes={changes + 1}")
