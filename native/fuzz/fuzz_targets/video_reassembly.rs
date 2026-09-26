//! Fuzz `VideoFragment::decode` and `Reassembler::push` (vcp.md §6.5). Input: fragment payloads,
//! each prefixed by a length byte. Properties: never panics; an accepted fragment re-encodes
//! and decodes to itself; a complete frame has `frame_len` bytes and is never followed by a
//! second completion of the same `frame_id`.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vcam_protocol::{Endpoint, Message, Pushed, Reassembler, Role, VideoFragment};

fuzz_target!(|data: &[u8]| {
    let host = Endpoint::new(Role::Host, 1, &[0x11; 32], &[0x22; 32]).expect("sid != 0");
    let device = Endpoint::new(Role::Device, 1, &[0x11; 32], &[0x22; 32]).expect("sid != 0");
    let mut reassembler = Reassembler::new();
    let mut last_complete = 0u32;
    let mut out = Vec::new();
    let mut rest = data;
    while let Some((&n, tail)) = rest.split_first() {
        let (payload, next) = tail.split_at(usize::from(n).min(tail.len()));
        rest = next;
        let Ok(frag) = VideoFragment::decode(payload) else {
            continue;
        };
        out.clear();
        host.seal(&Message::VideoFragment(frag), &mut out)
            .expect("an accepted fragment must seal");
        assert_eq!(
            device.open(&out).expect("a sealed fragment must open"),
            Message::VideoFragment(frag)
        );
        if let Pushed::Complete(c) = reassembler.push(&frag) {
            assert_eq!(c.data.len(), frag.frame_len as usize);
            assert!(c.frame.frame_id > last_complete);
            last_complete = c.frame.frame_id;
        }
    }
});
