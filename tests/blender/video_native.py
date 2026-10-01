# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender: `vcam_native` viewfinder frames reach the fake iPhone (task 2.2c2a;
NET-VID-001, NET-VID-004) and adapt to its reports (task 2.2d2b; NET-VID-005).

Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/video_native.py

Submits a known frame (red above blue, rows bottom-up as `GPUOffScreen` reads them) to a
`FrameSlot` while `Session.start_video` encodes and sends it. Checks that frames before a device
connects are counted as unsent, that the newest frame the host sent is the newest complete frame
the fake iPhone reassembled (wire id, JPEG length, pose seq), that a quality change reaches the
stream, and that Blender decodes the received JPEG upright at the right size and colours. A
second session whose device reports a motion-to-photon p95 of 150 ms must lower the quality.
"""

import os
import re
import subprocess
import tempfile
import time

import addon_utils
import bpy
import numpy as np

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE = os.environ["FAKE_IPHONE"]
WIDTH, HEIGHT = 640, 360
RED, BLUE = (230, 20, 20, 255), (20, 20, 230, 255)

addon_utils.enable(MODULE, default_set=True, handle_error=None)
import vcam_native  # noqa: E402

# libjpeg-turbo's IJG/BSD terms require the notices in the binary distribution (SRS §13.2).
addon_dir = os.path.dirname(__import__(MODULE, fromlist=["_"]).__file__)
with open(os.path.join(addon_dir, "THIRD_PARTY_NOTICES.md"), encoding="utf-8") as f:
    notices = f.read()
assert "based in part on the work of the Independent JPEG Group" in notices
assert "Neither the name of the libjpeg-turbo Project" in notices


def raises(exc, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except exc as e:
        return e
    raise AssertionError(f"{fn} did not raise {exc.__name__}")


def wait_for(what, done, timeout=10.0):
    deadline = time.monotonic() + timeout
    while not done():
        assert time.monotonic() < deadline, what
        time.sleep(0.005)


frame = np.empty((HEIGHT, WIDTH, 4), dtype=np.uint8)
frame[: HEIGHT // 2] = BLUE  # stored bottom-up: the lower half as displayed
frame[HEIGHT // 2 :] = RED

with tempfile.TemporaryDirectory() as tmp:
    session = vcam_native.Session.start(0, tmp, os.urandom(16), bind="127.0.0.1")
    assert session.latest_control() is None
    slot = vcam_native.FrameSlot()
    assert session.video_stats() is None
    raises(ValueError, session.start_video, slot, quality=0)
    raises(RuntimeError, session.set_video_quality, 50)
    session.start_video(slot, quality=85)

    # No device yet: the frame is encoded, then dropped as unsent (not a send failure).
    slot.submit(frame, 0, session.host_clock_ns())
    wait_for("frame before the device was not dropped as unsent", lambda: session.video_stats()["unsent"] == 1)
    stats = session.video_stats()
    assert (stats["encoded"], stats["sent"], stats["send_failed"], stats["last_sent"]) == (1, 0, 0, None), stats

    video_out = os.path.join(tmp, "newest.jpg")
    child = subprocess.Popen(
        [
            FAKE,
            "--host",
            f"127.0.0.1:{session.port()}",
            "--state",
            os.path.join(tmp, "fake-iphone.key"),
            "--code",
            session.enable_pairing(),
            "--motion",
            os.path.join(ROOT, "testdata", "motion", "scripted.bin"),
            "--rate",
            "60",
            "--thermal",
            "2",
            "--linger",
            "1",
            "--video-out",
            video_out,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for("no authenticated device source", lambda: session.stats()["source"] is not None, timeout=20)
        wait_for("no thermal control", lambda: session.latest_control() is not None)
        assert session.latest_control()["thermal_state"] == 2, session.latest_control()
        deadline = time.monotonic() + 20
        while session.video_stats()["sent"] < 40:
            assert time.monotonic() < deadline and child.poll() is None, session.video_stats()
            if session.video_stats()["sent"] >= 20 and session.video_stats()["user_quality"] == 85:
                session.set_video_quality(40)
            pose = session.latest_pose()
            last_id = slot.submit(frame, pose["seq"] if pose else 0, session.host_clock_ns())
            time.sleep(1 / 30)
        # Nothing newer replaces the last frame, so it is encoded and sent in turn.
        wait_for(
            "last submitted frame was not sent",
            lambda: (session.video_stats()["last_sent"] or {}).get("source_frame_id") == last_id,
        )
        stats = session.video_stats()
        out, err = child.communicate(timeout=30)
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()
    assert child.returncode == 0, err
    done = dict(re.findall(r"(\w+)=(\d+)", out.splitlines()[-1].split(" camera=")[0]))
    last = stats["last_sent"]
    assert stats["send_failed"] == 0 and stats["last_error"] is None, stats
    assert (stats["adapt"]["session_id"], stats["adapt"]["report"] is not None) == (last["session_id"], True), stats
    assert last["quality"] == 40 and last["pose_seq"] > 0, last
    assert (last["width"], last["height"]) == (WIDTH, HEIGHT), last
    assert int(done["session_id"]) == last["session_id"], (done, last)
    assert (int(done["video_last_id"]), int(done["video_last_len"]), int(done["video_last_pose_seq"])) == (
        last["wire_frame_id"],
        last["jpeg_bytes"],
        last["pose_seq"],
    ), (done, last)
    # Loopback: allow a little loss, but most frames must arrive whole.
    received, lost = int(done["video_frames"]), int(done["video_lost"])
    assert received >= stats["sent"] * 0.9 and lost <= stats["sent"] * 0.1, (done, stats)

    image = bpy.data.images.load(video_out)
    assert tuple(image.size) == (WIDTH, HEIGHT), tuple(image.size)
    pixels = np.empty(WIDTH * HEIGHT * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    pixels = (pixels.reshape(HEIGHT, WIDTH, 4) * 255).round()  # Blender rows are bottom-up too
    top, bottom = pixels[HEIGHT * 3 // 4, WIDTH // 2, :3], pixels[HEIGHT // 4, WIDTH // 2, :3]
    assert np.abs(top - RED[:3]).max() <= 16 and np.abs(bottom - BLUE[:3]).max() <= 16, (top, bottom)

    # NET-VID-005 end to end (task 2.2d2b): a device reporting a motion-to-photon p95 above
    # 120 ms makes the host lower the quality in steps of 10 (after 2 bad reports, then 2
    # settling ones), and frames go out at the lowered quality. Same pairing, new session.
    # A loaded runner can lose a frame in a report interval, and the adapter ranks loss before
    # M2P, so a step may be a genuine 'loss' one. Every change is recorded as it appears (only
    # the last is exposed; settling spaces them about 2 s apart: 2 settling + 2 bad reports at
    # 500 ms), each must be a 10-point step for 'm2p' or for 'loss' with frames really lost, and
    # the test waits for two steps, at least one of them 'm2p'.
    seen = {}

    def observe(stats):
        change = (stats["adapt"] or {}).get("last_change")
        if change is not None and change["report_seq"] not in seen:
            seen[change["report_seq"]] = change
            assert change["to_quality"] == change["from_quality"] - 10, change
            assert change["from_resolution_drop"] == change["to_resolution_drop"] == 0, change
            assert change["reason"] in ("m2p", "loss"), change
            if change["reason"] == "loss":
                assert change["lost"] > 0 and change["expected"] >= change["lost"], change
            else:
                assert (change["m2p_p95_ms"], change["lost"]) == (150, None), change
        return change

    session.start_video(slot, quality=80, max_resolution_drop=1)
    assert session.video_stats()["adapt"] is None
    child = subprocess.Popen(
        [
            FAKE,
            "--host",
            f"127.0.0.1:{session.port()}",
            "--state",
            os.path.join(tmp, "fake-iphone.key"),
            "--motion",
            os.path.join(ROOT, "testdata", "motion", "scripted.bin"),
            "--rate",
            "60",
            "--linger",
            "20",
            "--m2p",
            "150",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 20
        while True:
            adapted = session.video_stats()
            observe(adapted)
            if len(seen) >= 2 and any(c["reason"] == "m2p" for c in seen.values()):
                break
            assert time.monotonic() < deadline and child.poll() is None, (seen, adapted)
            slot.submit(frame, 0, session.host_clock_ns())
            time.sleep(1 / 30)
        # A higher user quality doesn't undo the adaptation; the stream recovers towards it.
        session.set_video_quality(90)
        raised = session.video_stats()
        observe(raised)
        deadline = time.monotonic() + 10
        while True:
            now = session.video_stats()
            observe(now)
            if (now["last_sent"] or {}).get("quality") == now["quality"] < 90:
                break
            assert time.monotonic() < deadline and child.poll() is None, (seen, now)
            slot.submit(frame, 0, session.host_clock_ns())
            time.sleep(1 / 30)
    finally:
        child.kill()
        child.communicate()
    adapt, change = adapted["adapt"], adapted["adapt"]["last_change"]
    first = seen[min(seen)]
    assert (first["from_quality"], change["to_resolution_drop"]) == (80, 0), (seen, adapted)
    assert any(c["reason"] == "m2p" and c["m2p_p95_ms"] == 150 for c in seen.values()), seen
    # The recorded steps are consecutive: each starts where the previous one ended.
    steps = [seen[k] for k in sorted(seen)]
    assert all(a["to_quality"] == b["from_quality"] for a, b in zip(steps, steps[1:], strict=False)), steps
    # The quality is whatever the observed steps lowered it to, and the user's is untouched.
    assert (adapted["quality"], adapted["user_quality"], adapt["quality"], adapt["resolution_drop"]) == (
        change["to_quality"],
        80,
        change["to_quality"],
        0,
    ), adapted
    assert adapt["session_id"] not in (0, last["session_id"]), (adapt, last)
    report = adapt["report"]
    assert report["m2p_p95_ms"] == 150 and 0 < report["frames_complete"] <= report["newest_frame_id"], adapt
    assert adapt["last_interval"]["report_seq"] == report["report_seq"] and adapt["lost"] <= adapt["expected"], adapt
    # set_video_quality isn't one of the adapter's changes: only a report adds to the count.
    raised_change = raised["adapt"]["last_change"]
    assert (raised["quality"], raised["user_quality"]) == (raised_change["to_quality"], 90), raised
    new = raised_change["report_seq"] != change["report_seq"]
    assert raised["adapt"]["changes"] == adapt["changes"] + new, (adapted, raised)
    # The device left: the adapter goes with its session and the stream is back at the user's
    # quality for the next device.
    deadline = time.monotonic() + 10
    while session.video_stats()["adapt"] is not None:
        assert time.monotonic() < deadline, session.video_stats()
        slot.submit(frame, 0, session.host_clock_ns())
        time.sleep(1 / 30)
    assert session.video_stats()["quality"] == 90, session.video_stats()

    started = time.perf_counter()
    session.stop()  # stops the running video stream too
    stop_ms = (time.perf_counter() - started) * 1e3
    assert session.video_stats() is None
    raises(RuntimeError, session.start_video, slot)
    session.stop_video()

addon_utils.disable(MODULE, default_set=True)
print(
    f"VCAM_VIDEO_OK sent={stats['sent']} received={received} lost={lost} unsent={stats['unsent']} "
    f"skipped={stats['encoded_skipped']} last_id={last['wire_frame_id']} jpeg_bytes={last['jpeg_bytes']} "
    f"fragments={last['fragments']} encode_ms={last['encode_ns'] / 1e6:.2f} send_ms={last['send_ns'] / 1e6:.2f} "
    f"quality={last['quality']} decoded={WIDTH}x{HEIGHT} top={top.astype(int).tolist()} "
    f"bottom={bottom.astype(int).tolist()} stop_ms={stop_ms:.0f} adapt_changes={adapt['changes']} "
    f"adapt_quality={adapted['quality']} adapt_report_seq={report['report_seq']}"
)
