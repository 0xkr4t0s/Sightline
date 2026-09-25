//! Consumes `testdata/vcp/video.json` (vcp.md §6.5; NET-VID-001, NET-VID-004, PR-005).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::path::PathBuf;

use serde_json::Value;
use vcam_protocol::{
    DropReason, Endpoint, FragmentOutcome, FrameInfo, MAX_CHUNK_LEN, MAX_FRAGMENTS, MAX_FRAME_LEN,
    Message, PayloadError, Reassembler, Role, SealError, VIDEO_HEADER_LEN, VideoFragment,
    video_codec,
};

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/vcp")
        .join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).expect("read testdata"))
        .expect("parse json")
}

fn hex(v: &Value) -> Vec<u8> {
    let s = v.as_str().unwrap();
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn uint<T: TryFrom<u64>>(v: &Value) -> T
where
    T::Error: std::fmt::Debug,
{
    T::try_from(v.as_u64().unwrap()).unwrap()
}

/// (host, device) for the vcp.md §11 example session.
fn endpoints() -> (Endpoint, Endpoint) {
    let r = &load("receive.json")["receiver"];
    let sid = uint(&r["session_id"]);
    let d2h: [u8; 32] = hex(&r["k_d2h"]).try_into().unwrap();
    let h2d: [u8; 32] = hex(&r["k_h2d"]).try_into().unwrap();
    (
        Endpoint::new(Role::Host, sid, &d2h, &h2d).unwrap(),
        Endpoint::new(Role::Device, sid, &d2h, &h2d).unwrap(),
    )
}

#[test]
fn limits_match_the_vectors() {
    let l = &load("video.json")["limits"];
    assert_eq!(uint::<usize>(&l["header_len"]), VIDEO_HEADER_LEN);
    assert_eq!(uint::<u16>(&l["max_chunk_len"]), MAX_CHUNK_LEN);
    assert_eq!(uint::<u32>(&l["max_frame_len"]), MAX_FRAME_LEN);
    assert_eq!(uint::<u32>(&l["max_fragments"]), MAX_FRAGMENTS);
}

#[test]
fn seal_frame_matches_vectors_and_reassembles() {
    let (host, device) = endpoints();
    let v = load("video.json");
    let cases = v["fragmentation"].as_array().unwrap();
    assert_eq!(cases.len(), 4);
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let info = FrameInfo {
            frame_id: uint(&c["frame_id"]),
            render_time_ns: uint(&c["render_time_ns"]),
            pose_seq: uint(&c["pose_seq"]),
            codec: uint(&c["codec"]),
            flags: uint(&c["flags"]),
        };
        let frame = hex(&c["frame"]);
        let mut sealed = Vec::new();
        let count = host
            .seal_frame(&info, &frame, uint(&c["chunk_len"]), |d| {
                sealed.push(d.to_vec());
            })
            .unwrap();
        let want: Vec<Vec<u8>> = c["datagrams"].as_array().unwrap().iter().map(hex).collect();
        assert_eq!(sealed, want, "{name}");
        assert_eq!(usize::try_from(count).unwrap(), want.len(), "{name}");

        // Device side: every datagram opens, re-seals byte-exact, and reassembles the frame.
        let mut r = Reassembler::new();
        for (i, d) in want.iter().enumerate() {
            let Ok(Message::VideoFragment(frag)) = device.open(d) else {
                panic!("{name}: datagram {i} did not open as VIDEO_FRAGMENT");
            };
            assert_eq!(frag.frame, info, "{name}");
            let mut again = Vec::new();
            host.seal(&Message::VideoFragment(frag.clone()), &mut again)
                .unwrap();
            assert_eq!(&again, d, "{name}");
            let outcome = r.push(&frag);
            if i + 1 < want.len() {
                assert_eq!(outcome, FragmentOutcome::Pending, "{name}");
            } else {
                let FragmentOutcome::Complete(done) = outcome else {
                    panic!("{name}: last fragment gave {outcome:?}");
                };
                assert_eq!(done.info, info, "{name}");
                assert_eq!(done.data, frame, "{name}");
            }
        }
    }
    // The spec example is the first datagram of the first case, and its .bin file.
    let example = hex(&v["example"]["hex"]);
    assert_eq!(example, hex(&cases[0]["datagrams"][0]));
    let bin = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/vcp")
        .join(v["example"]["file"].as_str().unwrap());
    assert_eq!(std::fs::read(bin).unwrap(), example);
}

#[test]
fn invalid_fragments_are_dropped_with_their_rule() {
    let (host, device) = endpoints();
    let v = load("video.json");
    let cases = v["invalid"].as_array().unwrap();
    assert_eq!(cases.len(), 12);
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let rule = c["rule"].as_str().unwrap();
        let rx = match c["direction"].as_str().unwrap() {
            "h2d" => &device,
            "d2h" => &host,
            other => panic!("{name}: direction {other}"),
        };
        let got = rx.open(&hex(&c["hex"])).unwrap_err();
        let want = if rule.starts_with("§4.3 step 7") {
            DropReason::UnknownType
        } else if rule.starts_with("§4.3 step 8") {
            DropReason::Payload(PayloadError::TooShort)
        } else {
            DropReason::Payload(PayloadError::FragmentLayout)
        };
        assert_eq!(got, want, "{name}: {rule}");
    }
}

#[test]
fn reassembly_scenarios_match_the_reference() {
    let v = load("video.json");
    let scenarios = v["reassembly"].as_array().unwrap();
    assert_eq!(scenarios.len(), 7);
    for s in scenarios {
        let name = s["name"].as_str().unwrap();
        let mut r = Reassembler::new();
        for (i, step) in s["steps"].as_array().unwrap().iter().enumerate() {
            let frag = VideoFragment::decode(&hex(&step["payload"])).unwrap();
            let outcome = r.push(&frag);
            let label = match &outcome {
                FragmentOutcome::Pending => "pending",
                FragmentOutcome::Complete(_) => "complete",
                FragmentOutcome::Stale => "stale",
                FragmentOutcome::Duplicate => "duplicate",
                FragmentOutcome::Inconsistent => "inconsistent",
                FragmentOutcome::Invalid => "invalid",
            };
            assert_eq!(label, step["outcome"].as_str().unwrap(), "{name} step {i}");
            if let FragmentOutcome::Complete(frame) = outcome {
                let f = &step["frame"];
                assert_eq!(frame.info.frame_id, uint::<u32>(&f["frame_id"]), "{name}");
                assert_eq!(frame.info.render_time_ns, uint::<u64>(&f["render_time_ns"]));
                assert_eq!(frame.info.pose_seq, uint::<u32>(&f["pose_seq"]), "{name}");
                assert_eq!(frame.info.codec, uint::<u8>(&f["codec"]), "{name}");
                assert_eq!(frame.info.flags, uint::<u8>(&f["flags"]), "{name}");
                assert_eq!(frame.data, hex(&f["data"]), "{name}");
            }
        }
        let stats = r.stats();
        assert_eq!(stats.abandoned, uint::<u64>(&s["abandoned"]), "{name}");
        assert_eq!(
            stats.inconsistent,
            uint::<u64>(&s["inconsistent"]),
            "{name}"
        );
    }
}

#[test]
fn seal_frame_refuses_bad_input_and_the_device_role() {
    let (host, device) = endpoints();
    let info = FrameInfo {
        frame_id: 1,
        render_time_ns: 0,
        pose_seq: 0,
        codec: video_codec::JPEG,
        flags: FrameInfo::KEYFRAME,
    };
    let bad = Err(SealError::Payload(PayloadError::FragmentLayout));
    let mut emitted = 0;
    let mut emit = |_: &[u8]| emitted += 1;
    assert_eq!(host.seal_frame(&info, &[], MAX_CHUNK_LEN, &mut emit), bad);
    assert_eq!(host.seal_frame(&info, &[1], 0, &mut emit), bad);
    assert_eq!(
        host.seal_frame(&info, &[1], MAX_CHUNK_LEN + 1, &mut emit),
        bad
    );
    let zero_id = FrameInfo {
        frame_id: 0,
        ..info
    };
    assert_eq!(
        host.seal_frame(&zero_id, &[1], MAX_CHUNK_LEN, &mut emit),
        bad
    );
    let too_big = vec![0; usize::try_from(MAX_FRAME_LEN).unwrap() + 1];
    assert_eq!(
        host.seal_frame(&info, &too_big, MAX_CHUNK_LEN, &mut emit),
        bad
    );
    // 65537 one-byte fragments would need a 17-bit index.
    assert_eq!(host.seal_frame(&info, &[0; 65_537], 1, &mut emit), bad);
    assert_eq!(
        device.seal_frame(&info, &[1], MAX_CHUNK_LEN, &mut emit),
        Err(SealError::WrongDirection)
    );
    assert_eq!(emitted, 0);

    // A full-size fragment fills exactly one 1200-byte datagram.
    let mut sizes = Vec::new();
    let n = host
        .seal_frame(&info, &[7; 3000], MAX_CHUNK_LEN, |d| sizes.push(d.len()))
        .unwrap();
    assert_eq!((n, sizes), (3, vec![1200, 1200, 12 + 28 + 696 + 8]));
}

#[test]
fn hand_built_invalid_fragment_is_rejected_not_panicking() {
    let frag = VideoFragment {
        frame: FrameInfo {
            frame_id: 1,
            render_time_ns: 0,
            pose_seq: 0,
            codec: 0,
            flags: 1,
        },
        frame_len: 10,
        chunk_len: 4,
        frag_index: 0,
        data: vec![0; 3],
    };
    assert_eq!(Reassembler::new().push(&frag), FragmentOutcome::Invalid);
    assert_eq!(
        frag.encode(&mut Vec::new()),
        Err(PayloadError::FragmentLayout)
    );
}
