//! Fuzz `Endpoint::open` (vcp.md §4.3) from both roles. Property: never panics, and anything
//! it accepts round-trips: `open(seal(msg)) == msg`.
#![no_main]

use std::sync::LazyLock;

use libfuzzer_sys::fuzz_target;
use vcam_protocol::{Endpoint, Role};

const SID: u32 = 0x1234_ABCD;
const K_D2H: [u8; 32] = [0x11; 32];
const K_H2D: [u8; 32] = [0x22; 32];

static HOST: LazyLock<Endpoint> =
    LazyLock::new(|| Endpoint::new(Role::Host, SID, &K_D2H, &K_H2D).expect("sid != 0"));
static DEVICE: LazyLock<Endpoint> =
    LazyLock::new(|| Endpoint::new(Role::Device, SID, &K_D2H, &K_H2D).expect("sid != 0"));

fuzz_target!(|data: &[u8]| {
    for (rx, tx) in [(&*HOST, &*DEVICE), (&*DEVICE, &*HOST)] {
        if let Ok(msg) = rx.open(data) {
            let mut out = Vec::new();
            tx.seal(&msg, &mut out)
                .expect("an accepted message must re-seal");
            assert_eq!(rx.open(&out).expect("re-sealed message must open"), msg);
        }
    }
});
