"""Wire-layout and sensor-math anchors for the T2 lens vectors, independent of the codec."""

import json
import math
import struct
from pathlib import Path

DATA = Path(__file__).resolve().parents[2] / "testdata"


def cases(name: str) -> list[dict]:
    return json.loads((DATA / name).read_text())["cases"]


def test_control_lens_groups_have_fixed_offsets() -> None:
    vectors = {v["name"]: v for v in cases("vcp/messages.json")}
    full = bytes.fromhex(vectors["control_state_lens_full"]["hex"])
    assert len(full) == 12 + 64 + 8
    payload = full[12:-8]
    assert struct.unpack_from("<I", payload, 4)[0] == 0x3FF
    assert struct.unpack_from("<fff", payload, 20) == (50.0, 4.0, struct.unpack("<f", struct.pack("<f", 2.8))[0])
    assert struct.unpack_from("<B", payload, 32) == (1,)
    assert struct.unpack_from("<ffH", payload, 36) == (0.25, 0.75, 12)
    assert struct.unpack_from("<ffBxHH", payload, 48) == (2.0, 8.0, 2, 1200, 7)
    assert len(bytes.fromhex(vectors["control_state_lens_partial"]["hex"])) == 12 + 24 + 8
    assert len(bytes.fromhex(vectors["control_state_lens_tap"]["hex"])) == 12 + 48 + 8
    assert len(bytes.fromhex(vectors["control_state_lens_rack"]["hex"])) == 12 + 64 + 8


def test_status_appends_applied_lens_after_name() -> None:
    status = next(v for v in cases("vcp/messages.json") if v["name"] == "status_applied_lens")
    payload = bytes.fromhex(status["hex"])[12:-8]
    assert payload[14] & 4
    name_length = payload[15]
    assert payload[16 : 16 + name_length] == b"Camera"
    block = payload[16 + name_length :]
    assert len(block) == 24
    assert struct.unpack("<fffBBHff", block) == (
        50.0,
        4.0,
        struct.unpack("<f", struct.pack("<f", 2.8))[0],
        1,
        0,
        0,
        36.0,
        1.5,
    )
    expected = status["fields"]["applied_lens"]
    assert math.isclose(expected["horizontal_fov_deg"], 39.597752709049864, abs_tol=1e-8)
    assert math.isclose(expected["equivalent_35mm_focal_mm"], 50 * 43.27 / math.hypot(36, 24), abs_tol=1e-8)


def test_lens_presets_derive_horizontal_fov_and_equivalent() -> None:
    vectors = cases("rig/lens_cases.json")
    assert {v["name"] for v in vectors} == {"super_35", "full_frame", "arri_alexa_35_open_gate", "custom"}
    for v in vectors:
        width, focal, aspect = v["sensor_width_mm"], v["lens_mm"], v["render_aspect"]
        diagonal = math.hypot(width, width / aspect)
        assert math.isclose(v["horizontal_fov_deg"], math.degrees(2 * math.atan(width / (2 * focal))), abs_tol=1e-5)
        assert math.isclose(v["equivalent_35mm_focal_mm"], focal * 43.27 / diagonal, abs_tol=1e-5)


def test_invalid_lens_vectors_cover_ranges_and_truncation() -> None:
    rejects = {v["name"]: v for v in cases("vcp/receive.json") if not v["accept"]}
    for name in (
        "lens_nan",
        "focus_zero",
        "fstop_zero",
        "dof_unknown",
        "tap_u_above_one",
        "tap_v_nan",
        "rack_a_zero",
        "rack_target_unknown",
        "rack_duration_too_long",
    ):
        assert f"control_{name}" in rejects
    for bit in range(4, 10):
        assert f"control_lens_bit_{bit}_short" in rejects
    assert "status_lens_short" in rejects
    assert "status_fit_unknown" in rejects
