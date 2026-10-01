#!/usr/bin/env python3
"""Soak the Blender host with an impaired fake iPhone and judge it (task 2.7; NFR-REL-003).

    tools/soak/run_soak.py [--duration 600] [--interval 5] [--warmup 60] [--loss 2] [--jitter 10]
        [--seed N] [--no-video] [--out PATH] [--date YYYY-MM-DD] [--environment local] [--build TEXT]
        [--note TEXT]

It starts the headless QA host (tools/mission/qa_blender.sh start → qa_host.py, streaming on,
127.0.0.1:47000), then runs the fake iPhone through `qa_blender.sh drive` with `--loss`,
`--jitter`, `--seed` and `--duration`, so it pairs, streams poses and controls, and receives the
viewfinder for the whole run. Every `--interval` seconds it samples Blender's RSS and open
handles (tools/soak/soak_probe.py: macOS ps/lsof, Linux /proc) and the host's state.json
(session, applied pose, frames sent, rolling latency p95, errors). At the end it saves the host's
latency report, stops the host and the fake iPhone, and writes
`reports/soak-<date>-<platform>.json` with the samples, the thresholds and four verdicts:
no_crash, rss_bounded, handles_bounded and latency_bounded (tools/soak/soak_verdict.py).

With `tc netem` on Linux (CI) pass `--loss 0 --jitter 0` and describe the impairment in
`--environment`/`--note`; `--pose-p95-limit` then sets the pose-leg limit (default 20 ms plus the
jitter). The `soak` job in .github/workflows/ci.yml does this. On a host without a GPU (CI
runners) pass `--no-video`: the host doesn't stream and the latency verdict judges the pose path
only. Run tools/mission/setup.sh first. It refuses to start while a QA host is running.
Exit status: 0 all verdicts pass, 1 a verdict failed, 2 the soak couldn't run.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import json
import os
import platform
import random
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from types import FrameType
from typing import IO, Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import soak_probe  # noqa: E402
import soak_verdict as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
QA_BLENDER = ROOT / "tools" / "mission" / "qa_blender.sh"
HOST_LEG_KEYS = ("count", "p50", "p95", "p99", "max")
# After the last sample: the fake iPhone's linger, BYE and the host's session teardown.
DRIVE_GRACE_S = 90.0
M2P_NOT_MEASURED = (
    "not measured: the fake iPhone sends VIDEO_REPORT m2p_p95_ms 0; device M2P comes from the "
    "simulator or a device (reports/latency-*-simulator.json, tools/latency/)"
)
LOCAL_BUILD = "debug vcam_native wheel and fake iPhone (tools/mission/setup.sh)"


def mission_dir() -> Path:
    return Path(os.environ.get("MISSION_DIR") or ROOT / ".mission")


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        with path.open(encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def qa(*args: str, timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
    """tools/mission/qa_blender.sh; its output can hold the pairing code, so callers don't echo it."""
    return subprocess.run([str(QA_BLENDER), *args], capture_output=True, text=True, timeout=timeout, check=False)


def port_free(port: int) -> bool:
    """Nothing is bound to 127.0.0.1:`port` over TCP or UDP any more."""
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        with socket.socket(socket.AF_INET, kind) as s:
            if kind == socket.SOCK_STREAM:
                # Lets the check ignore TIME_WAIT from closed control connections, not listeners.
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("127.0.0.1", port))
            except OSError:
                return False
    return True


def group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stop_group(proc: subprocess.Popen[Any]) -> None:
    """Stops `qa_blender.sh drive` and the fake iPhone it runs (one process group)."""
    for sig, wait in ((signal.SIGTERM, 5.0), (signal.SIGKILL, 5.0)):
        if not group_alive(proc.pid):
            break
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, sig)
        deadline = time.monotonic() + wait
        while group_alive(proc.pid) and time.monotonic() < deadline:
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=0.2)
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=1.0)


def host_legs(report: dict[str, Any] | None) -> dict[str, Any]:
    """count/p50/p95/p99/max of every leg of the host's latency report, histograms left out."""
    if report is None:
        return {}
    legs = report.get("legs") or {}
    out: dict[str, Any] = {}
    for name, leg in {**legs, "device_m2p_p95_ms": report.get("device_m2p_p95_ms")}.items():
        out[name] = None if not isinstance(leg, dict) else {k: leg.get(k) for k in HOST_LEG_KEYS}
    return out


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--duration", type=float, default=600.0, help="seconds the fake iPhone streams (default 600)")
    p.add_argument("--interval", type=float, default=5.0, help="seconds between samples (default 5)")
    p.add_argument("--warmup", type=float, default=60.0, help="seconds ignored by the growth/latency verdicts")
    p.add_argument("--loss", type=float, default=2.0, help="fake iPhone datagram loss in %% (default 2)")
    p.add_argument("--jitter", type=float, default=10.0, help="fake iPhone jitter in ms (default 10)")
    p.add_argument("--seed", type=int, help="impairment seed (default: random, recorded in the report)")
    p.add_argument("--no-video", action="store_true", help="host without the viewfinder stream (no GPU)")
    p.add_argument("--pose-p95-limit", type=float, help="pose-leg p95 limit in ms (default 20 + jitter)")
    p.add_argument("--frame-p95-limit", type=float, default=sv.FRAME_P95_MS, help="frame-path p95 limit in ms")
    p.add_argument("--out", type=Path, help="default reports/soak-<date>-<platform>.json")
    p.add_argument("--date", default=datetime.date.today().isoformat(), help="YYYY-MM-DD (default today)")
    p.add_argument("--environment", default="local", help="label for the report (default local)")
    p.add_argument("--build", default=LOCAL_BUILD, help="the wheel and fake iPhone build, for the report")
    p.add_argument("--note", action="append", default=[], help="a note for the report (repeatable)")
    return p.parse_args(argv)


def say(text: str) -> None:
    print(f"soak: {text}", flush=True)


def progress(s: dict[str, Any]) -> str:
    rss = "?" if s["rss_kib"] is None else f"{s['rss_kib'] / 1024:.0f} MiB"
    return (
        f"{s['t_s']:.0f} s: rss {rss}, handles {s['handles']}, pose p95 {s['pose_leg_p95_ms']} ms, "
        f"frame p95 {s['frame_p95_ms']} ms, sent {s['video_sent']}, lost {s['video_lost']}/{s['video_expected']}"
    )


class Soak:
    def __init__(self, args: argparse.Namespace, system: str, work: Path) -> None:
        self.args = args
        self.system = system
        self.work = work
        self.state_path = mission_dir() / "qa" / "state.json"
        self.pid: int | None = None
        self.port = 47000
        self.drive: subprocess.Popen[Any] | None = None
        self.samples: list[dict[str, Any]] = []
        self.fake_exit: int | None = None
        self.fake_done: dict[str, Any] | None = None
        self.host_report: dict[str, Any] | None = None
        self.blender_version: str | None = None

    def sample(self, t: float) -> dict[str, Any]:
        alive = soak_probe.pid_alive(self.pid)
        rss, handles = soak_probe.sample_process(self.pid, self.system) if alive and self.pid else (None, None)
        return sv.sample_from_state(t, alive, rss, handles, read_json(self.state_path) or {})

    def start_host(self) -> None:
        started = qa("start", *(["--no-video"] if self.args.no_video else []))
        host = read_json(mission_dir() / "qa" / "host.json") or {}
        if started.returncode != 0 or host.get("state") != "running":
            raise RuntimeError("the QA host did not start (tools/mission/qa_blender.sh logs)")
        self.pid = int(host["pid"])
        self.port = int(host.get("port") or 47000)
        self.blender_version = host.get("blender_version")

    def start_drive(self, seed: int, log: IO[str]) -> None:
        a = self.args
        cmd = [str(QA_BLENDER), "drive", "--loss", f"{a.loss:g}", "--jitter", f"{a.jitter:g}", "--seed", str(seed)]
        cmd += ["--duration", f"{a.duration:g}", "--linger", "1"]
        self.drive = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)

    def sample_loop(self) -> None:
        a, drive = self.args, self.drive
        assert drive is not None
        t0 = time.monotonic()
        next_t = a.interval
        while True:
            while time.monotonic() - t0 < next_t and drive.poll() is None:
                time.sleep(0.1)
            s = self.sample(time.monotonic() - t0)
            self.samples.append(s)
            if len(self.samples) % max(1, round(60 / a.interval)) == 0:
                say(progress(s))
            if not s["host_alive"] or drive.poll() is not None or next_t >= a.duration:
                return
            next_t += a.interval

    def finish_drive(self, log_path: Path) -> None:
        drive = self.drive
        assert drive is not None
        try:
            self.fake_exit = drive.wait(timeout=DRIVE_GRACE_S)
        except subprocess.TimeoutExpired:
            say("the fake iPhone didn't finish; stopping it")
            stop_group(drive)
            self.fake_exit = None
        self.fake_done = sv.parse_fake_done(log_path.read_text(encoding="utf-8", errors="replace"))

    def save_host_report(self) -> None:
        if not soak_probe.pid_alive(self.pid):
            return
        path = self.work / "latency-host.json"
        path.unlink(missing_ok=True)
        qa("cmd", json.dumps({"cmd": "latency_report", "path": str(path)}), "30")
        self.host_report = read_json(path)

    def cleanup(self) -> dict[str, bool]:
        if self.drive is not None:
            stop_group(self.drive)
        qa("stop", timeout=60.0)
        return {
            "host_stopped": not soak_probe.pid_alive(self.pid),
            "port_free": port_free(self.port),
            "fake_iphone_stopped": self.drive is None or not group_alive(self.drive.pid),
        }


def _raise_exit(signum: int, frame: FrameType | None) -> None:
    raise SystemExit(128 + signum)


def build(
    soak: Soak, args: argparse.Namespace, seed: int, limits: sv.LatencyLimits, cleanup: dict[str, bool]
) -> dict[str, Any]:
    legs = host_legs(soak.host_report)
    m2p = legs.get("device_m2p_p95_ms")
    m2p_p95 = m2p["p95"] if m2p else None
    results = sv.verdicts(
        soak.samples,
        warmup_s=args.warmup,
        duration_s=args.duration,
        fake_exit=soak.fake_exit,
        fake_done=soak.fake_done,
        limits=limits,
        m2p_p95_ms=m2p_p95,
        video=not args.no_video,
    )
    done = soak.fake_done or {}
    frames, lost = done.get("video_frames"), done.get("video_lost")
    last = soak.samples[-1] if soak.samples else {}
    meta = {
        "date": args.date,
        "platform": sv.platform_tag(soak.system, platform.machine()),
        "environment": args.environment,
        "blender_version": soak.blender_version,
        "build": args.build,
        "impairment": {
            "loss_pct": args.loss,
            "jitter_ms": args.jitter,
            "seed": seed,
            "method": "fake iPhone --loss/--jitter/--seed (native/vcam-fake-iphone/src/impair.rs)",
        },
        "video": not args.no_video,
        "duration_s": args.duration,
        "run_s": last.get("t_s"),
        "interval_s": args.interval,
        "warmup_s": args.warmup,
        "thresholds": {
            "rss": sv.RSS_LIMIT.as_dict(),
            "handles": sv.HANDLE_LIMIT.as_dict(),
            "latency": limits.as_dict(),
        },
        "latency": {
            "host_legs": legs,
            "m2p": M2P_NOT_MEASURED if m2p_p95 is None else m2p_p95,
            "video_frames_received": frames,
            "video_frames_lost": lost,
            "video_frame_loss": round(lost / (frames + lost), 4)
            if isinstance(frames, int) and isinstance(lost, int) and frames + lost
            else None,
            "final_quality": last.get("quality"),
            "final_resolution_drop": last.get("resolution_drop"),
        },
        "fake_iphone": {"exit": soak.fake_exit, "done": soak.fake_done},
        "cleanup": cleanup,
        "notes": args.note,
    }
    return sv.build_report(meta, soak.samples, results)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    system = platform.system()
    if system not in ("Darwin", "Linux"):
        print(f"run_soak: macOS and Linux only, not {system}", file=sys.stderr)
        return 2
    if qa("status").returncode == 0:
        print("run_soak: a QA host is running; stop it first (tools/mission/qa_blender.sh stop)", file=sys.stderr)
        return 2
    seed = args.seed if args.seed is not None else random.randrange(1, 2**31)
    limits = sv.LatencyLimits(
        pose_leg_p95_ms=args.pose_p95_limit or sv.POSE_LEG_P95_BASE_MS + args.jitter,
        frame_p95_ms=args.frame_p95_limit,
        m2p_p95_ms=sv.M2P_P95_MS,
    )
    work = mission_dir() / "soak"
    work.mkdir(parents=True, exist_ok=True)
    log_path = work / "drive.log"
    signal.signal(signal.SIGTERM, _raise_exit)
    soak = Soak(args, system, work)
    try:
        say(f"starting the QA host: {args.duration:g} s, {args.loss:g} % loss, {args.jitter:g} ms jitter, seed {seed}")
        soak.start_host()
        with log_path.open("w", encoding="utf-8") as log:
            soak.start_drive(seed, log)
            soak.sample_loop()
            soak.finish_drive(log_path)
        soak.save_host_report()
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        print(f"run_soak: {e}", file=sys.stderr)
        return 2
    finally:
        cleanup = soak.cleanup()
    report = build(soak, args, seed, limits, cleanup)
    out = args.out or sv.default_out(ROOT, args.date, report["platform"])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
    for name, v in report["verdicts"].items():
        say(f"{name}: {'pass' if v['pass'] else 'FAIL'} {v.get('reason') or '; '.join(v.get('reasons') or [])}")
    say(f"cleanup {cleanup}")
    say(f"wrote {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out.name}: pass={report['pass']}")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
