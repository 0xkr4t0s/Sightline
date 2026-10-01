"""tools/latency/merge_report.py: host + device latency reports → the M2P report (NFR-LAT-003/004)."""

import copy
import json
import sys
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import merge_report  # noqa: E402


def host_leg(p50: float, p95: float, p99: float, count: int = 100) -> dict[str, Any]:
    """A leg as core/latency.summarize writes it (histogram included)."""
    return {
        "count": count,
        "min": p50 / 2,
        "mean": p50,
        "p50": p50,
        "p95": p95,
        "p99": p99,
        "max": p99 + 1,
        "histogram": {"bin_ms": 0.5, "counts": [0] * 200, "underflow": 0, "overflow": 0},
    }


def device_leg(p50: float, p95: float, p99: float, count: int = 90) -> dict[str, Any]:
    """A leg as DeviceLatencyReport writes it."""
    return {"count": count, "p50": p50, "p95": p95, "p99": p99, "max": p99 + 2}


HOST = {
    "kind": "vcam-latency",
    "format": 2,
    "date": "2026-09-28T03:44:35+1000",
    "platform": "darwin-arm64",
    "blender": "5.2.2 LTS",
    "device_name": "Someone's iPhone",
    "poll_interval_s": 1 / 60,
    "clock": {"offset_ns": 86055224914063, "delay_ns": 98458, "jitter_ns": 45380, "samples": 8},
    "session_id": 2273144953,
    "poses_without_clock": 0,
    "poses_not_applied": 327,
    "frames_not_sampled": 4,
    "stream": {"width": 960, "height": 540, "quality": 70},
    "legs": {
        "pose_leg_ms": host_leg(8.0, 16.0, 17.0),
        "apply_ms": host_leg(0.07, 0.11, 0.24),
        "render_readback_ms": host_leg(2.0, 3.0, 9.0),
        "encode_ms": host_leg(37.0, 39.0, 41.0),
        "send_ms": host_leg(0.6, 0.7, 0.8),
    },
    "device_m2p_p95_ms": host_leg(112.0, 133.0, 198.0, count=43),
    "device_reports_not_measured": 0,
    "methods": {
        "pose_leg_ms": "pose method",
        "apply_ms": "apply method",
        "render_readback_ms": "render method",
        "encode_ms": "encode method",
        "send_ms": "send method",
        "device_m2p_p95_ms": "report method",
    },
}

DEVICE = {
    "kind": "vcam-latency-device",
    "format": 1,
    "date": "2026-09-27T17:44:38Z",
    "environment": "simulator",
    "session_id": 2273144953,
    "frames_not_presented": 1,
    "frames_without_capture_time": 2,
    "last_report_m2p_p95_ms": 112,
    "legs": {
        "receive_ms": device_leg(0.7, 1.7, 1.9),
        "decode_ms": device_leg(4.2, 5.7, 6.0),
        "display_ms": device_leg(0.9, 10.8, 16.4),
        "m2p_ms": device_leg(98.0, 112.0, 128.0),
    },
    "methods": {
        "clock": "clock method",
        "display_time": "MTLCommandBuffer.GPUEndTime (the simulator SDK has no MTLDrawable.presentedTime)",
        "receive_ms": "receive method",
        "decode_ms": "decode method",
        "display_ms": "display method",
        "m2p_ms": "m2p method",
        "m2p_p95_ms_report": "report method",
    },
}


def merged(host: dict[str, Any] | None = None, device: dict[str, Any] | None = None) -> dict[str, Any]:
    return merge_report.merge(
        HOST if host is None else host,
        DEVICE if device is None else device,
        date="2026-09-28",
        fps=30,
        duration_s=60.0,
        motion="orbit",
        notes=["debug wheel"],
    )


def test_every_leg_in_path_order_with_its_source_and_percentiles() -> None:
    report = merged()
    assert report["kind"] == "vcam-latency-m2p" and report["format"] == 1
    assert report["environment"] == "simulator"
    assert report["order"] == list(merge_report.ORDER)
    assert list(report["legs"]) == [
        "pose_leg_ms",
        "render_readback_ms",
        "encode_ms",
        "send_ms",
        "network_ms",
        "receive_ms",
        "decode_ms",
        "display_ms",
        "m2p_ms",
    ]
    assert report["legs"]["encode_ms"] == {
        "count": 100,
        "p50": 37.0,
        "p95": 39.0,
        "p99": 41.0,
        "max": 42.0,
        "source": "host",
    }
    assert report["legs"]["m2p_ms"] == {
        "count": 90,
        "p50": 98.0,
        "p95": 112.0,
        "p99": 128.0,
        "max": 130.0,
        "source": "device",
    }
    for name in report["order"]:
        leg = report["legs"][name]
        assert all(isinstance(leg[p], float) for p in ("p50", "p95", "p99")), name
        assert name in report["methods"], name


def test_network_leg_is_m2p_minus_the_contiguous_legs_without_send() -> None:
    network = merged()["legs"]["network_ms"]
    # p50: 98 - (8 + 2 + 37 + 0.7 + 4.2 + 0.9); send (0.6) overlaps receive and isn't subtracted.
    assert network["p50"] == pytest.approx(45.2)
    assert network["p95"] == pytest.approx(112.0 - (16.0 + 3.0 + 39.0 + 1.7 + 5.7 + 10.8))
    assert network["p99"] == pytest.approx(128.0 - (17.0 + 9.0 + 41.0 + 1.9 + 6.0 + 16.4))
    assert network["source"] == "derived" and network["count"] is None and network["clamped"] == []
    assert "clocks differ" in merged()["methods"]["network_ms"]


def test_network_leg_is_clamped_at_zero_where_percentiles_dont_add() -> None:
    device = copy.deepcopy(DEVICE)
    device["legs"]["m2p_ms"] = device_leg(98.0, 112.0, 80.0)
    network = merged(device=device)["legs"]["network_ms"]
    assert network["p99"] == 0.0
    assert network["clamped"] == ["p99"]
    assert network["p50"] > 0.0


def test_crosscheck_has_the_clock_one_way_time_and_the_video_reports() -> None:
    crosscheck = merged()["crosscheck"]
    assert crosscheck["clock_one_way_ms"] == pytest.approx(0.049)
    assert crosscheck["video_report_m2p_p95_ms"]["p95"] == 133.0
    assert crosscheck["video_report_m2p_p95_ms"]["count"] == 43


def test_simulator_verdict_meets_and_is_labelled_simulator_only() -> None:
    verdict = merged()["verdict"]
    assert verdict["requirement"] == "NFR-LAT-003"
    assert verdict["meets"] is True
    assert verdict["m2p_p95_ms"] == 112.0
    assert verdict["limit_m2p_p95_ms"] == 120.0
    assert verdict["stream"] == "960x540"
    assert verdict["environment"] == "simulator"
    assert "simulator only" in verdict["scope"]
    assert "GPUEndTime" in verdict["scope"] and "lower bound" in verdict["scope"]


def test_verdict_fails_above_120_ms() -> None:
    device = copy.deepcopy(DEVICE)
    device["legs"]["m2p_ms"] = device_leg(110.0, 120.5, 140.0)
    verdict = merged(device=device)["verdict"]
    assert verdict["meets"] is False
    assert verdict["reason"] == "M2P p95 120.5 ms > 120.0 ms"


def test_verdict_at_exactly_120_ms_meets() -> None:
    device = copy.deepcopy(DEVICE)
    device["legs"]["m2p_ms"] = device_leg(110.0, 120.0, 140.0)
    assert merged(device=device)["verdict"]["meets"] is True


def test_verdict_is_only_judged_at_960x540() -> None:
    host = copy.deepcopy(HOST)
    host["stream"] = {"width": 640, "height": 360, "quality": 70}
    verdict = merged(host=host)["verdict"]
    assert verdict["meets"] is None
    assert "960x540" in verdict["reason"]
    host.pop("stream")
    report = merged(host=host)
    assert report["stream"] is None and report["verdict"]["meets"] is None


def test_device_run_has_no_simulator_scope() -> None:
    device = copy.deepcopy(DEVICE)
    device["environment"] = "device"
    report = merged(device=device)
    assert report["environment"] == "device"
    assert "scope" not in report["verdict"]


def test_missing_device_leg_gives_null_not_a_crash() -> None:
    device = copy.deepcopy(DEVICE)
    device["legs"]["m2p_ms"] = None
    report = merged(device=device)
    assert report["legs"]["m2p_ms"] is None
    assert report["legs"]["network_ms"] is None
    assert report["verdict"]["meets"] is None
    assert report["verdict"]["reason"] == "no M2P samples in the device report"


def test_missing_host_leg_gives_null_and_no_network_leg() -> None:
    host = copy.deepcopy(HOST)
    del host["legs"]["encode_ms"]
    host["legs"]["render_readback_ms"] = {"count": 3}  # incomplete summary
    report = merged(host=host)
    assert report["legs"]["encode_ms"] is None
    assert report["legs"]["render_readback_ms"] is None
    assert report["legs"]["network_ms"] is None
    assert report["verdict"]["meets"] is True


def test_reports_without_legs_or_methods_still_merge() -> None:
    host = {k: v for k, v in HOST.items() if k not in ("legs", "methods", "clock", "device_m2p_p95_ms")}
    device = {k: v for k, v in DEVICE.items() if k not in ("legs", "methods")}
    report = merged(host=host, device=device)
    assert all(leg is None for leg in report["legs"].values())
    assert report["crosscheck"]["clock_one_way_ms"] is None
    assert report["methods"]["encode_ms"] == "host: no method in the host report"
    assert report["methods"]["m2p_ms"] == "device: no method in the device report"


def test_methods_carry_both_reports_and_the_display_time_source() -> None:
    methods = merged()["methods"]
    assert methods["encode_ms"] == "host: encode method"
    assert methods["m2p_ms"] == "device: m2p method"
    assert "GPUEndTime" in methods["display_time"]
    assert methods["device_clock"] == "device: clock method"
    assert "upper edge" in methods["percentiles"]


def test_no_device_name_and_the_run_details_are_kept() -> None:
    report = merged()
    assert "Someone" not in json.dumps(report)
    assert report["run"]["session_id"] == 2273144953
    assert report["run"]["duration_s"] == 60.0
    assert report["run"]["motion"] == "orbit"
    assert report["stream"] == {"width": 960, "height": 540, "quality": 70, "codec": "JPEG", "fps_cap": 30}
    assert report["counts"]["frames_not_presented"] == 1
    assert report["counts"]["frames_not_sampled"] == 4
    assert report["notes"] == ["debug wheel"]
    assert any("presentedTime" in item for item in report["needs_owner"])
    assert any("Wi-Fi" in item for item in report["needs_owner"])


@pytest.mark.parametrize(
    ("which", "change"),
    [
        ("host", {"kind": "vcam-latency-device"}),
        ("host", {"format": 1}),
        ("device", {"kind": "vcam-latency"}),
        ("device", {"format": 2}),
    ],
)
def test_rejects_the_wrong_report(which: str, change: dict[str, Any]) -> None:
    host, device = dict(HOST), dict(DEVICE)
    (host if which == "host" else device).update(change)
    with pytest.raises(merge_report.ReportError, match=which):
        merged(host=host, device=device)


def test_rejects_reports_from_different_sessions() -> None:
    device = dict(DEVICE, session_id=1)
    with pytest.raises(merge_report.ReportError, match="different sessions"):
        merged(device=device)


def test_cli_writes_the_report(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    host_path, device_path = tmp_path / "host.json", tmp_path / "device.json"
    host_path.write_text(json.dumps(HOST), encoding="utf-8")
    device_path.write_text(json.dumps(DEVICE), encoding="utf-8")
    out = tmp_path / "out" / "latency.json"
    argv = ["--host", str(host_path), "--device", str(device_path), "--out", str(out), "--date", "2026-09-28"]
    assert merge_report.main([*argv, "--fps", "30", "--note", "a", "--note", "b"]) == 0
    report = json.loads(out.read_text(encoding="utf-8"))
    assert report["verdict"]["meets"] is True
    assert report["stream"]["fps_cap"] == 30
    assert report["notes"] == ["a", "b"]
    assert "M2P p95 112.0 ms, stream 960x540, meets True (simulator)" in capsys.readouterr().out


def test_cli_reports_a_bad_input_instead_of_raising(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    host_path, device_path = tmp_path / "host.json", tmp_path / "device.json"
    host_path.write_text(json.dumps(HOST), encoding="utf-8")
    device_path.write_text("[]", encoding="utf-8")
    argv = ["--host", str(host_path), "--device", str(device_path), "--out", str(tmp_path / "o.json")]
    assert merge_report.main(argv) == 2
    assert merge_report.main([*argv[:3], str(tmp_path / "missing.json"), *argv[4:]]) == 2
    assert "merge_report:" in capsys.readouterr().err
    assert not (tmp_path / "o.json").exists()


def test_default_output_name_has_the_date_and_environment() -> None:
    out = merge_report.default_out("2026-09-28", "simulator")
    assert out.name == "latency-2026-09-28-simulator.json"
    assert out.parent.name == "reports"
