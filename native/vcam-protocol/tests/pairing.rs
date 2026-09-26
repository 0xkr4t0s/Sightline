//! Pairing, session setup, and control frames against `testdata/vcp/{pairing,session,messages}.json`.
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::path::PathBuf;

use serde_json::Value;
use vcam_protocol::{
    ControlError, ControlMessage, Endpoint, Hello, HostPairing, Message, PairError, Role,
    SessionHandshake, device_pair,
};

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/vcp")
        .join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).expect("read testdata"))
        .expect("parse json")
}

fn hex(s: &str) -> Vec<u8> {
    let s = if s.len() % 2 == 1 {
        format!("0{s}")
    } else {
        s.to_owned()
    };
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn arr<const N: usize>(v: &Value) -> [u8; N] {
    let b = hex(v.as_str().unwrap());
    let mut out = [0u8; N];
    out[N - b.len()..].copy_from_slice(&b); // big-endian integers may be shorter
    out
}

fn decode(v: &Value) -> ControlMessage {
    let bytes = hex(v.as_str().unwrap());
    let msg = ControlMessage::decode(&bytes).unwrap();
    assert_eq!(
        msg.encode().unwrap(),
        bytes,
        "control frame must re-encode byte-exactly"
    );
    msg
}

fn hello_of(msg: ControlMessage) -> Hello {
    match msg {
        ControlMessage::Hello(h) => h,
        other => panic!("expected HELLO, got {other:?}"),
    }
}

#[test]
fn pairing_transcript_matches_vector() {
    let p = load("pairing.json");
    let (inputs, msgs) = (&p["inputs"], &p["messages"]);
    let code = p["params"]["code"].as_str().unwrap();
    let hello = hello_of(decode(&msgs["HELLO"]));

    // Host builds PAIR_CHALLENGE from HELLO.
    let host = HostPairing::new(
        code,
        &hello,
        arr(&inputs["host_id"]),
        arr(&inputs["s"]),
        &arr(&inputs["b"]),
    )
    .unwrap();
    let challenge = ControlMessage::PairChallenge(host.challenge().clone());
    assert_eq!(challenge, decode(&msgs["PAIR_CHALLENGE"]));

    // Device answers with PAIR_PROOF (A, M1).
    let (proof, pending) = device_pair(code, &hello, host.challenge(), &arr(&inputs["a"])).unwrap();
    assert_eq!(
        ControlMessage::PairProof(proof.clone()),
        decode(&msgs["PAIR_PROOF"])
    );
    assert_eq!(proof.m1.to_vec(), hex(p["M1"].as_str().unwrap()));

    // Host verifies M1 and returns M2 and PK; device verifies M2 and derives the same PK.
    let (m2, pk_host) = host.verify(&proof).unwrap();
    assert_eq!(
        ControlMessage::PairAccept { m2 },
        decode(&msgs["PAIR_ACCEPT"])
    );
    let pk_device = pending.finish(&m2).unwrap();
    assert_eq!(pk_host, pk_device);
    assert_eq!(pk_host.to_vec(), hex(p["PK"].as_str().unwrap()));

    // Tampered M2 is rejected.
    let mut bad = m2;
    bad[0] ^= 1;
    assert_eq!(pending.finish(&bad), Err(PairError::BadProof));
}

#[test]
fn wrong_code_is_rejected_with_the_vector_m1() {
    let p = load("pairing.json");
    let (inputs, msgs) = (&p["inputs"], &p["messages"]);
    let hello = hello_of(decode(&msgs["HELLO"]));
    let host = HostPairing::new(
        p["params"]["code"].as_str().unwrap(),
        &hello,
        arr(&inputs["host_id"]),
        arr(&inputs["s"]),
        &arr(&inputs["b"]),
    )
    .unwrap();
    let wrong = &p["wrong_code"];
    let (proof, _) = device_pair(
        wrong["code"].as_str().unwrap(),
        &hello,
        host.challenge(),
        &arr(&inputs["a"]),
    )
    .unwrap();
    assert_eq!(proof.m1.to_vec(), hex(wrong["M1"].as_str().unwrap()));
    assert_eq!(host.verify(&proof), Err(PairError::BadProof));
}

#[test]
fn session_setup_matches_vector_and_keys_open_first_pose() {
    let s = load("session.json");
    let msgs = &s["messages"];
    let pk: [u8; 32] = arr(&s["PK"]);
    let hello = hello_of(decode(&msgs["HELLO"]));
    let ControlMessage::SessionChallenge(challenge) = decode(&msgs["SESSION_CHALLENGE"]) else {
        panic!()
    };

    let hs = SessionHandshake::new(&pk, &hello, &challenge).unwrap();
    let proof_d = hs.device_proof().unwrap();
    let proof_h = hs.host_proof(&proof_d).unwrap();
    assert_eq!(
        ControlMessage::SessionProof { proof: proof_d },
        decode(&msgs["SESSION_PROOF"])
    );
    assert_eq!(
        ControlMessage::SessionAccept { proof: proof_h },
        decode(&msgs["SESSION_ACCEPT"])
    );
    assert!(hs.verify_device_proof(&proof_d));
    assert!(hs.verify_host_proof(&proof_d, &proof_h));
    let mut wrong = proof_d;
    wrong[31] ^= 0x80;
    assert!(!hs.verify_device_proof(&wrong));
    assert!(!hs.verify_host_proof(&wrong, &proof_h));

    let keys = hs.keys().unwrap();
    assert_eq!(keys.k_d2h.to_vec(), hex(s["k_d2h"].as_str().unwrap()));
    assert_eq!(keys.k_h2d.to_vec(), hex(s["k_h2d"].as_str().unwrap()));

    // The derived keys authenticate the session's first datagram.
    let host = Endpoint::new(Role::Host, keys.session_id, &keys.k_d2h, &keys.k_h2d).unwrap();
    let first_pose = hex(msgs["first_POSE_udp"].as_str().unwrap());
    let pose = host.open(&first_pose).unwrap();
    assert!(matches!(pose, Message::Pose(p) if p.seq == 1));
    // A different pairing key yields keys that don't.
    let other = SessionHandshake::new(&[0u8; 32], &hello, &challenge)
        .unwrap()
        .keys()
        .unwrap();
    let host2 = Endpoint::new(Role::Host, other.session_id, &other.k_d2h, &other.k_h2d).unwrap();
    assert!(
        host2
            .open(&hex(msgs["first_POSE_udp"].as_str().unwrap()))
            .is_err()
    );
}

#[test]
fn control_frames_from_messages_json_roundtrip() {
    let m = load("messages.json");
    let tcp: Vec<&Value> = m["cases"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["channel"] == "tcp")
        .collect();
    assert_eq!(tcp.len(), 2);
    for case in tcp {
        match decode(&case["hex"]) {
            ControlMessage::Hello(h) => {
                assert_eq!(
                    h.device_name,
                    case["fields"]["device_name"].as_str().unwrap()
                );
                assert_eq!(u64::from(h.mode), case["fields"]["mode"].as_u64().unwrap());
            }
            ControlMessage::Error(e) => {
                assert_eq!(u64::from(e.code), case["fields"]["code"].as_u64().unwrap());
                assert_eq!(e.message, case["fields"]["message"].as_str().unwrap());
            }
            other => panic!("unexpected {other:?}"),
        }
    }
}

#[test]
fn malformed_control_frames_are_rejected() {
    let hello = hex(load("pairing.json")["messages"]["HELLO"].as_str().unwrap());
    let with = |f: &dyn Fn(&mut Vec<u8>)| {
        let mut b = hello.clone();
        f(&mut b);
        ControlMessage::decode(&b)
    };
    assert_eq!(with(&|b| b.truncate(11)), Err(ControlError::Frame));
    assert_eq!(with(&|b| b.truncate(b.len() - 1)), Err(ControlError::Frame));
    assert_eq!(with(&|b| b[0] = b'X'), Err(ControlError::Frame));
    assert_eq!(with(&|b| b[4] = 2), Err(ControlError::Version));
    assert_eq!(
        with(&|b| b[6] = 1),
        Err(ControlError::Frame),
        "session_id must be 0 on TCP"
    );
    assert_eq!(with(&|b| b[5] = 0x4E), Err(ControlError::UnknownType));
    assert_eq!(
        with(&|b| b[10..12].copy_from_slice(&4097u16.to_le_bytes())),
        Err(ControlError::Frame)
    );
    // Name length byte pointing past the end.
    assert_eq!(with(&|b| b[12 + 36] = 200), Err(ControlError::Payload));
    // Header-only length check for stream readers.
    assert_eq!(ControlMessage::frame_len(&hello[..12]), Ok(hello.len()));
    // Every prefix and every byte flip: never panics.
    for n in 0..hello.len() {
        let _ = ControlMessage::decode(&hello[..n]);
    }
    for i in 0..hello.len() {
        let mut b = hello.clone();
        b[i] ^= 0xFF;
        let _ = ControlMessage::decode(&b);
    }
}
