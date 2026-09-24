//! Fuzz the peer-controlled pairing inputs (vcp.md §9): arbitrary `PAIR_PROOF` bytes against a
//! fixed host, and arbitrary `PAIR_CHALLENGE` bytes against the device. Property: never panics,
//! and a proof with an arbitrary `M1` is never accepted (a 2^-256 event).
#![no_main]

use std::sync::LazyLock;

use libfuzzer_sys::fuzz_target;
use vcam_protocol::{Hello, HostPairing, PairChallenge, PairProof, SRP_PUBLIC_LEN, device_pair};

const CODE: &str = "042917";

static HELLO: LazyLock<Hello> = LazyLock::new(|| Hello {
    mode: Hello::MODE_PAIR,
    proto_min: 1,
    proto_max: 1,
    device_id: [0x00; 16],
    nonce_d: [0xA5; 16],
    device_name: "fuzz".to_owned(),
});
static HOST: LazyLock<HostPairing> = LazyLock::new(|| {
    HostPairing::new(CODE, &HELLO, [0xF0; 16], [0xB0; 16], &[0x42; 32]).expect("valid fixed inputs")
});

/// Takes `N` bytes from `data`, zero-filling if it runs out.
fn take<const N: usize>(data: &mut &[u8]) -> [u8; N] {
    let mut out = [0u8; N];
    let n = data.len().min(N);
    out[..n].copy_from_slice(&data[..n]);
    *data = &data[n..];
    out
}

fuzz_target!(|data: &[u8]| {
    let mut rest = data;
    let Some((&selector, tail)) = rest.split_first() else {
        return;
    };
    rest = tail;
    if selector & 1 == 0 {
        let proof = PairProof {
            a_pub: take::<SRP_PUBLIC_LEN>(&mut rest),
            m1: take::<32>(&mut rest),
        };
        assert!(
            HOST.verify(&proof).is_err(),
            "an arbitrary M1 must not verify"
        );
    } else {
        let challenge = PairChallenge {
            host_id: take::<16>(&mut rest),
            salt: take::<16>(&mut rest),
            b_pub: take::<SRP_PUBLIC_LEN>(&mut rest),
        };
        let a = take::<32>(&mut rest);
        let _ = device_pair(CODE, &HELLO, &challenge, &a);
    }
});
