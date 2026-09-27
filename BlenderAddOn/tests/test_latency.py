# SPDX-License-Identifier: GPL-3.0-or-later
"""Pose-leg latency log and report (task 1.5.1; NFR-LAT-001)."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.latency import BIN_COUNT, LatencyLog, percentile, summarize  # noqa: E402


def test_percentiles_are_nearest_rank():
    ordered = [float(v) for v in range(1, 101)]  # 1..100
    assert percentile(ordered, 50) == 50.0
    assert percentile(ordered, 95) == 95.0
    assert percentile(ordered, 99) == 99.0
    assert percentile([7.0], 95) == 7.0
    # 20 samples: p95 is the 19th value, so one outlier doesn't set it.
    assert percentile([1.0] * 19 + [500.0], 95) == 1.0
    assert percentile([1.0] * 18 + [500.0] * 2, 95) == 500.0


def test_histogram_bins_and_out_of_range_values():
    s = summarize([0.0, 0.49, 0.5, 12.3, 99.99, 100.0, 250.0, -0.2])
    h = s["histogram"]
    assert len(h["counts"]) == BIN_COUNT and h["bin_ms"] == 0.5
    assert h["counts"][0] == 2 and h["counts"][1] == 1 and h["counts"][24] == 1 and h["counts"][199] == 1
    assert h["underflow"] == 1 and h["overflow"] == 2
    assert sum(h["counts"]) + h["underflow"] + h["overflow"] == s["count"] == 8
    assert s["min"] == -0.2 and s["max"] == 250.0
    assert summarize([]) is None


def test_reapplied_pose_is_not_a_new_sample_and_a_new_session_starts_over():
    log = LatencyLog()
    assert log.record(7, 1, 0.3, None)  # applied before the first CLOCK estimate
    assert log.record(7, 2, 0.2, 11.0)
    assert not log.record(7, 2, 0.9, 30.0)  # Set origin re-applied seq 2
    assert list(log.apply_ms) == [0.3, 0.2] and list(log.pose_leg_ms) == [11.0]
    assert log.without_clock == 1
    assert log.record(7, 5, 0.2, 12.0)  # seqs 3 and 4 were never applied
    assert log.not_applied == 2
    assert log.record(8, 2, 0.4, 5.0)  # new session: seq restarts, old samples dropped
    assert log.session_id == 8 and list(log.pose_leg_ms) == [5.0] and log.without_clock == 0
    assert log.not_applied == 0


def test_oldest_samples_drop_first():
    log = LatencyLog(max_samples=3)
    for seq in range(1, 6):
        log.record(1, seq, 0.1, float(seq))
    assert list(log.pose_leg_ms) == [3.0, 4.0, 5.0]
    log.record(2, 1, 0.1, 9.0)
    assert log.pose_leg_ms.maxlen == 3


def test_report_verdicts_follow_nfr_lat_001():
    log = LatencyLog()
    for seq in range(1, 101):  # p95 exactly at the 20 ms limit, applies at most 1 ms
        log.record(3, seq, 1.0 if seq == 50 else 0.2, 20.0 if seq >= 90 else 8.0)
    r = json.loads(json.dumps(log.report(date="2026-09-25", device_name="Fake iPhone")))
    assert r["kind"] == "vcam-latency" and r["device_name"] == "Fake iPhone" and r["session_id"] == 3
    assert r["legs"]["pose_leg_ms"]["p95"] == 20.0 and r["legs"]["pose_leg_ms"]["p50"] == 8.0
    assert r["meets"] == {"pose_leg_p95": True, "apply_max": True}
    log.record(3, 101, 1.01, 25.0)  # one slow apply fails the every-apply limit
    for seq in range(102, 111):  # 10 of 110 poses at 25 ms move p95 over 20 ms
        log.record(3, seq, 0.2, 25.0)
    r = log.report()
    assert r["meets"] == {"pose_leg_p95": False, "apply_max": False}
    assert LatencyLog().report()["meets"] == {"pose_leg_p95": None, "apply_max": None}


def sent(frame_id, encode_ms, send_ms, session_id=4, width=960, height=540, quality=80):
    """A `video_stats()["last_sent"]` dict."""
    return {
        "session_id": session_id,
        "wire_frame_id": frame_id,
        "encode_ns": int(encode_ms * 1e6),
        "send_ns": int(send_ms * 1e6),
        "width": width,
        "height": height,
        "quality": quality,
    }


def test_stream_legs_are_sampled_once_per_frame():
    log = LatencyLog()
    log.record(4, 1, 0.2, 9.0)
    log.record_render(4, 3.5)
    log.record_render(4, 4.0)
    assert log.record_sent(4, sent(1, 6.0, 0.5))
    assert not log.record_sent(4, sent(1, 6.0, 0.5))  # the same frame seen by the next poll
    assert log.record_sent(4, sent(4, 7.0, 0.25, quality=70))  # frames 2 and 3 went out between polls
    assert not log.record_sent(4, sent(5, 1.0, 1.0, session_id=3))  # an earlier device session's frame
    assert list(log.render_readback_ms) == [3.5, 4.0]
    assert list(log.encode_ms) == [6.0, 7.0] and list(log.send_ms) == [0.5, 0.25]
    assert log.frames_not_sampled == 2
    assert log.stream == {"width": 960, "height": 540, "quality": 70}
    assert log.session_id == 4 and list(log.pose_leg_ms) == [9.0]


def test_device_m2p_is_one_sample_per_video_report():
    log = LatencyLog()
    adapt = {"session_id": 4, "report": {"report_seq": 1, "m2p_p95_ms": 0}}
    assert log.record_device_report(4, adapt)  # 0 = not measured yet (vcp.md §6.6)
    assert not log.record_device_report(4, adapt)  # polled again before the next report
    adapt["report"] = {"report_seq": 2, "m2p_p95_ms": 84}
    assert log.record_device_report(4, adapt)
    adapt["report"] = {"report_seq": 3, "m2p_p95_ms": 65535}  # saturated stays saturated
    assert log.record_device_report(4, adapt)
    assert not log.record_device_report(4, {"session_id": 4, "report": None})
    assert not log.record_device_report(4, {"session_id": 3, "report": {"report_seq": 9, "m2p_p95_ms": 50}})
    assert list(log.device_m2p_p95_ms) == [84.0, 65535.0] and log.reports_not_measured == 1


def test_a_new_session_drops_the_stream_legs_too():
    log = LatencyLog()
    log.record_render(4, 3.0)
    log.record_sent(4, sent(7, 5.0, 0.5))
    log.record_device_report(4, {"session_id": 4, "report": {"report_seq": 2, "m2p_p95_ms": 90}})
    log.record_render(5, 2.0)
    assert log.session_id == 5 and list(log.render_readback_ms) == [2.0]
    assert not log.encode_ms and not log.send_ms and not log.device_m2p_p95_ms and log.stream is None
    assert log.record_sent(5, sent(1, 4.0, 0.4, session_id=5)) and log.frames_not_sampled == 0
    # Report seqs restart with the session too.
    assert log.record_device_report(5, {"session_id": 5, "report": {"report_seq": 2, "m2p_p95_ms": 70}})


def test_report_has_every_host_leg_and_the_device_m2p():
    log = LatencyLog()
    for seq in range(1, 101):
        log.record(4, seq, 0.2, 8.0)
        log.record_render(4, 2.0 if seq <= 95 else 9.0)
        log.record_sent(4, sent(seq, 5.0 if seq <= 50 else 6.0, 0.3))
    for seq, m2p in enumerate((80, 85, 90, 130), start=1):
        log.record_device_report(4, {"session_id": 4, "report": {"report_seq": seq, "m2p_p95_ms": m2p}})
    r = json.loads(json.dumps(log.report(date="2026-09-28")))
    assert r["kind"] == "vcam-latency" and r["format"] == 2
    assert set(r["legs"]) == {"pose_leg_ms", "apply_ms", "render_readback_ms", "encode_ms", "send_ms"}
    for leg in r["legs"].values():
        assert {"count", "p50", "p95", "p99", "histogram"} <= set(leg) and leg["count"] == 100
    assert (r["legs"]["render_readback_ms"]["p95"], r["legs"]["render_readback_ms"]["p99"]) == (2.0, 9.0)
    assert (r["legs"]["encode_ms"]["p50"], r["legs"]["encode_ms"]["p95"]) == (5.0, 6.0)
    assert r["legs"]["send_ms"]["p50"] == 0.3
    assert r["device_m2p_p95_ms"]["count"] == 4 and r["device_m2p_p95_ms"]["max"] == 130.0
    assert r["device_reports_not_measured"] == 0 and r["frames_not_sampled"] == 0
    assert r["stream"] == {"width": 960, "height": 540, "quality": 80}
    assert set(r["methods"]) == set(r["legs"]) | {"device_m2p_p95_ms"}
    # The NFR-LAT-001 verdicts are unchanged.
    assert r["meets"] == {"pose_leg_p95": True, "apply_max": True}
    empty = LatencyLog().report()
    assert empty["legs"]["render_readback_ms"] is None and empty["device_m2p_p95_ms"] is None


def test_summary_line_lists_every_leg():
    log = LatencyLog()
    log.record(4, 1, 0.2, 9.0)
    log.record_render(4, 3.25)
    line = log.summary_line()
    assert line.startswith("session=4 pose_leg_ms n=1 p50=9.00")
    assert "render_readback_ms n=1 p50=3.25" in line
    assert "encode=none" in line and "send=none" in line and "device_m2p_p95=none" in line
