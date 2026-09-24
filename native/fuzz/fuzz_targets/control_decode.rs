//! Fuzz TCP control-frame parsing (vcp.md §9–§11). Property: never panics; `frame_len` agrees
//! with `decode`; anything accepted round-trips through `encode`.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vcam_protocol::ControlMessage;

fuzz_target!(|data: &[u8]| {
    let header_len = data.get(..12).map(ControlMessage::frame_len);
    if let Ok(msg) = ControlMessage::decode(data) {
        assert_eq!(
            header_len,
            Some(Ok(data.len())),
            "decoded frame must have a consistent header"
        );
        let encoded = msg.encode().expect("an accepted message must re-encode");
        assert_eq!(
            ControlMessage::decode(&encoded).expect("re-encoded frame must decode"),
            msg
        );
    }
});
