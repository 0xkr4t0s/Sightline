#!/usr/bin/env python3
"""Merge a host and a device latency report into one motion-to-photon report (task 2.6;
NFR-LAT-003, NFR-LAT-004).

    tools/latency/merge_report.py --host HOST.json --device DEVICE.json [--out OUT.json]
        [--date YYYY-MM-DD] [--fps 30] [--duration-s 60] [--motion orbit]

HOST.json is the add-on's Save Latency Report (`kind: vcam-latency`, format 2; the QA host's
`latency_report` command). DEVICE.json is the app's `latency-device.json` (`kind:
vcam-latency-device`, format 1; `tools/mission/qa_ios.sh latency`). The default output is
`reports/latency-<date>-<environment>.json`, with the environment ("simulator" or "device")
taken from the device report.

The report lists every leg of a viewfinder frame's path in order, each as count/p50/p95/p99/max
in ms, with the method behind it, and states the NFR-LAT-003 verdict: M2P p95 ≤ 120 ms at
960×540. The two devices' clocks differ, so the downlink network leg can't be timed directly; it
is derived (see `NETWORK_METHOD`). A missing leg gives `null` rather than an error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

KIND = "vcam-latency-m2p"
FORMAT = 1
HOST_KIND, HOST_FORMAT = "vcam-latency", 2
DEVICE_KIND, DEVICE_FORMAT = "vcam-latency-device", 1
# NFR-LAT-003 Stage A: motion-to-photon p95 ≤ 120 ms at 960×540 (SRS §5.1).
M2P_P95_LIMIT_MS = 120.0
VERDICT_STREAM = (960, 540)
PERCENTILES = ("p50", "p95", "p99")

# The frame's path in time order: (leg, source report, key in that report's legs).
HOST_LEGS = (
    ("pose_leg_ms", "pose_leg_ms"),
    ("render_readback_ms", "render_readback_ms"),
    ("encode_ms", "encode_ms"),
    ("send_ms", "send_ms"),
)
DEVICE_LEGS = (
    ("receive_ms", "receive_ms"),
    ("decode_ms", "decode_ms"),
    ("display_ms", "display_ms"),
    ("m2p_ms", "m2p_ms"),
)
ORDER = (
    "pose_leg_ms",
    "render_readback_ms",
    "encode_ms",
    "send_ms",
    "network_ms",
    "receive_ms",
    "decode_ms",
    "display_ms",
    "m2p_ms",
)
# Contiguous steps of M2P that the network residual subtracts. `send` is left out: the device
# reassembles (`receive`) while the host is still sending the frame's fragments, so the two overlap.
RESIDUAL_OF = ("pose_leg_ms", "render_readback_ms", "encode_ms", "receive_ms", "decode_ms", "display_ms")
NETWORK_METHOD = (
    "derived, not timed: the host and device clocks differ, so a fragment's flight time can't be "
    "read from either side. At each percentile q, network = M2P(q) - (pose_leg + render_readback "
    "+ encode + receive + decode + display)(q); send is not subtracted because it overlaps "
    "receive. Percentiles don't add, so this is an estimate, clamped at 0 (`clamped` lists where). "
    "The residual holds the downlink flight of the first fragment plus the host waits no leg "
    "times (apply -> the next render tick, draw -> readback on the following tick, readback -> "
    "encoder start), so it is an upper bound on the network time. `crosscheck.clock_one_way_ms` "
    "(half the CLOCK round trip, symmetric-path assumption) shows how much of it is flight."
)
PERCENTILE_METHOD = (
    "host legs: nearest rank over every sample; device legs: nearest rank, reported as the upper "
    "edge of the histogram bin (0.1 ms for receive/decode/display, 1 ms for M2P), so they never "
    "understate"
)


class ReportError(ValueError):
    """An input that isn't the expected report."""


def _check_kind(report: Mapping[str, Any], kind: str, fmt: int, what: str) -> None:
    if report.get("kind") != kind or report.get("format") != fmt:
        raise ReportError(
            f"{what} report: expected kind {kind!r} format {fmt}, "
            f"got kind {report.get('kind')!r} format {report.get('format')!r}"
        )


def _leg(summary: Any, source: str) -> dict[str, Any] | None:
    """count/p50/p95/p99/max of a leg summary from either report; None if missing or incomplete."""
    if not isinstance(summary, Mapping):
        return None
    try:
        leg: dict[str, Any] = {"count": int(summary["count"]), **{p: float(summary[p]) for p in PERCENTILES}}
        leg["max"] = float(summary["max"])
    except (KeyError, TypeError, ValueError):
        return None
    leg["source"] = source
    return leg


def network_residual(legs: Mapping[str, dict[str, Any] | None]) -> dict[str, Any] | None:
    """The derived network leg (`NETWORK_METHOD`); None unless M2P and every subtracted leg exist."""
    m2p = legs.get("m2p_ms")
    parts = [legs.get(name) for name in RESIDUAL_OF]
    if m2p is None or any(part is None for part in parts):
        return None
    leg: dict[str, Any] = {"count": None, "source": "derived"}
    clamped = []
    for p in PERCENTILES:
        value = m2p[p] - sum(part[p] for part in parts if part is not None)
        if value < 0.0:
            clamped.append(p)
            value = 0.0
        leg[p] = round(value, 3)
    leg["max"] = None
    leg["clamped"] = clamped
    return leg


def _stream(host: Mapping[str, Any], fps: int | None) -> dict[str, Any] | None:
    stream = host.get("stream")
    if not isinstance(stream, Mapping):
        return None
    return {
        "width": stream.get("width"),
        "height": stream.get("height"),
        "quality": stream.get("quality"),
        "codec": "JPEG",
        "fps_cap": fps,
    }


def verdict(m2p: Mapping[str, Any] | None, stream: Mapping[str, Any] | None, environment: str) -> dict[str, Any]:
    """NFR-LAT-003: M2P p95 ≤ 120 ms, judged only on a 960×540 stream; `meets` is None when it can't be judged."""
    size = None if stream is None else (stream.get("width"), stream.get("height"))
    result: dict[str, Any] = {
        "requirement": "NFR-LAT-003",
        "limit_m2p_p95_ms": M2P_P95_LIMIT_MS,
        "m2p_p95_ms": None if m2p is None else m2p["p95"],
        "stream": None if size is None else f"{size[0]}x{size[1]}",
        "environment": environment,
    }
    if m2p is None:
        result["meets"], result["reason"] = None, "no M2P samples in the device report"
    elif size != VERDICT_STREAM:
        result["meets"] = None
        result["reason"] = f"the limit applies at {VERDICT_STREAM[0]}x{VERDICT_STREAM[1]}; this run streamed {size}"
    else:
        result["meets"] = m2p["p95"] <= M2P_P95_LIMIT_MS
        result["reason"] = "M2P p95 {} ms {} {} ms".format(
            m2p["p95"], "<=" if result["meets"] else ">", M2P_P95_LIMIT_MS
        )
    if environment == "simulator":
        result["scope"] = (
            "simulator only: the iPhone simulator on the same Mac as Blender, over loopback. The display "
            "time is the command buffer's GPUEndTime (the simulator SDK has no presentedTime), a lower "
            "bound that leaves out the wait for the next display refresh. Says nothing about a real "
            "iPhone on Wi-Fi."
        )
    return result


def _crosscheck(host: Mapping[str, Any]) -> dict[str, Any]:
    clock = host.get("clock")
    delay_ns = clock.get("delay_ns") if isinstance(clock, Mapping) else None
    reports = _leg(host.get("device_m2p_p95_ms"), "host")
    return {
        "clock_one_way_ms": None if delay_ns is None else round(delay_ns / 2e6, 3),
        "clock_one_way_method": "half the round trip delay of the host's newest CLOCK estimate (vcp.md §6.3)",
        "video_report_m2p_p95_ms": reports,
        "video_report_method": "the VIDEO_REPORT.m2p_p95_ms values the host received (each the device's p95 "
        "over ~500 ms), summarised by the host",
    }


def _methods(host: Mapping[str, Any], device: Mapping[str, Any]) -> dict[str, str]:
    host_methods = host.get("methods") or {}
    device_methods = device.get("methods") or {}
    methods = {name: f"host: {host_methods.get(key, 'no method in the host report')}" for name, key in HOST_LEGS}
    methods["network_ms"] = NETWORK_METHOD
    for name, key in DEVICE_LEGS:
        methods[name] = f"device: {device_methods.get(key, 'no method in the device report')}"
    display_time = device_methods.get("display_time")
    if display_time is not None:
        methods["display_time"] = f"device: {display_time}"
    if device_methods.get("clock") is not None:
        methods["device_clock"] = f"device: {device_methods['clock']}"
    methods["percentiles"] = PERCENTILE_METHOD
    return methods


def merge(
    host: Mapping[str, Any],
    device: Mapping[str, Any],
    *,
    date: str,
    fps: int | None = None,
    duration_s: float | None = None,
    motion: str | None = None,
    notes: list[str] | None = None,
) -> dict[str, Any]:
    """The merged report. Raises ReportError for a wrong kind or reports from different sessions."""
    _check_kind(host, HOST_KIND, HOST_FORMAT, "host")
    _check_kind(device, DEVICE_KIND, DEVICE_FORMAT, "device")
    host_session, device_session = host.get("session_id"), device.get("session_id")
    if host_session is not None and device_session is not None and host_session != device_session:
        raise ReportError(f"the reports are from different sessions: host {host_session}, device {device_session}")
    environment = str(device.get("environment") or "unknown")
    host_legs = host.get("legs") or {}
    device_legs = device.get("legs") or {}
    legs: dict[str, dict[str, Any] | None] = {name: _leg(host_legs.get(key), "host") for name, key in HOST_LEGS}
    legs.update({name: _leg(device_legs.get(key), "device") for name, key in DEVICE_LEGS})
    legs["network_ms"] = network_residual(legs)
    stream = _stream(host, fps)
    return {
        "kind": KIND,
        "format": FORMAT,
        "date": date,
        "environment": environment,
        "requirements": ["NFR-LAT-003", "NFR-LAT-004"],
        "run": {
            "platform": host.get("platform"),
            "blender": host.get("blender"),
            "duration_s": duration_s,
            "motion": motion,
            "session_id": host_session if host_session is not None else device_session,
            "host_report_date": host.get("date"),
            "device_report_date": device.get("date"),
        },
        "stream": stream,
        "order": list(ORDER),
        "legs": {name: legs[name] for name in ORDER},
        "methods": _methods(host, device),
        "crosscheck": _crosscheck(host),
        "counts": {
            "poses_without_clock": host.get("poses_without_clock"),
            "poses_not_applied": host.get("poses_not_applied"),
            "frames_not_sampled": host.get("frames_not_sampled"),
            "frames_not_presented": device.get("frames_not_presented"),
            "frames_without_capture_time": device.get("frames_without_capture_time"),
        },
        "verdict": verdict(legs["m2p_ms"], stream, environment),
        "notes": list(notes or []),
        "needs_owner": [
            "M2P and every leg on a real iPhone over 5 GHz Wi-Fi (NFR-LAT-003, NFR-LAT-004)",
            "the display leg from MTLDrawable.presentedTime on a device (the simulator has only GPUEndTime)",
        ],
    }


def _load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ReportError(f"{path.name}: not a JSON object")
    return data


def default_out(date: str, environment: str) -> Path:
    return Path(__file__).resolve().parents[2] / "reports" / f"latency-{date}-{environment}.json"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", type=Path, required=True, help="host report (vcam-latency format 2)")
    parser.add_argument("--device", type=Path, required=True, help="device report (vcam-latency-device format 1)")
    parser.add_argument("--out", type=Path, help="default reports/latency-<date>-<environment>.json")
    parser.add_argument("--date", default=datetime.date.today().isoformat(), help="YYYY-MM-DD (default today)")
    parser.add_argument("--fps", type=int, help="the stream's frame-rate cap")
    parser.add_argument("--duration-s", type=float, help="how long the run streamed")
    parser.add_argument("--motion", help="the scripted motion (simulator QA mode)")
    parser.add_argument("--note", action="append", default=[], help="a note for the report (repeatable)")
    args = parser.parse_args(argv)
    try:
        report = merge(
            _load(args.host),
            _load(args.device),
            date=args.date,
            fps=args.fps,
            duration_s=args.duration_s,
            motion=args.motion,
            notes=args.note,
        )
    except (OSError, ValueError) as e:
        print(f"merge_report: {e}", file=sys.stderr)
        return 2
    out = args.out or default_out(args.date, report["environment"])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
    v, env = report["verdict"], report["environment"]
    print(f"{out.name}: M2P p95 {v['m2p_p95_ms']} ms, stream {v['stream']}, meets {v['meets']} ({env})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
