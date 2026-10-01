"""Invariants of the take sidecar and resample vectors (testdata/take/, docs/takes-jsonl.md).

They re-derive the rules from the sidecar's own lines, so a wrong generator or a hand-edited
vector fails here even if the two files still agree with each other.
"""

import json
import math
import struct
from fractions import Fraction
from pathlib import Path

import pytest

DATA = Path(__file__).resolve().parents[2] / "testdata" / "take"
POSE_KEYS = {"t", "seg", "seq", "cap", "rx", "p", "q", "trk", "fl", "late"}
KNOWN_KINDS = {"take", "seg", "pose", "ctl", "applied", "clock", "frame", "end"}
TOL = 1e-6


def f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


@pytest.fixture(scope="module")
def lines() -> list[dict]:
    text = (DATA / "sidecar_v1.jsonl").read_bytes().decode("utf-8")
    assert text.endswith("\n") and "\r" not in text
    return [json.loads(line, parse_float=lambda tok: f32(float(tok))) for line in text.split("\n")[:-1]]


@pytest.fixture(scope="module")
def poses(lines: list[dict]) -> list[dict]:
    return [x for x in lines if x["t"] == "pose"]


def first_arrivals(poses: list[dict]) -> list[dict]:
    """Duplicated (seg, seq) keep the first arrival; the order of `poses` is kept."""
    first: dict[tuple[int, int], dict] = {}
    for x in poses:
        first.setdefault((x["seg"], x["seq"]), x)
    return list(first.values())


@pytest.fixture(scope="module")
def by_cap(poses: list[dict]) -> list[dict]:
    return sorted(first_arrivals(poses), key=lambda x: (x["seg"], x["cap"]))


def dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b, strict=True))


def slerp(a: list[float], b: list[float], w: float, *, shortest: bool = True) -> list[float]:
    d = dot(a, b)
    if shortest and d < 0:
        b, d = [-x for x in b], -d
    if 1 - d < 1e-12:
        q = [x + (y - x) * w for x, y in zip(a, b, strict=True)]
    else:
        th = math.acos(min(d, 1.0))
        ka, kb = math.sin((1 - w) * th) / math.sin(th), math.sin(w * th) / math.sin(th)
        q = [ka * x + kb * y for x, y in zip(a, b, strict=True)]
    n = math.hypot(*q)
    return [c / n for c in q]


def predict(samples: list[dict], t: int, *, lerp_p: bool = True, shortest: bool = True) -> list[float]:
    """p and q of an interp frame at device time t from the pair that brackets it in `samples`' order."""
    k = max(i for i, s in enumerate(samples) if s["cap"] <= t)
    a, b = samples[k], samples[k + 1]
    w = (t - a["cap"]) / (b["cap"] - a["cap"])
    p = [x + (y - x) * w for x, y in zip(a["p"], b["p"], strict=True)] if lerp_p else b["p"]
    return [*p, *slerp(a["q"], b["q"], w, shortest=shortest)]


def mismatches(cases: list[dict], samples: list[dict], **rules: bool) -> int:
    """How many interp frames of the vectors a resampler with these `samples` and `rules` gets wrong."""
    wrong = 0
    for c in cases:
        for fr in (f for f in c["frames"] if f["source"] == "interp"):
            try:
                want = predict(samples, fr["t_dev_ns"], **rules)
            except (ValueError, IndexError):
                wrong += 1
                continue
            wrong += any(abs(x - y) > TOL for x, y in zip(want, [*fr["p"], *fr["q"]], strict=True))
    return wrong


@pytest.fixture(scope="module")
def cases() -> list[dict]:
    doc = json.loads((DATA / "resample_v1.json").read_text())
    assert doc["tolerance"] == TOL and doc["input"] == "take/sidecar_v1.jsonl"
    return doc["cases"]


def case(cases: list[dict], name: str) -> dict:
    return next(c for c in cases if c["name"] == name)


def test_take_frames_the_file_and_pose_fields_are_exact_f32(lines: list[dict], poses: list[dict]) -> None:
    assert lines[0]["t"] == "take" and lines[0]["v"] == 1
    assert lines[1]["t"] == "seg" and lines[-1]["t"] == "end"
    assert set(lines[1]) == {"t", "seg", "session_id", "start_host_ns", "theta_clock_ns", "theta_hat_ns"}
    assert lines[1]["start_host_ns"] == lines[0]["start_host_ns"]
    for x in poses:
        assert set(x) == POSE_KEYS and x["late"] in (0, 1) and len(x["p"]) == 3 and len(x["q"]) == 4
        assert abs(math.hypot(*x["q"]) - 1) < 1e-6


def test_f32_fields_are_the_shortest_decimal_that_round_trips() -> None:
    text = (DATA / "sidecar_v1.jsonl").read_text()
    tokens = [tok for line in text.splitlines() for tok in _float_tokens(line)]
    assert len(tokens) > 900
    for tok in tokens:
        value = f32(float(tok))
        digits = next(n for n in range(1, 10) if f32(float(f"{value:.{n}g}")) == value)
        assert float(tok) == float(f"{value:.{digits}g}"), tok
        assert "." in tok or "e" in tok  # a float literal, never an integer


def _float_tokens(line: str) -> list[str]:
    found: list[str] = []
    json.loads(line, parse_float=lambda tok: found.append(tok) or 0.0)
    return found


def test_end_counts_match_the_lines(lines: list[dict], poses: list[dict]) -> None:
    end = lines[-1]
    assert (end["poses"], end["late"], end["truncated"]) == (len(poses), sum(x["late"] for x in poses), False)
    assert end["dur_ns"] > 0 and max(x["rx"] for x in poses) - lines[0]["start_host_ns"] < end["dur_ns"]
    assert [x["rx"] for x in lines if "rx" in x] == sorted(x["rx"] for x in lines if "rx" in x)


def test_take_line_records_the_rig_state_at_record_start(lines: list[dict]) -> None:
    start = lines[0]["applied_start"]
    assert set(start) == {"zero", "motion_scale", "lock_flags", "lens"}
    assert set(start["zero"]) == {"p", "yaw"} and len(start["zero"]["p"]) == 3
    assert set(start["lens"]) == {"lens_mm", "focus_distance_m", "fstop", "dof_on"}
    assert start["motion_scale"] != 1.0 and start["lock_flags"] != 0  # not the defaults a reader might assume
    assert "zero_start" not in lines[0]


def test_one_late_pose_one_duplicate_and_derived_gaps(poses: list[dict], by_cap: list[dict]) -> None:
    late = [x for x in poses if x["late"]]
    assert [x["seq"] for x in late] == [33]
    assert max(x["seq"] for x in poses if x["rx"] < late[0]["rx"]) == 34  # a higher seq arrived first
    dup = [s for s in {x["seq"] for x in poses} if sum(x["seq"] == s for x in poses) > 1]
    assert dup == [10] and len(by_cap) == len(poses) - 1
    first, second = (x for x in poses if x["seq"] == 10)
    assert first["cap"] == second["cap"] and first["rx"] < second["rx"] and first["p"] != second["p"]
    assert not second["late"]  # it repeats the newest seq; nothing higher had arrived
    assert next(x for x in by_cap if x["seq"] == 10) is first
    seqs = {x["seq"] for x in poses}
    assert sorted(set(range(1, max(seqs) + 1)) - seqs) == list(range(40, 56))  # derived from seq, never stored


def test_poses_move_and_the_hard_cases_sit_where_they_change(poses: list[dict], by_cap: list[dict]) -> None:
    assert all(a["p"] != b["p"] for a, b in zip(by_cap, by_cap[1:], strict=False))  # position changes every pose
    i = next(k for k, x in enumerate(by_cap) if x["late"])  # the late pose's capture-order neighbours differ
    before, late, after = by_cap[i - 1], by_cap[i], by_cap[i + 1]
    assert (before["seq"], after["seq"]) == (32, 34) and late["rx"] > after["rx"]
    assert (
        len({tuple(x["p"]) for x in (before, late, after)}) == len({tuple(x["q"]) for x in (before, late, after)}) == 3
    )
    negative = [b["seq"] for a, b in zip(by_cap, by_cap[1:], strict=False) if dot(a["q"], b["q"]) < 0]
    assert negative == [60, 61]  # the stored -q is the shortest-arc negation, entering and leaving it
    assert next(x for x in by_cap if x["seq"] == 60)["q"][3] < 0


def test_readers_skip_unknown_kinds_and_keys(lines: list[dict]) -> None:
    unknown = [x for x in lines if x["t"] not in KNOWN_KINDS]
    assert [x["t"] for x in unknown] == ["x_future"]
    counted = sum(1 for x in lines if x["t"] == "pose")
    assert counted == lines[-1]["poses"]
    assert all(set(x) >= {"rx"} for x in lines if x["t"] in ("ctl", "clock"))


def test_applied_lines_key_by_pose_seq_or_host_time(lines: list[dict], poses: list[dict]) -> None:
    applied = [x for x in lines if x["t"] == "applied"]
    assert {x["kind"] for x in applied} == {"zero", "scale", "lens"}
    for x in applied:
        assert ("pose_seq" in x) != ("host_ns" in x) and ("seg" in x) == ("pose_seq" in x)
    ctl = next(i for i, x in enumerate(lines) if x["t"] == "ctl")
    scale = next(i for i, x in enumerate(lines) if x.get("kind") == "scale")
    assert (
        scale > ctl
        and lines[scale]["motion_scale"] == lines[ctl]["motion_scale"] != lines[0]["applied_start"]["motion_scale"]
    )
    assert all("seg" in x for x in lines if x["t"] in ("ctl", "clock"))
    zero = next(x for x in applied if x["kind"] == "zero")
    assert zero["pose_seq"] in {p["seq"] for p in poses}
    assert lines.index(zero) > next(i for i, x in enumerate(lines) if x.get("seq") == zero["pose_seq"])


def test_theta_hat_and_grid_times(lines: list[dict], poses: list[dict], cases: list[dict]) -> None:
    head, seg = lines[0], lines[1]
    assert seg["theta_hat_ns"] == max(x["cap"] - x["rx"] for x in poses)
    for c in cases:
        want = seg["theta_hat_ns"] if c["theta_clock_ns"] is None else c["theta_clock_ns"]
        assert c["theta_ns"] == want
        if c["time_source"] != "grid":
            continue
        assert c["t0_dev_ns"] == head["start_host_ns"] + want
        for fr in c["frames"]:  # nearest ns, halves up
            exact = Fraction((fr["f"] - c["frame0"]) * c["fps_den"] * 10**9, c["fps_num"])
            assert fr["t_dev_ns"] == c["t0_dev_ns"] + math.floor(exact + Fraction(1, 2))
    assert case(cases, "theta_hat_24")["theta_clock_ns"] is None
    assert [c["theta_clock_ns"] for c in cases if c["name"] != "theta_hat_24"] == [seg["theta_clock_ns"]] * 5


def test_frames_increase_and_times_never_go_back(cases: list[dict]) -> None:
    for c in cases:
        frames = c["frames"]
        assert [f["f"] for f in frames] == list(range(c["frame0"], c["frame0"] + len(frames)))
        assert all(a["t_dev_ns"] <= b["t_dev_ns"] for a, b in zip(frames, frames[1:], strict=False))


def test_dropped_frame_playback_uses_first_note_and_interpolates_skipped(lines: list[dict], cases: list[dict]) -> None:
    notes = [(x["host_ns"], x["f"]) for x in lines if x["t"] == "frame"]
    shown = [f for _, f in notes]
    assert shown.count(5) == 2 and 9 not in shown
    c = case(cases, "frame_notes_24")
    t = {fr["f"]: fr["t_dev_ns"] for fr in c["frames"]}
    assert t[5] == next(h for h, f in notes if f == 5) + c["theta_ns"]
    assert t[8] < t[9] < t[10] and abs(2 * t[9] - t[8] - t[10]) <= 1
    assert max(t) == max(shown)


def test_held_gap_and_limited_spans_match_the_sidecar(by_cap: list[dict], cases: list[dict]) -> None:
    cap = {x["seq"]: x["cap"] for x in by_cap}
    last = by_cap[-1]["cap"]
    limited = {x["seq"] for x in by_cap if x["trk"] != 5}
    assert limited == set(range(90, 101))
    for c in cases:
        for fr in c["frames"]:
            t = fr["t_dev_ns"]
            in_gap = cap[39] < t < cap[56] and cap[56] - cap[39] > c["max_interp_gap_ns"]
            assert (fr["source"] == "held_gap") == (in_gap or t > last), (c["name"], fr)
            assert (fr["source"] == "limited") == (cap[89] < t < cap[101]), (c["name"], fr)
            assert (fr["trk"] != 5) == (fr["source"] == "limited")
    assert not [f for f in case(cases, "gap_500ms_24")["frames"] if f["source"] == "held_gap" and f["t_dev_ns"] < last]
    for c in cases:  # the take runs past its last pose, so frames after it hold it
        assert c["time_source"] != "grid" or any(f["t_dev_ns"] > last for f in c["frames"]), c["name"]


def test_every_frame_matches_its_neighbours(by_cap: list[dict], cases: list[dict]) -> None:
    caps = [x["cap"] for x in by_cap]
    seen = set()
    for c in cases:
        for fr in c["frames"]:
            t, seen = fr["t_dev_ns"], seen | {fr["source"]}
            i = max((k for k, v in enumerate(caps) if v <= t), default=-1)
            a = by_cap[max(i, 0)]
            if fr["source"] in ("exact", "before_first", "held_gap"):
                assert (fr["p"], fr["q"]) == (a["p"], a["q"]) and (fr["source"] != "exact" or caps[i] == t)
            elif fr["source"] == "limited":  # holds the last normal pose before the span
                held = max((x for x in by_cap[: i + 1] if x["trk"] == 5), key=lambda x: x["cap"])
                assert fr["p"] == held["p"] and fr["q"] == held["q"]
            else:
                b = by_cap[i + 1]
                assert caps[i] < t < caps[i + 1] and a["trk"] == b["trk"] == 5
                assert b["cap"] - a["cap"] <= c["max_interp_gap_ns"]
                want = predict(by_cap, t)  # the signed q, not just the same rotation
                assert all(abs(x - y) <= TOL for x, y in zip(want, [*fr["p"], *fr["q"]], strict=True))
            assert abs(math.hypot(*fr["q"]) - 1) < TOL
    assert seen == {"exact", "interp", "held_gap", "limited", "before_first"}


def test_the_vectors_catch_each_way_of_breaking_the_resample_rules(
    poses: list[dict], by_cap: list[dict], cases: list[dict]
) -> None:
    """A wrong resampler must fail on at least one frame, or the vectors can't pin its rule."""
    assert mismatches(cases, by_cap) == 0
    by_arrival = first_arrivals(poses)  # file order is arrival order
    last_wins = sorted({x["seq"]: x for x in poses}.values(), key=lambda x: x["cap"])
    wrong = {
        "ordered by arrival, not capture time": mismatches(cases, by_arrival),
        "position taken from b, not lerped": mismatches(cases, by_cap, lerp_p=False),
        "slerp without the shortest-arc negation": mismatches(cases, by_cap, shortest=False),
        "a duplicate replaces the first arrival": mismatches(cases, last_wins),
    }
    assert all(wrong.values()), wrong
