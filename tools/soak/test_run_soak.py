"""tools/soak/run_soak.py: the report's metadata (task 2.7; NFR-REL-003)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_soak as rs  # noqa: E402
import soak_verdict as sv  # noqa: E402


def meta_of(argv: list[str], tmp_path: Path) -> dict[str, object]:
    args = rs.parse_args(argv)
    soak = rs.Soak(args, "Linux", tmp_path)
    limits = sv.LatencyLimits(pose_leg_p95_ms=40.0, frame_p95_ms=sv.FRAME_P95_MS, m2p_p95_ms=sv.M2P_P95_MS)
    return rs.build(soak, args, 7, limits, {"host_stopped": True})


def test_build_defaults_to_the_local_debug_build(tmp_path: Path) -> None:
    report = meta_of(["--no-video"], tmp_path)
    assert report["build"] == rs.LOCAL_BUILD
    assert "debug" in rs.LOCAL_BUILD


def test_build_and_environment_come_from_the_command_line(tmp_path: Path) -> None:
    argv = ["--no-video", "--loss", "0", "--jitter", "0", "--build", "release wheel", "--environment", "ci"]
    report = meta_of([*argv, "--note", "tc netem"], tmp_path)
    assert report["build"] == "release wheel"
    assert report["environment"] == "ci"
    assert report["notes"] == ["tc netem"]
    assert report["impairment"] == {
        "loss_pct": 0.0,
        "jitter_ms": 0.0,
        "seed": 7,
        "method": "fake iPhone --loss/--jitter/--seed (native/vcam-fake-iphone/src/impair.rs)",
    }
