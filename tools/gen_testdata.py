# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the golden vectors in testdata/ (task 1.1.2; SRS NFR-QA-003, PR-004, DM-004).

This script is the reference implementation of docs/protocol/vcp.md (Draft 1). It uses only the
Python standard library. Before writing anything it checks itself against external anchors:

- SRP-6a against RFC 5054 Appendix B (SHA-1, 1024-bit group): k, x, v, A, B, u, premaster secret;
- HKDF against RFC 5869 test case 1;
- the RFC 5054 3072-bit group against the prime printed in RFC 5054 Appendix A (embedded below);
- the message bytes against the example hex blocks in docs/protocol/vcp.md §6 and §9.3;
- the coordinate vectors against hand-derived forward/up directions.

Usage:
    python3 tools/gen_testdata.py            # (re)write testdata/
    python3 tools/gen_testdata.py --check    # exit 1 if testdata/ differs from what would be written

File formats (all JSON is UTF-8, 2-space indented, keys sorted):

testdata/vcp/messages.json   valid messages. Each case: name, channel (udp|tcp), direction
                             (d2h|h2d), key (d2h|h2d|null), session_id, hex (whole message),
                             file (the same bytes as testdata/vcp/<file>), fields (decoded values).
testdata/vcp/receive.json    UDP receive-rule cases (vcp.md §4.3, §6). Each case: name, hex,
                             direction, accept (bool), rule (the §4.3 step or § that decides it);
                             accepted cases also carry fields.
testdata/vcp/freshness.json  stateful sequences: the seq/state_seq values fed in, in order, and
                             which ones the receiver applies.
testdata/vcp/clock_sync.json  host CLOCK estimation (vcp.md §6.3): requests and replies (with t4)
                             in order; each reply's verdict and the estimate after it.
testdata/vcp/pairing.json    one full SRP-6a pairing (vcp.md §9) with fixed secrets: every
                             intermediate value and every TCP message.
testdata/vcp/session.json    one session setup (vcp.md §10) from the pairing key above.
testdata/vcp/srp-rfc5054-appendix-b.json   the RFC 5054 vectors (SHA-1, 1024-bit).
testdata/coords/arkit_to_canonical.json    DM-004 cases (vcp.md §7).
testdata/rig/rig_cases.json   rig math (task 1.3.2a): device pose + Set-origin zero + motion scale + lock
                             flags -> the camera's local pose under VCam_Origin.
testdata/motion/scripted.json   fake-iPhone motion (task 1.2.7): canonical frames at rate_hz and the
                             named keyposes (frame index, position, orientation, matrix_world).
testdata/motion/scripted.bin    the same frames for vcam-fake-iphone: "VCMO", u16 version 1,
                             u16 rate_hz, u32 count, then count x (3 f32 position, 4 f32 x,y,z,w), LE.

Big integers are big-endian hex strings. Floats are JSON numbers; compare with the stated
tolerance. Quaternions are [x, y, z, w] with w >= 0 (q and -q are the same rotation).
"""

import argparse
import hashlib
import hmac
import json
import math
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "testdata"
SPEC = ROOT / "docs" / "protocol" / "vcp.md"

# --------------------------------------------------------------------------------------------
# RFC constants (transcribed from RFC 5054 Appendix A/B and RFC 5869 A.1)

N1024 = int(
    "EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576D674DF7496EA81D3383B4813"
    "D692C6E0E0D5D8E250B98BE48E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885"
    "C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3",
    16,
)
N3072 = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879"
    "8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B"
    "0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836"
    "1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804"
    "F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6"
    "955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64"
    "ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226"
    "1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"
    "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
    16,
)
G3072 = 5

RFC5054_B = {
    "I": "alice",
    "P": "password123",
    "s": "BEB25379D1A8581EB5A727673A2441EE",
    "k": "7556AA045AEF2CDD07ABAF0F665C3E818913186F",
    "x": "94B7555AABE9127CC58CCF4993DB6CF84D16C124",
    "v": "7E273DE8696FFC4F4E337D05B4B375BEB0DDE1569E8FA00A9886D8129BADA1F1822223CA1A605B530E379BA4"
    "729FDC59F105B4787E5186F5C671085A1447B52A48CF1970B4FB6F8400BBF4CEBFBB168152E08AB5EA53D15C"
    "1AFF87B2B9DA6E04E058AD51CC72BFC9033B564E26480D78E955A5E29E7AB245DB2BE315E2099AFB",
    "a": "60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393",
    "b": "E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20",
    "A": "61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E8903211C04692272D8B2D1A5358"
    "A2CF1B6E0BFCF99F921530EC8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF0"
    "6530E69F66615261EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B",
    "B": "BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652"
    "236F99D9B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F"
    "9C6059F388838E7A00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58",
    "u": "CE38B9593487DA98554ED47D70A7AE5F462EF019",
    "S": "B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E359B48220F7C4693C9AE12B0A"
    "6F67809F0876E2D013800D6C41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200"
    "210DCC1F10EB33943CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A",
}

# --------------------------------------------------------------------------------------------
# Primitives


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:length]


def i2b(n: int, length: int | None = None) -> bytes:
    """Big-endian bytes; minimal length unless `length` is given (then left-padded)."""
    size = length if length is not None else max(1, (n.bit_length() + 7) // 8)
    return n.to_bytes(size, "big")


def srp(N: int, g: int, H, I: bytes, P: bytes, s: bytes, a: int, b: int) -> dict:
    """SRP-6a exactly as vcp.md §9.2 / RFC 5054 (PAD = left-pad to len(N))."""
    n_len = (N.bit_length() + 7) // 8

    def pad(x: int) -> bytes:
        return i2b(x, n_len)

    def h_int(*parts: bytes) -> int:
        return int.from_bytes(H(b"".join(parts)).digest(), "big")

    k = h_int(i2b(N), pad(g))
    x = h_int(s, H(I + b":" + P).digest())
    v = pow(g, x, N)
    A = pow(g, a, N)
    B = (k * v + pow(g, b, N)) % N
    u = h_int(pad(A), pad(B))
    assert A % N and B % N and u, "illegal SRP value"
    S_client = pow((B - k * pow(g, x, N)) % N, a + u * x, N)
    S_server = pow((A * pow(v, u, N)) % N, b, N)
    assert S_client == S_server, "SRP premaster mismatch"
    return {"k": k, "x": x, "v": v, "A": A, "B": B, "u": u, "S": S_client, "pad": pad}


def hx(b: bytes) -> str:
    return b.hex()


def header(msg_type: int, session_id: int, payload: bytes) -> bytes:
    return b"VCP1" + struct.pack("<BBIH", 1, msg_type, session_id, len(payload))


def tag(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()[:8]


def udp(msg_type: int, session_id: int, payload: bytes, key: bytes) -> bytes:
    h = header(msg_type, session_id, payload)
    return h + payload + tag(key, h + payload)


def tcp(msg_type: int, payload: bytes) -> bytes:
    return header(msg_type, 0, payload) + payload


def str8(s: str) -> bytes:
    b = s.encode("utf-8")
    assert len(b) <= 255
    return bytes([len(b)]) + b


def f32(x: float) -> float:
    """Round-trip through binary32 so JSON shows exactly what is on the wire."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


# --------------------------------------------------------------------------------------------
# Message encoders (vcp.md §6, §9, §10)

SID = 0x1234ABCD
K_D2H = bytes(range(0x00, 0x20))  # vcp.md §11 example keys (test values only)
K_H2D = bytes(range(0x20, 0x40))
KEYS = {"d2h": K_D2H, "h2d": K_H2D}
TYPES = {"POSE": 0x01, "CONTROL_STATE": 0x02, "CLOCK": 0x03, "STATUS": 0x04}


def pose_payload(seq, t_ns, pos, quat, state, flags=0) -> bytes:
    return struct.pack("<IQ3f4fBB", seq, t_ns, *pos, *quat, state, flags)


def control_payload(state_seq, fields, scale, locks, epoch) -> bytes:
    return struct.pack("<IIfBBH", state_seq, fields, scale, locks, 0, epoch)


def clock_payload(mode, t1, t2, t3) -> bytes:
    return struct.pack("<B3xQQQ", mode, t1, t2, t3)


def status_payload(status_seq, pose_seq, ack, err, flags, name) -> bytes:
    return struct.pack("<IIIHB", status_seq, pose_seq, ack, err, flags) + str8(name)


def hello_payload(mode, device_id, nonce, name) -> bytes:
    return struct.pack("<BBBB", mode, 1, 1, 0) + device_id + nonce + str8(name)


def error_payload(code, message) -> bytes:
    return struct.pack("<HH", code, 0) + str8(message)


# --------------------------------------------------------------------------------------------
# Vector builders


def build_messages() -> tuple[dict, dict[str, bytes]]:
    s = math.sqrt(0.5)
    cases, files = [], {}

    def add(name, channel, direction, msg_type, payload, fields, description):
        if channel == "udp":
            data = udp(msg_type, SID, payload, KEYS[direction])
            key, sid = direction, SID
        else:
            data = tcp(msg_type, payload)
            key, sid = None, 0
        fname = f"{name}.bin"
        files[fname] = data
        cases.append(
            {
                "name": name,
                "description": description,
                "channel": channel,
                "direction": direction,
                "key": key,
                "session_id": sid,
                "type": msg_type,
                "hex": hx(data),
                "file": fname,
                "fields": fields,
            }
        )

    pos, quat = (0.5, -1.25, 1.6), (s, 0.0, 0.0, s)
    add("pose_normal", "udp", "d2h", 0x01, pose_payload(1, 1_000_000_000, pos, quat, 5),
        {"seq": 1, "capture_time_ns": 1_000_000_000, "position_m": [f32(v) for v in pos],
         "orientation": [f32(v) for v in quat], "tracking_state": 5, "flags": 0},
        "vcp.md §6.1 example")
    add("pose_limited_relocalizing", "udp", "d2h", 0x01,
        pose_payload(4_000_000_000, 123_456_789_012_345, (-3.0, 0.0, 12.75), (0.0, 0.0, 0.0, 1.0), 4),
        {"seq": 4_000_000_000, "capture_time_ns": 123_456_789_012_345,
         "position_m": [-3.0, 0.0, 12.75], "orientation": [0.0, 0.0, 0.0, 1.0],
         "tracking_state": 4, "flags": 0},
        "large seq and timestamp, identity orientation, limited(relocalizing)")
    add("control_state_full", "udp", "d2h", 0x02, control_payload(7, 0b111, 10.0, 0b010, 3),
        {"state_seq": 7, "fields": 7, "motion_scale": 10.0, "lock_flags": 2, "origin_epoch": 3},
        "vcp.md §6.2 example")
    add("control_state_epoch_only", "udp", "d2h", 0x02, control_payload(8, 0b100, 0.0, 0, 65535),
        {"state_seq": 8, "fields": 4, "motion_scale": 0.0, "lock_flags": 0, "origin_epoch": 65535},
        "only origin_epoch present; motion_scale/lock_flags bytes are present but must be ignored")
    add("clock_request", "udp", "h2d", 0x03, clock_payload(0, 5_000_000_000, 0, 0),
        {"mode": 0, "t1": 5_000_000_000, "t2": 0, "t3": 0}, "vcp.md §6.3 request example")
    add("clock_reply", "udp", "d2h", 0x03, clock_payload(1, 5_000_000_000, 1_000_400_000, 1_000_450_000),
        {"mode": 1, "t1": 5_000_000_000, "t2": 1_000_400_000, "t3": 1_000_450_000,
         "t4_host_on_receipt": 5_001_000_000, "expected_offset_ns": -4_000_075_000,
         "expected_delay_ns": 950_000},
        "vcp.md §6.3 reply example; offset/delay per the §6.3 formulas with the given t4")
    add("status_camera", "udp", "h2d", 0x04, status_payload(2, 1, 7, 0, 0b11, "Camera"),
        {"status_seq": 2, "applied_pose_seq": 1, "control_ack": 7, "error_code": 0, "flags": 3,
         "camera_name": "Camera"}, "vcp.md §6.4 example")
    add("status_no_camera_utf8", "udp", "h2d", 0x04, status_payload(3, 0, 0, 1, 0b01, "Kamera Ω"),
        {"status_seq": 3, "applied_pose_seq": 0, "control_ack": 0, "error_code": 1, "flags": 1,
         "camera_name": "Kamera Ω"}, "error 1 (no camera), non-ASCII name (str8 counts bytes)")
    dev = bytes.fromhex("00112233445566778899aabbccddeeff")
    add("hello_pair", "tcp", "d2h", 0x40, hello_payload(0, dev, b"\xa5" * 16, "iPhone"),
        {"mode": 0, "proto_min": 1, "proto_max": 1, "device_id": hx(dev), "nonce_d": "a5" * 16,
         "device_name": "iPhone"}, "vcp.md §9.3 example")
    add("error_not_paired", "tcp", "h2d", 0x4F, error_payload(3, "device not paired"),
        {"code": 3, "message": "device not paired"}, "vcp.md §11")
    return {"cases": cases, "float_tolerance": 0.0,
            "note": "floats in fields are the exact binary32 values on the wire"}, files


def build_receive() -> dict:
    s = math.sqrt(0.5)
    good_pose = pose_payload(1, 1_000_000_000, (0.5, -1.25, 1.6), (s, 0.0, 0.0, s), 5)
    good = udp(0x01, SID, good_pose, K_D2H)
    cases = []

    def case(name, data, accept, rule, direction="d2h", fields=None):
        c = {"name": name, "hex": hx(data), "direction": direction, "accept": accept, "rule": rule}
        if fields is not None:
            c["fields"] = fields
        cases.append(c)

    def reframe(payload=good_pose, msg_type=0x01, sid=SID, version=1, key=K_D2H, len_field=None,
                magic=b"VCP1"):
        h = magic + struct.pack("<BBIH", version, msg_type, sid,
                                len(payload) if len_field is None else len_field)
        return h + payload + tag(key, h + payload)

    case("valid_pose", good, True, "all", fields={"seq": 1})
    case("too_short_datagram", good[:19], False, "4.3.1")
    case("oversize_datagram", reframe(good_pose + bytes(1200 - 20 - len(good_pose) + 1)), False, "4.3.1")
    case("max_size_datagram_accepted", reframe(good_pose + bytes(1200 - 20 - len(good_pose))), True,
         "4.3.1 (1200 bytes is allowed; extra payload bytes ignored per §2)", fields={"seq": 1})
    case("bad_magic", reframe(magic=b"VCP2"), False, "4.3.2")
    case("unknown_version", reframe(version=2), False, "4.3.3")
    case("len_too_large", reframe(len_field=len(good_pose) + 1), False, "4.3.4")
    case("len_too_small", reframe(len_field=len(good_pose) - 1), False, "4.3.4")
    case("truncated_tag", good[:-1], False, "4.3.4")
    case("session_id_zero", reframe(sid=0), False, "4.3.5")
    case("wrong_session_id", reframe(sid=SID + 1), False, "4.3.5")
    flipped = bytearray(good)
    flipped[-1] ^= 0x01
    case("bad_tag", bytes(flipped), False, "4.3.6")
    body_flip = bytearray(good)
    body_flip[20] ^= 0x80
    case("payload_bit_flip", bytes(body_flip), False, "4.3.6")
    case("wrong_direction_key", reframe(key=K_H2D), False, "4.3.6 (reflected datagram)")
    case("unknown_type", reframe(msg_type=0x7E), False, "4.3.7")
    case("clock_request_from_device", udp(0x03, SID, clock_payload(0, 1, 0, 0), K_D2H), False,
         "4.3.7 (CLOCK mode 0 is host→device only)")
    case("pose_payload_short", reframe(payload=good_pose[:41]), False, "4.3.8")
    case("pose_payload_longer_accepted", reframe(payload=good_pose + b"\xee" * 6), True,
         "§2 forward compatibility (tail ignored)", fields={"seq": 1, "tracking_state": 5})
    case("pose_nan_position", udp(0x01, SID, pose_payload(2, 1, (math.nan, 0.0, 0.0), (0, 0, 0, 1), 5), K_D2H),
         False, "§6.1 non-finite")
    case("pose_inf_quat", udp(0x01, SID, pose_payload(2, 1, (0, 0, 0), (math.inf, 0, 0, 1), 5), K_D2H),
         False, "§6.1 non-finite")
    case("pose_quat_norm_1_2", udp(0x01, SID, pose_payload(2, 1, (0, 0, 0), (0, 0, 0, 1.2), 5), K_D2H),
         False, "§6.1 quaternion norm outside 0.9–1.1")
    case("pose_quat_norm_1_05_accepted", udp(0x01, SID, pose_payload(2, 1, (0, 0, 0), (0, 0, 0, 1.05), 5), K_D2H),
         True, "§6.1 (renormalised by the host)", fields={"seq": 2, "orientation_renormalised": [0.0, 0.0, 0.0, 1.0]})
    for scale in (0.0005, 1500.0, math.nan):
        case(f"control_scale_{str(scale).replace('.', '_')}",
             udp(0x02, SID, control_payload(1, 0b111, scale, 0, 0), K_D2H), False, "§6.2 motion_scale range")
    case("control_scale_absent_ignored", udp(0x02, SID, control_payload(1, 0b110, math.nan, 0, 0), K_D2H), True,
         "§6.2 (motion_scale not present, so its bytes are ignored)", fields={"state_seq": 1, "fields": 6})
    return {"receiver": {"session_id": SID, "k_d2h": hx(K_D2H), "k_h2d": hx(K_H2D),
                         "role": "host for direction d2h, device for h2d"},
            "cases": cases}


def build_freshness() -> dict:
    def newest(seq_in):
        applied, last = [], 0
        for v in seq_in:
            if v > last:
                applied.append(v)
                last = v
        return applied

    pose_in = [1, 2, 5, 3, 5, 6, 4, 7]
    control_in = [1, 1, 3, 2, 4, 4]
    return {
        "note": "Feed values in order within one session; 'applied' lists what the receiver uses (§6.1, §6.2, §6.4).",
        "sequences": [
            {"message": "POSE.seq", "input": pose_in, "applied": newest(pose_in)},
            {"message": "CONTROL_STATE.state_seq", "input": control_in, "applied": newest(control_in)},
            {"message": "STATUS.status_seq", "input": [2, 1, 3], "applied": newest([2, 1, 3])},
            {"message": "CONTROL_STATE.origin_epoch (reset when changed, including wrap)",
             "input": [3, 3, 4, 65535, 0, 0], "resets_at_index": [2, 3, 4]},
        ],
    }


def build_clock_sync() -> dict:
    """Reference for vcp.md §6.3 host estimation; the Rust ClockEstimator must match it."""
    outstanding_max, timeout, window_max = 4, 2_000_000_000, 8
    outstanding, window, events = [], [], []

    def tdiv2(x):  # Rust i128 division truncates toward zero
        return -((-x) // 2) if x < 0 else x // 2

    def estimate():
        if not window:
            return None
        best = min(reversed(window), key=lambda s: s[1])  # first minimum = newest
        sq = sum(min(abs(o - best[0]), 2**64 - 1) ** 2 for o, _ in window)
        return {"offset_ns": best[0], "delay_ns": best[1], "jitter_ns": math.isqrt(sq // len(window)),
                "samples": len(window)}

    def request(t1):
        if len(outstanding) == outstanding_max:
            outstanding.pop(0)
        outstanding.append(t1)
        events.append({"op": "request", "t1": t1})

    def reply(t1, t2, t3, t4, expect, note=""):
        offset, delay = tdiv2((t2 - t1) + (t3 - t4)), (t4 - t1) - (t3 - t2)
        if t1 not in outstanding:
            result = "unmatched"
        else:
            outstanding.remove(t1)
            if t4 < t1:
                result = "invalid"
            elif t4 - t1 >= timeout:
                result = "expired"
            elif t3 < t2 or delay < 0:
                result = "invalid"
            else:
                result = "accepted"
                if len(window) == window_max:
                    window.pop(0)
                window.append((offset, delay))
        assert result == expect, (note, result)
        e = {"op": "reply", "t1": t1, "t2": t2, "t3": t3, "t4": t4, "result": result,
             "estimate": estimate()}
        if note:
            e["note"] = note
        events.append(e)

    theta = -1_234_567_891  # device − host; odd, so some θ sums truncate toward zero

    def exchange(t1, up, proc, down, expect="accepted", note=""):
        t2 = t1 + up + theta
        request(t1)
        reply(t1, t2, t2 + proc, t1 + up + proc + down, expect, note)

    # (uplink, device processing, downlink) in ns: asymmetric paths shift θ by (up−down)/2.
    paths = [(3_000_001, 40_000, 2_000_000), (900_000, 50_000, 800_001), (7_000_000, 30_000, 1_000_000),
             (1_200_000, 60_000, 1_500_000), (2_500_000, 45_000, 2_600_003)]
    t = 10_000_000_000
    for up, proc, down in paths:
        exchange(t, up, proc, down)
        t += 1_000_000_000
    # Replay of the newest answered reply, still well inside 2 s: only consumption rejects it.
    dup = events[-1]
    reply(dup["t1"], dup["t2"], dup["t3"], dup["t4"] + 1_000_000, "unmatched",
          "duplicate reply to an answered request")
    reply(t + 123, 1, 2, t + 500, "unmatched", "t1 never requested")
    for i in range(5):  # five unanswered requests evict the first one
        request(t + i * 1_000_000_000)
    reply(t, t + theta, t + theta + 1, t + 4_500_000_000, "unmatched", "request evicted by four newer ones")
    last = t + 4_000_000_000
    reply(last, last + 1_000_000 + theta, last + 1_050_000 + theta, last + timeout, "expired",
          "arrived exactly 2 s after the request")
    t += 5_000_000_000
    request(t)
    reply(t, t + 5_000 + theta, t + 4_000 + theta, t + 20_000, "invalid", "t3 before t2")
    t += 1_000_000_000
    request(t)
    reply(t, t + 100 + theta, t + 2_000_100 + theta, t + 1_000_000, "invalid",
          "negative round trip (device processing longer than the round trip)")
    t += 1_000_000_000
    exchange(t, 1_999_000_000, 10_000, 900_000, "accepted", "just inside the 2 s limit")
    t += 1_000_000_000
    # Enough further samples to slide the lowest-delay sample (paths[1]) and the 2 s sample out of
    # the window. The last two tie on δ (2.1 ms) with different θ: the newer one must win.
    for up, proc, down in paths[2:] + paths[2:] + [(1_000_000, 20_000, 1_100_000), (1_100_000, 20_000, 1_000_000)]:
        exchange(t, up, proc, down)
        t += 1_000_000_000
    assert estimate()["samples"] == window_max
    before_tie, after_tie = events[-3]["estimate"], events[-1]["estimate"]
    assert before_tie["delay_ns"] == after_tie["delay_ns"] == 2_100_000
    assert before_tie["offset_ns"] != after_tie["offset_ns"], "tie must change the chosen θ"
    assert max(abs(o - theta) for o, _ in window) < 10_000_000, "2 s sample must have left the window"
    return {
        "note": "vcp.md §6.3 host side. Feed events in order into one estimator; 'request' records t1 "
                "as sent; for 'reply', t4 is the host clock on receipt. 'estimate' is the state after "
                "the reply (null before the first accepted sample).",
        "outstanding": outstanding_max,
        "reply_timeout_ns": timeout,
        "window": window_max,
        "events": events,
    }



def build_pairing() -> tuple[dict, dict]:
    code = "042917"
    I = b"vcam"
    s = bytes(range(0xB0, 0xC0))
    a = int.from_bytes(hashlib.sha256(b"VCP1 test vector a").digest(), "big")
    b = int.from_bytes(hashlib.sha256(b"VCP1 test vector b").digest(), "big")
    device_id = bytes.fromhex("00112233445566778899aabbccddeeff")
    host_id = bytes(range(0xF0, 0x100))
    r = srp(N3072, G3072, hashlib.sha256, I, code.encode(), s, a, b)
    pad = r["pad"]
    K = hashlib.sha256(pad(r["S"])).digest()

    hello = hello_payload(0, device_id, b"\xa5" * 16, "iPhone")
    challenge = host_id + s + pad(r["B"])
    t_pair = hashlib.sha256(hello + challenge + pad(r["A"])).digest()
    m1 = hmac.new(K, b"VCP1 pair M1" + t_pair, hashlib.sha256).digest()
    m2 = hmac.new(K, b"VCP1 pair M2" + t_pair + m1, hashlib.sha256).digest()
    pk = hkdf_sha256(K, t_pair, b"VCP1 pairing key", 32)
    proof = pad(r["A"]) + m1
    assert len(challenge) == 416 and len(proof) == 416

    # Wrong code on the device only: the host keeps the correct verifier and B, so u is unchanged
    # and the device computes S = (B - k*g^x')^(a + u*x') with x' from the wrong code.
    x_wrong = int.from_bytes(hashlib.sha256(s + hashlib.sha256(I + b":" + b"042918").digest()).digest(), "big")
    s_wrong = pow((r["B"] - r["k"] * pow(G3072, x_wrong, N3072)) % N3072, a + r["u"] * x_wrong, N3072)
    k_wrong = hashlib.sha256(pad(s_wrong)).digest()
    m1_wrong = hmac.new(k_wrong, b"VCP1 pair M1" + t_pair, hashlib.sha256).digest()
    if s_wrong == r["S"] or m1_wrong == m1:
        raise SystemExit("SELF-CHECK FAILED: wrong-code pairing produced the correct secret")

    vec = {
        "params": {"group": "RFC 5054 3072-bit", "g": G3072, "hash": "SHA-256", "N": format(N3072, "X"),
                   "I": I.decode(), "code": code},
        "inputs": {"s": hx(s), "a": format(a, "X"), "b": format(b, "X"), "device_id": hx(device_id),
                   "host_id": hx(host_id), "nonce_d": "a5" * 16, "device_name": "iPhone"},
        "srp": {k: format(r[k], "X") for k in ("k", "x", "v", "A", "B", "u", "S")},
        "K": hx(K),
        "T_pair": hx(t_pair),
        "M1": hx(m1),
        "M2": hx(m2),
        "PK": hx(pk),
        "messages": {
            "HELLO": hx(tcp(0x40, hello)),
            "PAIR_CHALLENGE": hx(tcp(0x41, challenge)),
            "PAIR_PROOF": hx(tcp(0x42, proof)),
            "PAIR_ACCEPT": hx(tcp(0x43, m2)),
        },
        "wrong_code": {"code": "042918", "M1": hx(m1_wrong),
                       "expect": "host rejects with ERROR 2 (M1 differs from the correct one)"},
    }
    return vec, {"pk": pk, "device_id": device_id, "host_id": host_id}


def build_session(ctx: dict) -> dict:
    pk = ctx["pk"]
    hello = hello_payload(1, ctx["device_id"], b"\x5a" * 16, "iPhone")
    sid, port = SID, 47000
    challenge = ctx["host_id"] + b"\xc3" * 16 + struct.pack("<IHH", sid, port, 0)
    assert len(challenge) == 40
    t_sess = hashlib.sha256(hello + challenge).digest()
    proof_d = hmac.new(pk, b"VCP1 session D" + t_sess, hashlib.sha256).digest()
    proof_h = hmac.new(pk, b"VCP1 session H" + t_sess + proof_d, hashlib.sha256).digest()
    keys = hkdf_sha256(pk, t_sess, b"VCP1 session keys" + struct.pack("<I", sid), 64)
    k_d2h, k_h2d = keys[:32], keys[32:]
    first_pose = udp(0x01, sid, pose_payload(1, 2_000_000_000, (0.0, 0.0, 1.5), (0, 0, 0, 1), 5), k_d2h)
    return {
        "PK": hx(pk),
        "inputs": {"nonce_d": "5a" * 16, "nonce_h": "c3" * 16, "session_id": sid, "udp_port": port},
        "T_sess": hx(t_sess),
        "proof_d": hx(proof_d),
        "proof_h": hx(proof_h),
        "k_d2h": hx(k_d2h),
        "k_h2d": hx(k_h2d),
        "messages": {
            "HELLO": hx(tcp(0x40, hello)),
            "SESSION_CHALLENGE": hx(tcp(0x44, challenge)),
            "SESSION_PROOF": hx(tcp(0x45, proof_d)),
            "SESSION_ACCEPT": hx(tcp(0x46, proof_h)),
            "first_POSE_udp": hx(first_pose),
        },
    }


def build_rfc5054() -> dict:
    v = RFC5054_B
    r = srp(N1024, 2, hashlib.sha1, v["I"].encode(), v["P"].encode(), bytes.fromhex(v["s"]),
            int(v["a"], 16), int(v["b"], 16))
    for key in ("k", "x", "v", "A", "B", "u", "S"):
        got = format(r[key], "X").rjust(len(v[key]), "0")
        if got != v[key]:
            raise SystemExit(f"SELF-CHECK FAILED: RFC 5054 Appendix B {key}: {got} != {v[key]}")
    return {"source": "RFC 5054 Appendix B", "group": "RFC 5054 1024-bit", "g": 2, "hash": "SHA-1",
            "N": format(N1024, "X"), **v}


# --- coordinates (vcp.md §7) -----------------------------------------------------------------


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def qaxis(axis, deg):
    h = math.radians(deg) / 2
    return (axis[0] * math.sin(h), axis[1] * math.sin(h), axis[2] * math.sin(h), math.cos(h))


def qrot(q, v):
    x, y, z, w = q
    return qmul(qmul(q, (*v, 0.0)), (-x, -y, -z, w))[:3]


def qcanon(q):
    n = math.sqrt(sum(c * c for c in q))
    q = tuple(c / n for c in q)
    return tuple(-c for c in q) if q[3] < 0 else q


def qmatrix(q, t):
    """Row-major 4x4 (Blender Matrix layout) from rotation q and translation t."""
    cols = [qrot(q, e) for e in ((1, 0, 0), (0, 1, 0), (0, 0, 1))]
    return [[cols[0][r], cols[1][r], cols[2][r], t[r]] for r in range(3)] + [[0.0, 0.0, 0.0, 1.0]]


def rnd(v, nd=9):
    out = [round(c, nd) + 0.0 for c in v]
    return out


def build_motion() -> tuple[dict, bytes]:
    """Scripted camera moves for vcam-fake-iphone and the headless Blender test (1.2.7/1.3.5).

    Level start (identity looks down -Z; +90 deg about X looks along +Y, up +Z), then pan,
    tilt, dolly and crane, each a 1 s move followed by a 0.5 s hold. The keypose is the last
    frame of each hold, so the receiver has settled on it.
    """
    rate, move, hold = 60, 60, 30
    q = qaxis((1, 0, 0), 90)
    p = (0.0, 0.0, 1.6)
    frames, keys = [], []

    def emit(pos, rot):
        rot = qcanon(rot)
        frames.append((tuple(f32(c) for c in pos), tuple(f32(c) for c in rot)))

    def hold_at(name):
        for _ in range(hold):
            emit(p, q)
        pos, rot = frames[-1]
        keys.append({"name": name, "frame": len(frames) - 1, "position": list(pos),
                     "orientation": list(rot), "matrix_world": [rnd(r) for r in qmatrix(rot, pos)]})

    def ramp(fn):
        for i in range(1, move + 1):
            emit(*fn(i / move))

    hold_at("start")
    ramp(lambda t: (p, qmul(qaxis((0, 0, 1), 90 * t), q)))  # pan left 90 deg about world Z
    q = qmul(qaxis((0, 0, 1), 90), q)
    hold_at("pan")
    ramp(lambda t: (p, qmul(q, qaxis((1, 0, 0), -30 * t))))  # tilt down 30 deg about camera X
    q = qmul(q, qaxis((1, 0, 0), -30))
    hold_at("tilt")
    start = p
    ramp(lambda t: ((start[0] - 2.0 * t, start[1], start[2]), q))  # dolly 2 m along the pan heading
    p = (start[0] - 2.0, start[1], start[2])
    hold_at("dolly")
    start = p
    ramp(lambda t: ((start[0], start[1], start[2] + 1.5 * t), q))  # crane up 1.5 m
    p = (start[0], start[1], start[2] + 1.5)
    hold_at("crane")

    def forward(k):
        return qrot(k["orientation"], (0, 0, -1))

    by = {k["name"]: k for k in keys}
    assert all(abs(a - b) < 1e-6 for a, b in zip(forward(by["start"]), (0, 1, 0)))
    assert all(abs(a - b) < 1e-6 for a, b in zip(forward(by["pan"]), (-1, 0, 0)))
    c, s30 = math.cos(math.radians(30)), math.sin(math.radians(30))
    assert all(abs(a - b) < 1e-6 for a, b in zip(forward(by["tilt"]), (-c, 0, -s30)))
    assert by["crane"]["position"] == [f32(-2.0), 0.0, f32(3.1)], by["crane"]["position"]

    blob = b"VCMO" + struct.pack("<HHI", 1, rate, len(frames))
    for pos, rot in frames:
        blob += struct.pack("<7f", *pos, *rot)
    doc = {
        "note": "Canonical axes (vcp.md §7). Stream frames in order at rate_hz (seq = index + 1). "
                "Each keypose is the last frame of a 0.5 s hold; matrix_world is row-major with "
                "an identity rig (VCam_Origin at the world origin, scale 1).",
        "rate_hz": rate,
        "frames": [{"position": list(pos), "orientation": list(rot)} for pos, rot in frames],
        "keyposes": keys,
    }
    return doc, blob


def build_rig() -> dict:
    """Reference for BlenderAddOn/core/rig.py, written with 3x3 matrices (not quaternions)."""

    def mat(q):
        x, y, z, w = q
        return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]

    def mmul(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]

    def mvec(m, v):
        return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]

    def rz(a):
        c, s = math.cos(a), math.sin(a)
        return [[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]]

    def col(m, j):
        return [m[0][j], m[1][j], m[2][j]]

    def heading(m):
        f = [-c for c in col(m, 2)]
        if math.hypot(f[0], f[1]) < 1e-6:
            f = col(m, 1)
        return math.atan2(-f[0], f[1])

    def quat(m):
        # Largest-component extraction, then w >= 0.
        t = m[0][0] + m[1][1] + m[2][2]
        cands = [(1 + t, 3), (1 + m[0][0] - m[1][1] - m[2][2], 0), (1 - m[0][0] + m[1][1] - m[2][2], 1),
                 (1 - m[0][0] - m[1][1] + m[2][2], 2)]
        v, k = max(cands)
        r = math.sqrt(v) * 2
        if k == 3:
            q = ((m[2][1] - m[1][2]) / r, (m[0][2] - m[2][0]) / r, (m[1][0] - m[0][1]) / r, r / 4)
        elif k == 0:
            q = (r / 4, (m[0][1] + m[1][0]) / r, (m[0][2] + m[2][0]) / r, (m[2][1] - m[1][2]) / r)
        elif k == 1:
            q = ((m[0][1] + m[1][0]) / r, r / 4, (m[1][2] + m[2][1]) / r, (m[0][2] - m[2][0]) / r)
        else:
            q = ((m[0][2] + m[2][0]) / r, (m[1][2] + m[2][1]) / r, r / 4, (m[1][0] - m[0][1]) / r)
        return qcanon(q)

    def cross(a, b):
        return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]

    def expected(p, q, zero_pose, scale, locks):
        p0, yaw0 = ([0.0, 0.0, 0.0], 0.0) if zero_pose is None else (list(zero_pose[0]), heading(mat(zero_pose[1])))
        un = rz(-yaw0)
        r = mmul(un, mat(q))
        prel = mvec(un, [a - b for a, b in zip(p, p0)])
        if locks & 4:
            prel = [0.0, 0.0, 0.0]
        if locks & 1:
            prel[2] = 0.0
        if locks & 2:
            f = [-c for c in col(r, 2)]
            up = [-f[0] * f[2], -f[1] * f[2], 1 - f[2] * f[2]]
            n = math.sqrt(sum(c * c for c in up))
            if n >= 1e-6:
                up = [c / n for c in up]
                back = [-c for c in f]
                x = cross(up, back)
                r = [[x[i], up[i], back[i]] for i in range(3)]
        return [scale * c for c in prel], quat(r), yaw0

    level = qaxis((1, 0, 0), 90)  # looks along +Y, up +Z

    def cam(yaw, pitch=0.0, roll=0.0):
        # World yaw about Z, then camera-local pitch about X and roll about the view axis (local Z).
        return qcanon(qmul(qmul(qaxis((0, 0, 1), yaw), level), qmul(qaxis((1, 0, 0), pitch), qaxis((0, 0, 1), roll))))

    tilted = cam(30, -20, 15)
    cases = []

    def case(name, p, q, zero_pose=None, scale=1.0, locks=0, note=""):
        # Compute from the rounded values actually written, so consumers start from the same inputs.
        p, q = rnd(p), rnd(q)
        if zero_pose is not None:
            zero_pose = (rnd(zero_pose[0]), rnd(zero_pose[1]))
        pos, rot, yaw0 = expected(p, q, zero_pose, scale, locks)
        cases.append({
            "name": name, "note": note, "position": rnd(p), "orientation": rnd(q),
            "zero_pose": None if zero_pose is None else {"position": rnd(zero_pose[0]), "orientation": rnd(zero_pose[1])},
            "zero_yaw": round(yaw0, 12), "motion_scale": scale, "lock_flags": locks,
            "expected_position": rnd(pos), "expected_orientation": rnd(rot),
        })

    case("identity", (0, 0, 0), (0, 0, 0, 1), note="no zero, no locks: local = device pose")
    case("scale_10", (0.5, -1.25, 1.6), level, scale=10.0, note="1:10 motion scale; rotation unscaled")
    case("lock_roll", (1, 2, 1.7), tilted, locks=2, note="yaw 30, pitch -20, roll 15 -> roll removed, heading and pitch kept")
    case("lock_height", (1, 2, 1.7), tilted, locks=1, note="local z = 0")
    case("pan_only", (1, 2, 1.7), tilted, locks=4, note="position locked at the origin")
    case("set_origin_then_walk", (-1, 0.5, 1.2), cam(100, -5), zero_pose=((1, 1, 1.6), cam(90)),
         note="zero at a camera facing -X; 2 m along -X and 0.5 m to its left -> local (-0.5, 2, -0.4) (forward +Y, right +X), yaw +10")
    case("combined", (-1, 0.5, 1.2), cam(100, -5, 8), zero_pose=((1, 1, 1.6), cam(90)), scale=2.0, locks=3,
         note="zero + scale 2 + lock height + lock roll")
    case("straight_down_lock_roll", (0, 0, 2), (0, 0, 0, 1), zero_pose=((0, 0, 2), qaxis((0, 0, 1), 45)), locks=2,
         note="looking straight down: heading from the up vector; roll undefined, so the rotation is kept")

    walk = next(c for c in cases if c["name"] == "set_origin_then_walk")
    assert all(abs(a - b) < 1e-9 for a, b in zip(walk["expected_position"], (-0.5, 2.0, -0.4))), walk
    assert abs(walk["zero_yaw"] - math.pi / 2) < 1e-12, walk
    # Lock roll on a rolled camera equals the same camera without roll (independent of the matrix path).
    no_roll = next(c for c in cases if c["name"] == "lock_roll")["expected_orientation"]
    assert all(abs(a - b) < 1e-9 for a, b in zip(no_roll, rnd(cam(30, -20)))), no_roll
    return {
        "note": "Camera local pose under VCam_Origin (BlenderAddOn/core/rig.py). Quaternions are "
                "x, y, z, w with w >= 0; compare positions and orientations to 1e-9 (q and -q are "
                "equal). zero_pose null means no Set origin yet (identity zero).",
        "lock_flags": {"lock_height": 1, "lock_roll": 2, "pan_only": 4},
        "cases": cases,
    }


def build_coords() -> dict:
    q_c = qaxis((1, 0, 0), 90)

    def convert(p, q):
        return (p[0], -p[2], p[1]), qcanon(qmul(q_c, q))

    # ARKit camera attitude from pan (about world +Y), tilt (about camera +X), roll (about camera +Z).
    def arkit_q(pan=0.0, tilt=0.0, roll=0.0):
        return qcanon(qmul(qmul(qaxis((0, 1, 0), pan), qaxis((1, 0, 0), tilt)), qaxis((0, 0, 1), roll)))

    specs = [
        ("identity", (0, 0, 0), {}, (0, 1, 0), (0, 0, 1)),
        ("pan_+90", (0, 0, 0), {"pan": 90}, (-1, 0, 0), (0, 0, 1)),
        ("pan_-90", (0, 0, 0), {"pan": -90}, (1, 0, 0), (0, 0, 1)),
        ("tilt_+90", (0, 0, 0), {"tilt": 90}, (0, 0, 1), (0, -1, 0)),
        ("tilt_-90", (0, 0, 0), {"tilt": -90}, (0, 0, -1), (0, 1, 0)),
        ("roll_+90", (0, 0, 0), {"roll": 90}, (0, 1, 0), (-1, 0, 0)),
        ("roll_-90", (0, 0, 0), {"roll": -90}, (0, 1, 0), (1, 0, 0)),
        ("combined_pan30_tilt-20_roll10", (0, 0, 0), {"pan": 30, "tilt": -20, "roll": 10}, None, None),
        ("translated_pan45", (1.0, 1.5, -2.0), {"pan": 45}, None, None),
    ]
    cases = []
    for name, p, att, want_fwd, want_up in specs:
        q = arkit_q(**att)
        cp, cq = convert(p, q)
        fwd, up = qrot(cq, (0, 0, -1)), qrot(cq, (0, 1, 0))
        if want_fwd is not None:
            for got, want, label in ((fwd, want_fwd, "forward"), (up, want_up, "up")):
                if max(abs(g - w) for g, w in zip(got, want)) > 1e-12:
                    raise SystemExit(f"SELF-CHECK FAILED: coords {name} {label} {got} != {want}")
        cases.append({
            "name": name,
            "arkit_attitude_deg": {"pan": att.get("pan", 0), "tilt": att.get("tilt", 0), "roll": att.get("roll", 0)},
            "arkit": {"position": rnd(p), "orientation": rnd(q), "transform_row_major": [rnd(r) for r in qmatrix(q, p)]},
            "canonical": {"position": rnd(cp), "orientation": rnd(cq),
                          "matrix_world_row_major": [rnd(r) for r in qmatrix(cq, cp)],
                          "view_direction": rnd(fwd), "up": rnd(up)},
        })
    return {
        "convention": "vcp.md §7. ARKit: Y up (worldAlignment .gravity). Canonical = Blender: Z up. "
                      "Camera looks down local -Z with local +Y up on both sides. "
                      "pan = rotation about world up, tilt = about camera +X, roll = about camera +Z; "
                      "q_arkit = q_pan ⊗ q_tilt ⊗ q_roll. matrix_world is for a VCam_Origin at identity, scale 1.",
        "tolerance": 1e-6,
        "quaternion_order": "x, y, z, w (w >= 0)",
        "cases": cases,
    }


# --------------------------------------------------------------------------------------------
# Self-checks and output


def self_check_hkdf():
    ikm = bytes.fromhex("0b" * 22)
    salt = bytes.fromhex("000102030405060708090a0b0c")
    info = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
    okm = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    if hkdf_sha256(ikm, salt, info, 42).hex() != okm:
        raise SystemExit("SELF-CHECK FAILED: HKDF vs RFC 5869 A.1")


def self_check_spec(messages: dict):
    """Every example block in vcp.md must equal the corresponding generated message."""
    text = SPEC.read_text(encoding="utf-8")
    blocks = re.findall(r"```\n(header .*?)```", text, re.S)
    wanted = []
    for block in blocks:
        joined = re.sub(r"\b(header|payload|tag)\b", " ", block)
        wanted.append(bytes.fromhex(re.sub(r"\s+", "", joined)))
    generated = {bytes.fromhex(c["hex"]) for c in messages["cases"]}
    missing = [w.hex() for w in wanted if w not in generated]
    if len(wanted) != 6 or missing:
        raise SystemExit(f"SELF-CHECK FAILED: vcp.md examples ({len(wanted)} found) not generated: {missing}")


def dumps(obj) -> str:
    def default(o):
        raise TypeError(repr(o))

    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False, default=default) + "\n"


def build_all() -> dict[str, bytes]:
    self_check_hkdf()
    rfc = build_rfc5054()
    messages, bins = build_messages()
    self_check_spec(messages)
    pairing, ctx = build_pairing()
    motion, motion_bin = build_motion()
    files = {
        "vcp/messages.json": dumps(messages).encode(),
        "vcp/receive.json": dumps(build_receive()).encode(),
        "vcp/freshness.json": dumps(build_freshness()).encode(),
        "vcp/clock_sync.json": dumps(build_clock_sync()).encode(),
        "vcp/pairing.json": dumps(pairing).encode(),
        "vcp/session.json": dumps(build_session(ctx)).encode(),
        "vcp/srp-rfc5054-appendix-b.json": dumps(rfc).encode(),
        "coords/arkit_to_canonical.json": dumps(build_coords()).encode(),
        "motion/scripted.json": dumps(motion).encode(),
        "rig/rig_cases.json": dumps(build_rig()).encode(),
        "motion/scripted.bin": motion_bin,
    }
    files.update({f"vcp/{name}": data for name, data in bins.items()})
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if testdata/ is out of date")
    args = parser.parse_args()
    files = build_all()
    if args.check:
        stale = [p for p, data in files.items() if not (OUT / p).exists() or (OUT / p).read_bytes() != data]
        extra = [str(p.relative_to(OUT)) for d in ("vcp", "coords", "motion", "rig") for p in (OUT / d).glob("*")
                 if str(p.relative_to(OUT)) not in files]
        if stale or extra:
            print(f"testdata/ is out of date. stale={stale} extra={extra}. Run tools/gen_testdata.py")
            sys.exit(1)
        print(f"testdata/ up to date ({len(files)} files)")
        return
    for rel, data in files.items():
        path = OUT / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print(f"wrote {len(files)} files to {OUT.relative_to(ROOT)}/")


main()
