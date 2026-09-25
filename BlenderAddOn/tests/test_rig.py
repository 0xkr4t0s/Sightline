# SPDX-License-Identifier: GPL-3.0-or-later
"""Rig math and control merging against the golden vectors (task 1.3.2a; NFR-QA-003)."""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.rig import Controls, heading, local_pose, zero_from_pose  # noqa: E402

TESTDATA = Path(__file__).resolve().parents[2] / "testdata"
CASES = json.loads((TESTDATA / "rig" / "rig_cases.json").read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_local_pose_matches_vectors(case):
    zero = None
    if case["zero_pose"] is not None:
        zp = case["zero_pose"]
        zero = zero_from_pose(zp["position"], zp["orientation"])
        assert heading(zp["orientation"]) == pytest.approx(case["zero_yaw"], abs=1e-9)
    p, q = local_pose(case["position"], case["orientation"], zero, case["motion_scale"], case["lock_flags"])
    assert p == pytest.approx(case["expected_position"], abs=1e-9)
    dot = sum(a * b for a, b in zip(q, case["expected_orientation"]))
    assert abs(dot) == pytest.approx(1.0, abs=1e-9), (q, case["expected_orientation"])


def test_set_origin_follows_the_shared_origin_epoch_vector():
    vectors = json.loads((TESTDATA / "vcp" / "freshness.json").read_text(encoding="utf-8"))
    seq = next(s for s in vectors["sequences"] if s["message"].startswith("CONTROL_STATE.origin_epoch"))
    controls, resets = Controls(), []
    for i, epoch in enumerate(seq["input"]):
        _, set_origin = controls.update({"state_seq": i + 1, "motion_scale": None, "lock_flags": None,
                                         "origin_epoch": epoch})
        if set_origin:
            resets.append(i)
    assert resets == seq["resets_at_index"]


def test_controls_keep_absent_fields_and_ignore_stale_states():
    c = Controls()
    assert c.update({"state_seq": 1, "motion_scale": 10.0, "lock_flags": 3, "origin_epoch": 0}) == (True, False)
    assert c.update({"state_seq": 2, "motion_scale": None, "lock_flags": None, "origin_epoch": None}) == (True, False)
    assert (c.motion_scale, c.lock_flags, c.origin_epoch) == (10.0, 3, 0)
    assert c.update({"state_seq": 2, "motion_scale": 1.0, "lock_flags": 0, "origin_epoch": 5}) == (False, False)
    assert c.update(None) == (False, False)
    assert (c.state_seq, c.motion_scale) == (2, 10.0)
