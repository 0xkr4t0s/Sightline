"""tools/soak/soak_verdict.py: soak series analysis and verdicts (task 2.7; NFR-REL-003)."""

import json
import sys
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import soak_verdict as sv  # noqa: E402

LIMITS = sv.LatencyLimits(pose_leg_p95_ms=30.0, frame_p95_ms=100.0, m2p_p95_ms=120.0)


def sample(t: float, **over: Any) -> dict[str, Any]:
    """One healthy sample at `t` s: host alive, state fresh, one session, frames and poses flowing."""
    s: dict[str, Any] = {
        "t_s": t,
        "host_alive": True,
        "rss_kib": 800_000,
        "handles": 120,
        "state_uptime_s": 10.0 + t,
        "session_id": 7,
        "applied_seq": int(60 * t),
        "video_sent": int(30 * t),
        "video_expected": int(30 * t),
        "video_lost": int(7 * t),
        "pose_leg_p95_ms": 22.0,
        "frame_p95_ms": 45.0,
        "errors": 0,
    }
    s.update(over)
    return s


def run(n: int = 120, interval: float = 5.0, **over: Any) -> list[dict[str, Any]]:
    return [sample(interval * (i + 1), **over) for i in range(n)]


FAKE_DONE = {"video_frames": 12000, "video_lost": 3000, "poses": 36000, "control_ack": 1}


# --- state.json → sample ---


def leg(p95: float) -> dict[str, float]:
    return {"count": 100, "p50": p95 / 2, "p95": p95, "p99": p95 + 1, "max": p95 + 2}


def test_sample_from_state() -> None:
    state = {
        "uptime_s": 42.5,
        "session": {"session_id": 7, "applied_seq": 900},
        "latency": {
            "pose_leg_ms": leg(21.25),
            "render_readback_ms": leg(3.0),
            "encode_ms": leg(38.0),
            "send_ms": leg(0.75),
        },
        "video": {"sent": 400, "adapt": {"expected": 390, "lost": 80, "quality": 50, "resolution_drop": 1}},
        "errors": ["boom"],
    }
    s = sv.sample_from_state(12.34, True, 1024, 99, state)
    assert s == {
        "t_s": 12.3,
        "host_alive": True,
        "rss_kib": 1024,
        "handles": 99,
        "state_uptime_s": 42.5,
        "session_id": 7,
        "applied_seq": 900,
        "video_sent": 400,
        "video_expected": 390,
        "video_lost": 80,
        "quality": 50,
        "resolution_drop": 1,
        "pose_leg_p95_ms": 21.25,
        "frame_p95_ms": 41.75,
        "errors": 1,
    }


def test_sample_from_empty_state() -> None:
    s = sv.sample_from_state(5.0, False, None, None, {"session": {"session_id": None}, "video": None, "latency": {}})
    assert s["session_id"] is None
    assert s["video_sent"] is None
    assert s["pose_leg_p95_ms"] is None
    assert s["frame_p95_ms"] is None
    assert s["errors"] == 0
    # A frame leg missing: no frame-path sum rather than a partial one.
    partial = {"latency": {"render_readback_ms": leg(3.0), "encode_ms": None, "send_ms": leg(1.0)}}
    assert sv.sample_from_state(5.0, True, 1, 1, partial)["frame_p95_ms"] is None


# --- slope and growth ---


def test_slope_of_a_line_is_per_minute() -> None:
    points = [(t, 100.0 + 0.5 * t) for t in range(0, 600, 10)]
    assert sv.slope_per_min(points) == pytest.approx(30.0)


def test_slope_needs_two_distinct_times() -> None:
    assert sv.slope_per_min([]) is None
    assert sv.slope_per_min([(5.0, 1.0)]) is None
    assert sv.slope_per_min([(5.0, 1.0), (5.0, 3.0)]) is None


def test_net_growth_compares_the_first_and_last_tenth_medians() -> None:
    points = [(float(t), 10.0) for t in range(50)] + [(float(t), 30.0) for t in range(50, 100)]
    assert sv.net_growth(points) == pytest.approx(20.0)
    # A single spike at the end doesn't move the median of the last tenth.
    spiky = [(float(t), 10.0) for t in range(100)]
    spiky[-1] = (99.0, 500.0)
    assert sv.net_growth(spiky) == pytest.approx(0.0)
    assert sv.net_growth([(0.0, 1.0)]) is None


def test_flat_series_is_bounded() -> None:
    points = [(5.0 * i, 800.0 + (i % 3) * 0.5) for i in range(120)]
    v = sv.growth_verdict(points, warmup_s=60.0, limit=sv.RSS_LIMIT)
    assert v["pass"] is True
    assert v["samples"] == 108
    assert abs(v["slope_per_min"]) < 0.1
    assert v["limit"] == {"slope_per_min": sv.RSS_LIMIT.slope_per_min, "growth": sv.RSS_LIMIT.growth, "unit": "MiB"}


def test_steady_growth_after_warm_up_fails() -> None:
    # 3 MiB/min for 10 minutes: past both the slope and the net-growth limit.
    points = [(5.0 * i, 800.0 + 3.0 * (5.0 * i) / 60.0) for i in range(120)]
    v = sv.growth_verdict(points, warmup_s=60.0, limit=sv.RSS_LIMIT)
    assert v["pass"] is False
    assert v["slope_per_min"] == pytest.approx(3.0)
    assert "slope" in v["reason"]


def test_growth_during_warm_up_only_is_bounded() -> None:
    points = [(5.0 * i, 400.0 + 40.0 * i if 5.0 * i < 60.0 else 900.0) for i in range(120)]
    assert sv.growth_verdict(points, warmup_s=60.0, limit=sv.RSS_LIMIT)["pass"] is True


def test_steep_but_small_change_is_bounded() -> None:
    # A short run can show a steep slope from a few MiB of allocator noise; the net growth stays
    # under its limit, so it isn't called a leak.
    points = [(5.0 * i, 800.0 + (2.0 if i > 20 else 0.0)) for i in range(30)]
    v = sv.growth_verdict(points, warmup_s=0.0, limit=sv.RSS_LIMIT)
    assert v["slope_per_min"] > sv.RSS_LIMIT.slope_per_min
    assert v["pass"] is True


def test_one_off_step_without_trend_is_bounded() -> None:
    # A cache filling once, an hour into a 2-hour run: the net growth is large but the fitted
    # slope stays under the limit.
    points = [(5.0 * i, 800.0 + (60.0 if i >= 720 else 0.0)) for i in range(1440)]
    v = sv.growth_verdict(points, warmup_s=60.0, limit=sv.RSS_LIMIT)
    assert v["growth"] == pytest.approx(60.0)
    assert v["slope_per_min"] < sv.RSS_LIMIT.slope_per_min
    assert v["pass"] is True


def test_handle_leak_fails() -> None:
    points = [(5.0 * i, 120.0 + i // 2) for i in range(120)]
    v = sv.growth_verdict(points, warmup_s=60.0, limit=sv.HANDLE_LIMIT)
    assert v["pass"] is False


def test_too_few_samples_after_warm_up_fails() -> None:
    v = sv.growth_verdict([(0.0, 1.0), (70.0, 1.0)], warmup_s=60.0, limit=sv.RSS_LIMIT)
    assert v["pass"] is False
    assert "too few" in v["reason"]


def test_missing_values_are_skipped() -> None:
    samples = run(rss_kib=None)
    assert sv.series(samples, "rss_kib") == []
    samples = run()
    samples[3]["rss_kib"] = None
    assert len(sv.series(samples, "rss_kib", scale=1 / 1024)) == 119
    assert sv.series(samples, "rss_kib", scale=1 / 1024)[0] == (5.0, pytest.approx(800_000 / 1024))


# --- crash ---


def test_healthy_run_has_no_crash() -> None:
    v = sv.crash_verdict(run(), fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)
    assert v == {"pass": True, "reasons": [], "sessions": 1, "host_exit_at_s": None}


def test_host_exit_is_a_crash() -> None:
    samples = run()
    samples[80]["host_alive"] = False
    v = sv.crash_verdict(samples[:81], fake_exit=1, fake_done=None, duration_s=600.0)
    assert v["pass"] is False
    assert v["host_exit_at_s"] == 405.0
    assert any("Blender host exited" in r for r in v["reasons"])
    assert any("fake iPhone exited 1" in r for r in v["reasons"])
    assert any("FAKE_IPHONE_DONE" in r for r in v["reasons"])
    assert any("ended after" in r for r in v["reasons"])


def test_frozen_state_is_a_hang() -> None:
    samples = run()
    for s in samples[50:53]:
        s["state_uptime_s"] = 260.0
    v = sv.crash_verdict(samples, fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)
    assert v["pass"] is False
    assert any("stopped updating" in r for r in v["reasons"])


def test_host_errors_fail() -> None:
    samples = run()
    samples[-1]["errors"] = 2
    v = sv.crash_verdict(samples, fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)
    assert v["pass"] is False
    assert any("2 errors" in r for r in v["reasons"])


def test_session_drop_and_new_session_fail() -> None:
    samples = run()
    samples[40]["session_id"] = None
    v = sv.crash_verdict(samples, fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)
    assert v["pass"] is False
    assert any("session dropped" in r for r in v["reasons"])
    samples = run()
    for s in samples[60:]:
        s["session_id"] = 8
    v = sv.crash_verdict(samples, fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)
    assert v["sessions"] == 2
    assert v["pass"] is False


def test_session_start_and_end_outside_the_samples_are_not_drops() -> None:
    samples = run()
    samples[0]["session_id"] = None
    samples[-1]["session_id"] = None
    assert sv.crash_verdict(samples, fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)["pass"] is True


def test_no_samples_fails() -> None:
    v = sv.crash_verdict([], fake_exit=0, fake_done=FAKE_DONE, duration_s=600.0)
    assert v["pass"] is False


# --- latency ---


def test_bounded_latency_passes() -> None:
    v = sv.latency_verdict(run(), warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)
    assert v["pass"] is True
    assert v["pose_leg_p95_max_ms"] == 22.0
    assert v["frame_p95_max_ms"] == 45.0
    assert v["stalls"] == 0
    assert v["m2p"] == "not measured"


def test_pose_leg_over_limit_after_warm_up_fails() -> None:
    samples = run()
    samples[90]["pose_leg_p95_ms"] = 31.0
    v = sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)
    assert v["pass"] is False
    assert any("pose leg p95 31.0 ms" in r for r in v["reasons"])


def test_latency_during_warm_up_is_ignored() -> None:
    samples = run()
    samples[2]["pose_leg_p95_ms"] = 80.0
    samples[2]["frame_p95_ms"] = 400.0
    assert sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)["pass"] is True


def test_frame_path_over_limit_fails() -> None:
    samples = run()
    samples[-1]["frame_p95_ms"] = 150.0
    v = sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)
    assert v["pass"] is False
    assert v["frame_p95_max_ms"] == 150.0


def test_stalled_stream_or_poses_fail() -> None:
    samples = run()
    samples[70]["video_sent"] = samples[69]["video_sent"]
    v = sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)
    assert v["pass"] is False
    assert v["stalls"] == 1
    samples = run()
    samples[70]["applied_seq"] = samples[69]["applied_seq"]
    assert sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)["pass"] is False


def test_without_video_only_poses_are_judged() -> None:
    samples = run(video_sent=None, frame_p95_ms=None)
    v = sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None, video=False)
    assert v["pass"] is True
    assert v["frame_p95_max_ms"] is None
    assert v["video"] is False
    assert sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)["pass"] is False
    samples[70]["applied_seq"] = samples[69]["applied_seq"]
    assert sv.latency_verdict(samples, warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None, video=False)["pass"] is False


def test_missing_latency_fails() -> None:
    v = sv.latency_verdict(run(pose_leg_p95_ms=None), warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)
    assert v["pass"] is False
    assert any("no pose leg" in r for r in v["reasons"])
    assert sv.latency_verdict([], warmup_s=60.0, limits=LIMITS, m2p_p95_ms=None)["pass"] is False


def test_measured_m2p_is_checked() -> None:
    assert sv.latency_verdict(run(), warmup_s=60.0, limits=LIMITS, m2p_p95_ms=90.0)["pass"] is True
    v = sv.latency_verdict(run(), warmup_s=60.0, limits=LIMITS, m2p_p95_ms=130.0)
    assert v["pass"] is False
    assert v["m2p"] == 130.0


# --- fake iPhone output, platform, report ---


def test_parse_fake_done_takes_the_last_line() -> None:
    text = (
        "FAKE_IPHONE_PAIRED\n"
        "FAKE_IPHONE_DONE poses=1 video_frames=2\n"
        "noise\n"
        "FAKE_IPHONE_DONE session_id=9 poses=36000 video_frames=1200 video_lost=300 loss_pct=2 "
        "aspect=1.7777778 hfov_deg=unavailable camera=Camera\n"
    )
    done = sv.parse_fake_done(text)
    assert done is not None
    assert done["poses"] == 36000
    assert done["loss_pct"] == 2
    assert done["aspect"] == pytest.approx(1.7777778)
    assert done["hfov_deg"] == "unavailable"
    assert done["camera"] == "Camera"
    assert sv.parse_fake_done("FAKE_IPHONE_PAIRED\n") is None


@pytest.mark.parametrize(
    ("system", "machine", "tag"),
    [
        ("Darwin", "arm64", "macos-arm64"),
        ("Linux", "x86_64", "linux-x86_64"),
        ("Linux", "aarch64", "linux-arm64"),
        ("Windows", "AMD64", "windows-x86_64"),
    ],
)
def test_platform_tag(system: str, machine: str, tag: str) -> None:
    assert sv.platform_tag(system, machine) == tag


def test_default_out() -> None:
    out = sv.default_out(Path("/r"), "2026-09-28", "macos-arm64")
    assert out == Path("/r/reports/soak-2026-09-28-macos-arm64.json")


def test_verdicts_combine() -> None:
    verdicts = sv.verdicts(
        run(),
        warmup_s=60.0,
        duration_s=600.0,
        fake_exit=0,
        fake_done=FAKE_DONE,
        limits=LIMITS,
        m2p_p95_ms=None,
    )
    assert list(verdicts) == ["no_crash", "rss_bounded", "handles_bounded", "latency_bounded"]
    assert all(v["pass"] for v in verdicts.values())
    assert verdicts["rss_bounded"]["limit"]["unit"] == "MiB"
    json.dumps(verdicts)
    leaking = run()
    for i, s in enumerate(leaking):
        s["rss_kib"] = 800_000 + i * 1024
    verdicts = sv.verdicts(
        leaking, warmup_s=60.0, duration_s=600.0, fake_exit=0, fake_done=FAKE_DONE, limits=LIMITS, m2p_p95_ms=None
    )
    assert verdicts["rss_bounded"]["pass"] is False
    assert verdicts["handles_bounded"]["pass"] is True


def test_build_report() -> None:
    samples = run()
    results = sv.verdicts(
        samples, warmup_s=60.0, duration_s=600.0, fake_exit=0, fake_done=FAKE_DONE, limits=LIMITS, m2p_p95_ms=None
    )
    report = sv.build_report({"date": "2026-09-28", "platform": "macos-arm64"}, samples, results)
    assert report["kind"] == "vcam-soak"
    assert report["format"] == 1
    assert report["date"] == "2026-09-28"
    assert report["pass"] is True
    assert set(report["methods"]) == set(results)
    assert len(report["samples"]) == 120
    results["no_crash"] = {"pass": False, "reasons": ["x"]}
    assert sv.build_report({}, samples, results)["pass"] is False
