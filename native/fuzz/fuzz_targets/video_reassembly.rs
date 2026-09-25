//! Fuzz the device-side `VIDEO_FRAGMENT` reassembler (vcp.md §6.5) against a plain model of the
//! spec's six steps. Each 7-byte record builds one small valid fragment, so the fuzzer explores
//! orderings, duplicates, gaps and header changes rather than layout errors (`udp_open` covers
//! those). Properties: never panics; every outcome and every completed frame matches the model.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vcam_protocol::{FragmentOutcome, FrameInfo, Reassembler, VideoFragment, fragment_count};

/// The spec's reassembly steps, written as directly as possible.
#[derive(Default)]
struct Model {
    floor: u32,
    current: Option<(u32, (FrameInfo, u32, u16), Vec<Option<Vec<u8>>>)>,
}

impl Model {
    fn push(&mut self, f: &VideoFragment) -> (&'static str, Option<Vec<u8>>) {
        let id = f.frame.frame_id;
        let key = (f.frame, f.frame_len, f.chunk_len);
        if id <= self.floor || self.current.as_ref().is_some_and(|c| id < c.0) {
            return ("stale", None);
        }
        if let Some(c) = self.current.take_if(|c| id > c.0) {
            self.floor = c.0;
        }
        let count = fragment_count(f.frame_len, f.chunk_len).expect("valid fragment");
        let (_, cur_key, parts) = self
            .current
            .get_or_insert_with(|| (id, key, vec![None; count as usize]));
        if *cur_key != key {
            self.floor = id;
            self.current = None;
            return ("inconsistent", None);
        }
        let slot = &mut parts[usize::from(f.frag_index)];
        if slot.is_some() {
            return ("duplicate", None);
        }
        *slot = Some(f.data.clone());
        if parts.iter().any(Option::is_none) {
            return ("pending", None);
        }
        let data = parts.iter().flatten().flatten().copied().collect();
        self.floor = id;
        self.current = None;
        ("complete", Some(data))
    }
}

fuzz_target!(|data: &[u8]| {
    let (mut real, mut model) = (Reassembler::new(), Model::default());
    for r in data.chunks_exact(7) {
        let frame_len = u32::from(r[1] % 24) + 1;
        let chunk_len = u16::from(r[2] % 6) + 1;
        let count = fragment_count(frame_len, chunk_len).expect("small layout");
        let frag_index = u16::try_from(u32::from(r[3]) % count).expect("count <= 24");
        let start = u32::from(frag_index) * u32::from(chunk_len);
        let len = (frame_len - start).min(u32::from(chunk_len));
        let frag = VideoFragment {
            frame: FrameInfo {
                frame_id: u32::from(r[0] % 6) + 1,
                render_time_ns: u64::from(r[4] % 2),
                pose_seq: u32::from(r[5] % 2),
                codec: 0,
                flags: 1,
            },
            frame_len,
            chunk_len,
            frag_index,
            data: vec![r[6]; len as usize],
        };
        let (want, want_frame) = model.push(&frag);
        let (got, got_frame) = match real.push(&frag) {
            FragmentOutcome::Pending => ("pending", None),
            FragmentOutcome::Complete(f) => ("complete", Some(f.data)),
            FragmentOutcome::Stale => ("stale", None),
            FragmentOutcome::Duplicate => ("duplicate", None),
            FragmentOutcome::Inconsistent => ("inconsistent", None),
            FragmentOutcome::Invalid => ("invalid", None),
        };
        assert_eq!(got, want);
        assert_eq!(got_frame, want_frame);
    }
});
