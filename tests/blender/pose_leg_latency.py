# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless pose-leg latency run with the fake iPhone (task 1.5.1; NFR-LAT-001).

Streams `testdata/motion/scripted.bin` at 60 Hz over loopback and drives the add-on's session
poll at its timer interval (`POLL_INTERVAL`, 60 Hz), as the GUI timer would; timers don't run
in a background script. Then saves the report with the `vcam.latency_report_save` operator and
checks it. Install the extension as for `smoke_native.py`, then:

    FAKE_IPHONE=native/target.nosync/debug/vcam-fake-iphone \\
    "$B" --background --factory-startup --python-exit-code 1 \\
        --python tests/blender/pose_leg_latency.py -- [--report reports/latency-....json]

Loopback measures the host side only: the fake's capture times come from its own clock (offset
by 1000 s), mapped through the `CLOCK` estimate, so the pose leg here is the wait in the
latest-sample slot plus the apply. The Wi-Fi figure needs a real iPhone (owner).
"""

import importlib
import json
import os
import subprocess
import sys
import tempfile
import time

import addon_utils
import bpy

MODULE = "bl_ext.user_default.vcam_blender"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE = os.environ["FAKE_IPHONE"]

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
report_path = argv[argv.index("--report") + 1] if "--report" in argv else os.path.join(
    tempfile.mkdtemp(), "latency.json")

addon_utils.enable(MODULE, default_set=True, handle_error=None)
session = importlib.import_module(MODULE + ".core.session")

assert bpy.ops.vcam.session_start(port=0, bind="127.0.0.1") == {'FINISHED'}
live = session.current()
child = subprocess.Popen(
    [FAKE, "--host", f"127.0.0.1:{live.port()}", "--state", os.path.join(session.config_dir(), "fake-iphone.key"),
     "--code", live.enable_pairing(), "--motion", os.path.join(ROOT, "testdata", "motion", "scripted.bin"),
     "--rate", "60", "--linger", "0.5"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
deadline = time.monotonic() + 60
tick = time.monotonic()
while child.poll() is None:
    assert time.monotonic() < deadline, "fake iPhone did not finish"
    session._poll()
    tick += session.POLL_INTERVAL
    time.sleep(max(0.0, tick - time.monotonic()))
out, err = child.communicate()
assert child.returncode == 0, err
for _ in range(100):  # the report outlives the device session: save it after SessionEnded
    session._poll()
    if session.state.session_id is None:
        break
    time.sleep(0.01)
assert session.state.session_id is None, "session did not end"

assert bpy.ops.vcam.latency_report_save(filepath=report_path) == {'FINISHED'}
with open(report_path, encoding="utf-8") as f:
    report = json.load(f)
leg, apply = report["legs"]["pose_leg_ms"], report["legs"]["apply_ms"]
assert report["device_name"] == "Fake iPhone" and report["clock"]["samples"] >= 1, report["clock"]
# 390 frames. Polling at the send rate, a poll sometimes finds two new poses and applies only
# the newer (NET-002), so every frame is either applied or counted as not applied.
assert leg["count"] + report["poses_without_clock"] == apply["count"] >= 100, (leg["count"], apply["count"])
assert apply["count"] + report["poses_not_applied"] <= 390, report["poses_not_applied"]
assert apply["count"] + report["poses_not_applied"] >= 390 - 60, report["poses_not_applied"]
# The capture time mapped through the offset lands on the host clock: never before the capture
# (beyond the offset's error, at most half the loopback round trip), and within a few polls.
assert leg["min"] > -1.0 and leg["p50"] < 50.0, leg
assert sum(leg["histogram"]["counts"]) + leg["histogram"]["underflow"] + leg["histogram"]["overflow"] == leg["count"]

assert bpy.ops.vcam.session_stop() == {'FINISHED'}
addon_utils.disable(MODULE, default_set=True)
print(f"VCAM_POSE_LEG_OK report={report_path} poses={apply['count']} not_applied={report['poses_not_applied']} "
      f"pose_leg_p50={leg['p50']:.2f} p95={leg['p95']:.2f} p99={leg['p99']:.2f} max={leg['max']:.2f} "
      f"apply_p95={apply['p95']:.3f} apply_max={apply['max']:.3f} meets={report['meets']}")
