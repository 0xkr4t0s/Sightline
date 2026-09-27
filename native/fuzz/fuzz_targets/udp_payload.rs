//! Fuzz the UDP payload decoders behind the tag check (vcp.md §4.3 steps 7–8, §6), which
//! `udp_open` rarely reaches because it would have to forge an HMAC. Input: a type byte, then
//! the payload. Properties: never panics; an accepted message seals and opens to itself; extra
//! trailing bytes after an accepted `CONTROL_STATE` or `STATUS` change nothing (§2).
#![no_main]

use libfuzzer_sys::fuzz_target;
use vcam_protocol::{Endpoint, Message, Role, decode_payload};

fuzz_target!(|data: &[u8]| {
    let Some((&msg_type, payload)) = data.split_first() else {
        return;
    };
    let Ok(msg) = decode_payload(msg_type, payload) else {
        return;
    };
    let host = Endpoint::new(Role::Host, 1, &[0x11; 32], &[0x22; 32]).expect("sid != 0");
    let device = Endpoint::new(Role::Device, 1, &[0x11; 32], &[0x22; 32]).expect("sid != 0");
    let mut out = Vec::new();
    let (tx, rx) = if host.seal(&msg, &mut out).is_ok() {
        (&host, &device)
    } else {
        (&device, &host)
    };
    out.clear();
    if tx.seal(&msg, &mut out).is_ok() {
        assert_eq!(rx.open(&out).expect("a sealed message must open"), msg);
    }
    if matches!(msg, Message::ControlState(_) | Message::Status(_)) {
        let mut longer = payload.to_vec();
        longer.extend_from_slice(&[0xFF; 16]);
        assert_eq!(decode_payload(msg_type, &longer), Ok(msg));
    }
});
