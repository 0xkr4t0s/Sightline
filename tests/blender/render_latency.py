# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender: the host latency report's stream legs and the device M2P (task 2.6; NFR-LAT-004,
NET-VID-005).

A fake iPhone streams `testdata/motion/scripted.bin` and reports `--m2p 85` in its VIDEO_REPORTs.
The add-on's poll records render/readback, encode and send per frame and the device's M2P per
report; the N-panel's video lines show the newest report's M2P. After the session the Save
Latency Report operator writes all of them. A second session reporting 140 ms replaces the value
(no stale M2P) and starts a fresh log.

Requires an installed extension, a GPU (gpu.init()), and FAKE_IPHONE built in native/. Encode and
send times come from the debug `vcam_native` wheel setup.sh builds; they aren't release numbers.
"""

import importlib
import json
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
assert (scene.vcam_props.stream_resolution, scene.vcam_props.stream_fps) == ('540p', '30')
session.start(port=0, bind="127.0.0.1", stream=True)
live = session.current()
key = os.path.join(session.config_dir(), "latency-test.key")


def fake_iphone(m2p, linger, code=None):
    args = [
        os.environ["FAKE_IPHONE"],
        "--host",
        f"127.0.0.1:{live.port()}",
        "--state",
        key,
        "--motion",
        os.path.join(ROOT, "testdata/motion/scripted.bin"),
        "--rate",
        "60",
        "--linger",
        str(linger),
        "--m2p",
        str(m2p),
    ]
    if code is not None:
        args += ["--code", code]
    return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def labels():
    return status.video_labels(live.video_stats(), '540p')


class Counter:
    """Stands in for the stream's FrameSlot and counts the frames the renderer submits."""

    def __init__(self, slot):
        self.slot, self.submitted = slot, 0

    def submit(self, pixels, pose_seq, render_time_ns):
        self.submitted += 1
        return self.slot.submit(pixels, pose_seq, render_time_ns)


def count_submits():
    """Wraps the running stream's slot once; the number of frames it submitted so far."""
    stream = session._stream
    if stream is None:
        return 0
    if not isinstance(stream.renderer.slot, Counter):
        # A new stream's first tick only draws, so wrapping after it misses no submit.
        assert not session.latency_log().render_readback_ms, "a stream restarted within the session"
        stream.renderer.slot = Counter(stream.renderer.slot)
    return stream.renderer.slot.submitted


def poll_for(child, seconds):
    """Runs the add-on's poll at its timer interval, as the GUI timer would."""
    deadline = time.monotonic() + seconds
    tick = time.monotonic()
    while time.monotonic() < deadline and child.poll() is None:
        assert session._poll() == session.POLL_INTERVAL
        assert session.state.stream_error is None, session.state.stream_error
        yield
        tick += session.POLL_INTERVAL
        time.sleep(max(0.0, tick - time.monotonic()))


child = fake_iphone(85, 1.0, live.enable_pairing())
report_path = os.path.join(tempfile.mkdtemp(), "latency.json")
try:
    shown = None
    submitted = 0
    for _ in poll_for(child, 60):
        submitted = max(submitted, count_submits())
        if shown is None and "Device M2P p95: 85 ms" in labels():
            shown = labels()
    out, err = child.communicate(timeout=10)
    assert child.returncode == 0, err
    assert shown is not None, "the N-panel never showed the device's M2P"
    for _ in range(100):  # the log outlives the device session: save it after SessionEnded
        session._poll()
        if session.state.session_id is None:
            break
        time.sleep(0.01)
    assert session.state.session_id is None, "session did not end"

    assert bpy.ops.vcam.latency_report_save(filepath=report_path) == {'FINISHED'}
    with open(report_path, encoding="utf-8") as f:
        report = json.load(f)
    assert report["kind"] == "vcam-latency" and report["format"] == 2, report["format"]
    legs = report["legs"]
    assert set(legs) == {"pose_leg_ms", "apply_ms", "render_readback_ms", "encode_ms", "send_ms"}, legs.keys()
    for name in ("render_readback_ms", "encode_ms", "send_ms"):
        leg = legs[name]
        assert leg is not None and leg["count"] >= 20, (name, leg and leg["count"])
        assert 0.0 < leg["p50"] <= leg["p95"] <= leg["p99"] <= leg["max"] < 1000.0, (name, leg)
    # One render/readback sample per submitted frame, none for ticks the pacer skipped.
    assert legs["render_readback_ms"]["count"] == submitted, (legs["render_readback_ms"]["count"], submitted)
    # Every sent frame is either sampled or counted by its wire frame_id gap.
    sent_frames = legs["encode_ms"]["count"] + report["frames_not_sampled"]
    assert legs["send_ms"]["count"] == legs["encode_ms"]["count"] and sent_frames >= 20, report
    assert report["stream"]["width"] == 960 and report["stream"]["height"] == 540, report["stream"]
    m2p = report["device_m2p_p95_ms"]
    assert m2p is not None and m2p["count"] >= 2 and m2p["min"] == m2p["max"] == 85.0, m2p
    assert legs["pose_leg_ms"]["count"] >= 100 and legs["apply_ms"]["count"] >= 100, legs["apply_ms"]
    assert set(report["methods"]) == set(legs) | {"device_m2p_p95_ms"}

    # A new report value replaces the shown one; the new device session starts a fresh log.
    first_session = report["session_id"]
    child = fake_iphone(140, 30)
    for _ in poll_for(child, 30):
        if "Device M2P p95: 140 ms (over 120 ms)" in labels():
            break
    else:
        raise AssertionError(("the N-panel kept a stale M2P", labels()))
    assert "Device M2P p95: 85 ms" not in labels()
    session._poll()  # the report may have arrived after this poll's video_stats()
    log = session.latency_log()
    assert log.session_id not in (None, first_session) and list(log.device_m2p_p95_ms)[-1] == 140.0
    assert len(log.encode_ms) < legs["encode_ms"]["count"], "the new session kept the old samples"
finally:
    session.stop()
    if child.poll() is None:
        child.terminate()
    child.communicate(timeout=5)
    addon_utils.disable(MODULE, default_set=True)

render_leg, encode, send = legs["render_readback_ms"], legs["encode_ms"], legs["send_ms"]
print(
    f"VCAM_RENDER_LATENCY_OK report_format={report['format']} frames={render_leg['count']} "
    f"render_readback_p50={render_leg['p50']:.2f} p95={render_leg['p95']:.2f} p99={render_leg['p99']:.2f} "
    f"encode_p50={encode['p50']:.2f} p95={encode['p95']:.2f} send_p50={send['p50']:.3f} p95={send['p95']:.3f} "
    f"not_sampled={report['frames_not_sampled']} device_m2p=85->140 reports={m2p['count']}"
)
