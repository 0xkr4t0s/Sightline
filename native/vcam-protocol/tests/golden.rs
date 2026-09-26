//! Consumes the golden vectors in `testdata/vcp/` (NFR-QA-003, PR-004, PR-005).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::path::PathBuf;

use serde_json::Value;
use vcam_protocol::{
    CLOCK_OUTSTANDING, CLOCK_REPLY_TIMEOUT_NS, CLOCK_WINDOW, Clock, ClockEstimator, ClockReject,
    ClockSample, ControlState, DropReason, Endpoint, EpochWatcher, Message, Pose, Role, SealError,
    SeqFilter, Status,
};

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/vcp")
        .join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).expect("read testdata"))
        .expect("parse json")
}

fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn key(v: &Value) -> [u8; 32] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

/// Endpoints for the §11 example session: (host, device).
fn example_endpoints() -> (Endpoint, Endpoint) {
    let r = &load("receive.json")["receiver"];
    let sid = u32::try_from(r["session_id"].as_u64().unwrap()).unwrap();
    let (d2h, h2d) = (key(&r["k_d2h"]), key(&r["k_h2d"]));
    (
        Endpoint::new(Role::Host, sid, &d2h, &h2d).unwrap(),
        Endpoint::new(Role::Device, sid, &d2h, &h2d).unwrap(),
    )
}

/// (receiver, sender) for a vector's direction.
fn pair<'a>(
    direction: &str,
    host: &'a Endpoint,
    device: &'a Endpoint,
) -> (&'a Endpoint, &'a Endpoint) {
    match direction {
        "d2h" => (host, device),
        "h2d" => (device, host),
        other => panic!("bad direction {other}"),
    }
}

fn f32s(v: &Value) -> Vec<f32> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap() as f32)
        .collect()
}

fn uint(v: &Value) -> u64 {
    v.as_u64().unwrap()
}

fn check_fields(msg: &Message, f: &Value, name: &str) {
    match msg {
        Message::Pose(p) => {
            assert_eq!(u64::from(p.seq), uint(&f["seq"]), "{name}");
            assert_eq!(p.capture_time_ns, uint(&f["capture_time_ns"]), "{name}");
            assert_eq!(p.position_m.to_vec(), f32s(&f["position_m"]), "{name}");
            assert_eq!(p.orientation.to_vec(), f32s(&f["orientation"]), "{name}");
            assert_eq!(
                u64::from(p.tracking_state),
                uint(&f["tracking_state"]),
                "{name}"
            );
            assert_eq!(u64::from(p.flags), uint(&f["flags"]), "{name}");
        }
        Message::ControlState(c) => {
            let bits = uint(&f["fields"]);
            assert_eq!(u64::from(c.state_seq), uint(&f["state_seq"]), "{name}");
            let want_scale = (bits & 1 != 0).then(|| f["motion_scale"].as_f64().unwrap() as f32);
            assert_eq!(c.motion_scale, want_scale, "{name}");
            let want_locks = (bits & 2 != 0).then(|| u8::try_from(uint(&f["lock_flags"])).unwrap());
            assert_eq!(c.lock_flags, want_locks, "{name}");
            let want_epoch =
                (bits & 4 != 0).then(|| u16::try_from(uint(&f["origin_epoch"])).unwrap());
            assert_eq!(c.origin_epoch, want_epoch, "{name}");
        }
        Message::Clock(c) => {
            let (t1, t2, t3) = (uint(&f["t1"]), uint(&f["t2"]), uint(&f["t3"]));
            let want = match uint(&f["mode"]) {
                0 => Clock::Request { t1 },
                1 => Clock::Reply { t1, t2, t3 },
                m => panic!("{name}: mode {m}"),
            };
            assert_eq!(*c, want, "{name}");
        }
        Message::Status(s) => {
            assert_eq!(u64::from(s.status_seq), uint(&f["status_seq"]), "{name}");
            assert_eq!(
                u64::from(s.applied_pose_seq),
                uint(&f["applied_pose_seq"]),
                "{name}"
            );
            assert_eq!(u64::from(s.control_ack), uint(&f["control_ack"]), "{name}");
            assert_eq!(u64::from(s.error_code), uint(&f["error_code"]), "{name}");
            assert_eq!(u64::from(s.flags), uint(&f["flags"]), "{name}");
            assert_eq!(s.camera_name, f["camera_name"].as_str().unwrap(), "{name}");
        }
        Message::VideoFragment(_) => {
            panic!("{name}: VIDEO_FRAGMENT vectors are in testdata/video/")
        }
    }
}

#[test]
fn udp_messages_decode_and_reencode_byte_exact() {
    let (host, device) = example_endpoints();
    let cases = load("messages.json");
    let mut checked = 0;
    for case in cases["cases"].as_array().unwrap() {
        if case["channel"] != "udp" {
            continue; // TCP messages are task 1.1.3b
        }
        let name = case["name"].as_str().unwrap();
        let bytes = hex(case["hex"].as_str().unwrap());
        let (rx, tx) = pair(case["direction"].as_str().unwrap(), &host, &device);
        let msg = rx
            .open(&bytes)
            .unwrap_or_else(|e| panic!("{name}: dropped {e:?}"));
        check_fields(&msg, &case["fields"], name);
        let mut out = Vec::new();
        tx.seal(&msg, &mut out).unwrap();
        assert_eq!(out, bytes, "{name}: re-encoding differs");
        checked += 1;
    }
    assert_eq!(checked, 8);
}

#[test]
fn clock_reply_offset_and_delay() {
    let case = load("messages.json")["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "clock_reply")
        .unwrap()
        .clone();
    let f = &case["fields"];
    let s = ClockSample::from_timestamps(
        uint(&f["t1"]),
        uint(&f["t2"]),
        uint(&f["t3"]),
        uint(&f["t4_host_on_receipt"]),
    );
    assert_eq!(
        s.offset_ns,
        i128::from(f["expected_offset_ns"].as_i64().unwrap())
    );
    assert_eq!(
        s.delay_ns,
        i128::from(f["expected_delay_ns"].as_i64().unwrap())
    );
    // Extreme inputs must not overflow.
    let _ = ClockSample::from_timestamps(0, u64::MAX, u64::MAX, 0);
}

#[test]
fn receive_rules_match_vectors() {
    let (host, device) = example_endpoints();
    let vectors = load("receive.json");
    let cases = vectors["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 26);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let (rx, _) = pair(case["direction"].as_str().unwrap(), &host, &device);
        let bytes = hex(case["hex"].as_str().unwrap());
        let result = rx.open(&bytes);
        let want = case["accept"].as_bool().unwrap();
        assert_eq!(
            result.is_ok(),
            want,
            "{name}: got {result:?}, rule {}",
            case["rule"]
        );
        let (Ok(msg), Some(f)) = (result, case.get("fields")) else {
            continue;
        };
        match msg {
            Message::Pose(p) => {
                assert_eq!(u64::from(p.seq), uint(&f["seq"]), "{name}");
                if let Some(ts) = f.get("tracking_state") {
                    assert_eq!(u64::from(p.tracking_state), uint(ts), "{name}");
                }
                if let Some(q) = f.get("orientation_renormalised") {
                    for (got, want) in p.orientation_normalized().iter().zip(f32s(q)) {
                        assert!((got - want).abs() < 1e-6, "{name}: {got} vs {want}");
                    }
                }
            }
            Message::ControlState(c) => {
                assert_eq!(u64::from(c.state_seq), uint(&f["state_seq"]), "{name}");
                let bits = uint(&f["fields"]);
                assert_eq!(c.motion_scale.is_some(), bits & 1 != 0, "{name}");
                assert_eq!(c.lock_flags.is_some(), bits & 2 != 0, "{name}");
                assert_eq!(c.origin_epoch.is_some(), bits & 4 != 0, "{name}");
            }
            other => panic!("{name}: unexpected {other:?}"),
        }
    }
}

#[test]
fn drop_reasons_follow_rule_order() {
    let (host, device) = example_endpoints();
    let vectors = load("receive.json");
    let reason = |name: &str| {
        let case = vectors["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == name)
            .unwrap();
        let (rx, _) = pair(case["direction"].as_str().unwrap(), &host, &device);
        rx.open(&hex(case["hex"].as_str().unwrap())).unwrap_err()
    };
    assert_eq!(reason("too_short_datagram"), DropReason::Size);
    assert_eq!(reason("oversize_datagram"), DropReason::Size);
    assert_eq!(reason("bad_magic"), DropReason::Magic);
    assert_eq!(reason("unknown_version"), DropReason::Version);
    assert_eq!(reason("len_too_large"), DropReason::Length);
    assert_eq!(reason("session_id_zero"), DropReason::Session);
    assert_eq!(reason("wrong_direction_key"), DropReason::Tag);
    assert_eq!(reason("unknown_type"), DropReason::UnknownType);
    assert_eq!(reason("clock_request_from_device"), DropReason::UnknownType);
    assert!(matches!(
        reason("pose_payload_short"),
        DropReason::Payload(_)
    ));
}

#[test]
fn freshness_sequences_match_vectors() {
    let vectors = load("freshness.json");
    for seq in vectors["sequences"].as_array().unwrap() {
        let input: Vec<u64> = seq["input"].as_array().unwrap().iter().map(uint).collect();
        if let Some(applied) = seq.get("applied") {
            let mut filter = SeqFilter::default();
            let got: Vec<u64> = input
                .iter()
                .copied()
                .filter(|&v| filter.accept(u32::try_from(v).unwrap()))
                .collect();
            let want: Vec<u64> = applied.as_array().unwrap().iter().map(uint).collect();
            assert_eq!(got, want, "{}", seq["message"]);
        } else {
            let mut watcher = EpochWatcher::default();
            let got: Vec<u64> = input
                .iter()
                .enumerate()
                .filter(|&(_, &v)| watcher.changed(u16::try_from(v).unwrap()))
                .map(|(i, _)| i as u64)
                .collect();
            let want: Vec<u64> = seq["resets_at_index"]
                .as_array()
                .unwrap()
                .iter()
                .map(uint)
                .collect();
            assert_eq!(got, want, "{}", seq["message"]);
        }
    }
}

#[test]
fn clock_sync_matches_vectors() {
    let vectors = load("clock_sync.json");
    assert_eq!(uint(&vectors["outstanding"]), CLOCK_OUTSTANDING as u64);
    assert_eq!(uint(&vectors["reply_timeout_ns"]), CLOCK_REPLY_TIMEOUT_NS);
    assert_eq!(uint(&vectors["window"]), CLOCK_WINDOW as u64);
    let int = |v: &Value| i128::from(v.as_i64().unwrap());
    let mut clock = ClockEstimator::default();
    let mut replies = 0;
    for (i, e) in vectors["events"].as_array().unwrap().iter().enumerate() {
        let t1 = uint(&e["t1"]);
        if e["op"] == "request" {
            clock.request(t1);
            continue;
        }
        replies += 1;
        let got = clock.reply(t1, uint(&e["t2"]), uint(&e["t3"]), uint(&e["t4"]));
        let want = match e["result"].as_str().unwrap() {
            "accepted" => None,
            "unmatched" => Some(ClockReject::Unmatched),
            "expired" => Some(ClockReject::Expired),
            "invalid" => Some(ClockReject::Invalid),
            other => panic!("unknown result {other}"),
        };
        assert_eq!(got.err(), want, "event {i}: {}", e["note"]);
        let est = clock.estimate();
        let w = &e["estimate"];
        if w.is_null() {
            assert_eq!(est, None, "event {i}");
            continue;
        }
        let est = est.unwrap();
        assert_eq!(
            (
                est.offset_ns,
                est.delay_ns,
                est.jitter_ns,
                est.samples as u64
            ),
            (
                int(&w["offset_ns"]),
                int(&w["delay_ns"]),
                uint(&w["jitter_ns"]),
                uint(&w["samples"])
            ),
            "event {i}: {}",
            e["note"]
        );
    }
    assert!(replies >= 20, "{replies}");
}

#[test]
fn seal_enforces_direction_and_limits() {
    let (host, device) = example_endpoints();
    let status = Message::Status(Status {
        status_seq: 1,
        applied_pose_seq: 0,
        control_ack: 0,
        error_code: 0,
        flags: 0,
        camera_name: "x".repeat(64),
    });
    let mut out = vec![0xAA];
    assert_eq!(
        device.seal(&status, &mut out),
        Err(SealError::WrongDirection)
    );
    assert!(matches!(
        host.seal(&status, &mut out),
        Err(SealError::Payload(_))
    ));
    assert_eq!(
        out,
        vec![0xAA],
        "a failed seal must leave the buffer unchanged"
    );
    let pose = Message::Pose(Pose {
        seq: 1,
        capture_time_ns: 0,
        position_m: [0.0; 3],
        orientation: [0.0, 0.0, 0.0, 1.0],
        tracking_state: Pose::TRACKING_NORMAL,
        flags: 0,
    });
    assert_eq!(host.seal(&pose, &mut out), Err(SealError::WrongDirection));
    let control = Message::ControlState(ControlState {
        state_seq: 1,
        motion_scale: None,
        lock_flags: Some(1),
        origin_epoch: None,
    });
    device.seal(&control, &mut out).unwrap();
    assert_eq!(
        host.open(&out[1..]).unwrap(),
        control,
        "a partial CONTROL_STATE round-trips"
    );
    assert!(
        Endpoint::new(Role::Host, 0, &[0; 32], &[0; 32]).is_none(),
        "session_id 0 is reserved"
    );
}

/// PR-005 smoke check (the real fuzzing is task 1.1.3c): prefixes, every single-byte flip,
/// and pseudo-random datagrams must never panic, and no corrupted vector may be accepted.
#[test]
fn malformed_input_never_panics_or_authenticates() {
    let (host, device) = example_endpoints();
    let mut all: Vec<(Vec<u8>, &str)> = Vec::new();
    for case in load("messages.json")["cases"].as_array().unwrap() {
        if case["channel"] == "udp" {
            let dir = if case["direction"] == "d2h" {
                "d2h"
            } else {
                "h2d"
            };
            all.push((hex(case["hex"].as_str().unwrap()), dir));
        }
    }
    for (bytes, dir) in &all {
        let (rx, _) = pair(dir, &host, &device);
        for n in 0..bytes.len() {
            assert!(rx.open(&bytes[..n]).is_err());
        }
        for i in 0..bytes.len() {
            let mut m = bytes.clone();
            m[i] ^= 0xFF;
            assert!(rx.open(&m).is_err(), "byte {i} flip accepted");
        }
    }
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    for _ in 0..20_000 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let len = (state >> 33) as usize % 1300;
        let mut d: Vec<u8> = (0..len)
            .map(|i| (state.rotate_left((i % 64) as u32) >> 11) as u8 ^ i as u8)
            .collect();
        if d.len() >= 12 {
            d[..4].copy_from_slice(b"VCP1");
            d[4] = 1;
        }
        let _ = host.open(&d);
        let _ = device.open(&d);
    }
}
