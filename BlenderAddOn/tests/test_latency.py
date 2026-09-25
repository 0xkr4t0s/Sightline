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
