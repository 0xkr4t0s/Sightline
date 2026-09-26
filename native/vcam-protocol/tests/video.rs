//! Consumes `testdata/video/` (vcp.md §6.5; NET-VID-001, NET-VID-004, NFR-QA-003).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::path::PathBuf;

use serde_json::Value;
use vcam_protocol::{
    DropReason, Endpoint, Message, PayloadError, Pushed, Reassembler, Role, VideoFragment,
    VideoFrameInfo, VideoReport, fragment_frame,
};

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/video")
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

fn uint(v: &Value) -> u64 {
    v.as_u64().unwrap()
}

/// (device, host) endpoints for the vcp.md §11 example session.
fn endpoints(v: &Value) -> (Endpoint, Endpoint) {
    let sid = u32::try_from(uint(&v["session_id"])).unwrap();
    let (d2h, h2d) = (key(&v["k_d2h"]), key(&v["k_h2d"]));
    (
        Endpoint::new(Role::Device, sid, &d2h, &h2d).unwrap(),
        Endpoint::new(Role::Host, sid, &d2h, &h2d).unwrap(),
    )
}

fn check_fields(f: &VideoFragment<'_>, want: &Value, name: &str) {
    let got = [
        u64::from(f.frame.frame_id),
        u64::from(f.frame_len),
        u64::from(f.frag_index),
        u64::from(f.frag_count),
        u64::from(f.frag_size),
        u64::from(f.frame.codec),
        u64::from(f.frame.color),
        f.frame.render_time_ns,
        u64::from(f.frame.pose_seq),
        u64::from(f.frame.quality),
        u64::from(f.frame.flags),
    ];
    let keys = [
        "frame_id",
        "frame_len",
        "frag_index",
        "frag_count",
        "frag_size",
        "codec",
        "color",
        "render_time_ns",
        "pose_seq",
        "quality",
        "flags",
    ];
    for (k, g) in keys.iter().zip(got) {
        assert_eq!(g, uint(&want[k]), "{name}: {k}");
    }
    assert_eq!(f.data, hex(want["data"].as_str().unwrap()), "{name}: data");
}

#[test]
fn fragments_match_vectors() {
    let v = load("fragments.json");
    assert_eq!(
        (
            uint(&v["limits"]["header_len"]),
            uint(&v["limits"]["max_data"]),
            uint(&v["limits"]["max_frame_len"]),
        ),
        (
            VideoFragment::HEADER_LEN as u64,
            VideoFragment::MAX_DATA as u64,
            u64::from(VideoFragment::MAX_FRAME_LEN)
        )
    );
    let (device, host) = endpoints(&v["receiver"]);
    let cases = v["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 16);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let bytes = hex(case["hex"].as_str().unwrap());
        let (rx, tx) = match case["direction"].as_str().unwrap() {
            "h2d" => (&device, &host),
            _ => (&host, &device),
        };
        let result = rx.open(&bytes);
        if !case["accept"].as_bool().unwrap() {
            let want = match case["reason"].as_str().unwrap() {
                "too_short" => DropReason::Payload(PayloadError::TooShort),
                "layout" => DropReason::Payload(PayloadError::FragmentLayout),
                "format" => DropReason::Payload(PayloadError::VideoFormat),
                "direction" => DropReason::UnknownType,
                r => panic!("{name}: reason {r}"),
            };
            assert_eq!(result, Err(want), "{name}: rule {}", case["rule"]);
            continue;
        }
        let Ok(Message::VideoFragment(frag)) = result else {
            panic!("{name}: got {result:?}");
        };
        check_fields(&frag, &case["fields"], name);
        // Re-sealing reproduces the datagram; ignored tail bytes are dropped (and `len` shrinks).
        let mut out = Vec::new();
        tx.seal(&Message::VideoFragment(frag), &mut out).unwrap();
        let len = 12 + VideoFragment::HEADER_LEN + frag.data.len();
        assert_eq!(out.len(), len + 8, "{name}");
        if bytes.len() == out.len() {
            assert_eq!(out, bytes, "{name}: re-encoding differs");
        } else {
            assert_eq!(out[12..len], bytes[12..len], "{name}: re-encoding differs");
        }
        assert_eq!(
            rx.open(&out).unwrap(),
            Message::VideoFragment(frag),
            "{name}"
        );
    }
}

#[test]
fn host_split_matches_the_first_and_last_vectors() {
    let v = load("fragments.json");
    let (_, host) = endpoints(&v["receiver"]);
    let case = |n: &str| {
        v["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == n)
            .unwrap()
            .clone()
    };
    // The generator's 2600-byte frame: byte i = (7i + 3) mod 256.
    let data: Vec<u8> = (0..2600u32).map(|i| ((i * 7 + 3) & 0xFF) as u8).collect();
    let frame = VideoFrameInfo {
        frame_id: 9,
        render_time_ns: 123_456_789_012,
        pose_seq: 4_000_000_000,
        codec: VideoFragment::CODEC_JPEG,
        color: VideoFragment::COLOR_SRGB_REC709,
        quality: 100,
        flags: 0,
    };
    let datagrams: Vec<Vec<u8>> = fragment_frame(frame, &data)
        .unwrap()
        .map(|f| {
            let mut out = Vec::new();
            host.seal(&Message::VideoFragment(f), &mut out).unwrap();
            out
        })
        .collect();
    assert_eq!(datagrams.len(), 3);
    assert_eq!(
        datagrams[0].len(),
        1200,
        "a full fragment fills the datagram"
    );
    for (i, name) in [(0, "video_first_of_three"), (2, "video_last_of_three")] {
        assert_eq!(
            datagrams[i],
            hex(case(name)["hex"].as_str().unwrap()),
            "{name}"
        );
    }
}

#[test]
fn reassembly_matches_vectors() {
    let v = load("reassembly.json");
    let sid = u32::try_from(uint(&v["session_id"])).unwrap();
    let device = Endpoint::new(Role::Device, sid, &[0; 32], &key(&v["k_h2d"])).unwrap();
    let sequences = v["sequences"].as_array().unwrap();
    assert_eq!(sequences.len(), 6);
    for seq in sequences {
        let name = seq["name"].as_str().unwrap();
        let mut r = Reassembler::new();
        let mut highest = 0;
        for (i, step) in seq["steps"].as_array().unwrap().iter().enumerate() {
            let bytes = hex(step["hex"].as_str().unwrap());
            let Ok(Message::VideoFragment(frag)) = device.open(&bytes) else {
                panic!("{name}[{i}]: vector datagram must open");
            };
            highest = highest.max(frag.frame.frame_id);
            let pushed = r.push(&frag);
            let got = match pushed {
                Pushed::Pending => "pending",
                Pushed::Complete(_) => "complete",
                Pushed::Stale => "stale",
                Pushed::Duplicate => "duplicate",
                Pushed::Done => "done",
                Pushed::Inconsistent => "inconsistent",
            };
            assert_eq!(got, step["outcome"].as_str().unwrap(), "{name}[{i}]");
            if let Pushed::Complete(c) = pushed {
                let f = &step["frame"];
                assert_eq!(u64::from(c.frame.frame_id), uint(&f["frame_id"]), "{name}");
                assert_eq!(c.frame.render_time_ns, uint(&f["render_time_ns"]), "{name}");
                assert_eq!(u64::from(c.frame.pose_seq), uint(&f["pose_seq"]), "{name}");
                assert_eq!(c.data, hex(f["data"].as_str().unwrap()), "{name}[{i}]");
            }
        }
        let stats = r.stats();
        assert_eq!(
            (stats.complete, stats.lost),
            (uint(&seq["complete"]), uint(&seq["lost"])),
            "{name}"
        );
        // The device's VIDEO_REPORT totals (vcp.md §6.6) after the sequence.
        let report = r.report(7, 0);
        assert_eq!(
            (report.newest_frame_id, u64::from(report.frames_complete)),
            (highest, stats.complete),
            "{name}"
        );
    }
}

#[test]
fn reports_match_vectors() {
    let v = load("report.json");
    assert_eq!(uint(&v["len"]), VideoReport::LEN as u64);
    let (device, host) = endpoints(&v["receiver"]);
    let cases = v["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 8);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let bytes = hex(case["hex"].as_str().unwrap());
        let (rx, tx) = match case["direction"].as_str().unwrap() {
            "d2h" => (&host, &device),
            _ => (&device, &host),
        };
        let result = rx.open(&bytes);
        if !case["accept"].as_bool().unwrap() {
            let want = match case["reason"].as_str().unwrap() {
                "too_short" => DropReason::Payload(PayloadError::TooShort),
                "counts" => DropReason::Payload(PayloadError::ReportCounts),
                "direction" => DropReason::UnknownType,
                r => panic!("{name}: reason {r}"),
            };
            assert_eq!(result, Err(want), "{name}: rule {}", case["rule"]);
            continue;
        }
        let f = &case["fields"];
        let want = VideoReport {
            report_seq: u32::try_from(uint(&f["report_seq"])).unwrap(),
            newest_frame_id: u32::try_from(uint(&f["newest_frame_id"])).unwrap(),
            frames_complete: u32::try_from(uint(&f["frames_complete"])).unwrap(),
            m2p_p95_ms: u16::try_from(uint(&f["m2p_p95_ms"])).unwrap(),
        };
        assert_eq!(result, Ok(Message::VideoReport(want)), "{name}");
        // Re-sealing gives the 16-byte v1 layout: reserved zeroed, extra bytes dropped.
        let mut out = Vec::new();
        tx.seal(&Message::VideoReport(want), &mut out).unwrap();
        assert_eq!(out.len(), 12 + VideoReport::LEN + 8, "{name}");
        if name == "report_example" || name == "report_nothing_complete" {
            assert_eq!(out, bytes, "{name}: re-encoding differs");
        }
        assert_eq!(rx.open(&out), Ok(Message::VideoReport(want)), "{name}");
    }
    // A device can't seal counts the host would drop, nor can the host send a report.
    let bad = VideoReport {
        report_seq: 1,
        newest_frame_id: 2,
        frames_complete: 3,
        m2p_p95_ms: 0,
    };
    let mut out = Vec::new();
    assert!(device.seal(&Message::VideoReport(bad), &mut out).is_err());
    assert!(
        host.seal(&Message::VideoReport(VideoReport::default()), &mut out)
            .is_err()
    );
    assert!(out.is_empty());
}
