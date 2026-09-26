import Foundation

/// The fields every fragment of one frame repeats (docs/protocol/vcp.md §6.5).
nonisolated struct VCPVideoFrameInfo: Equatable, Sendable {
    /// Strictly increasing within the session, starting at 1; gaps are allowed.
    var frameID: UInt32
    /// Host clock when Blender drew the frame.
    var renderTimeNs: UInt64
    /// `POSE.seq` on the camera when the frame was drawn (0 = none).
    var poseSeq: UInt32
    var codec: UInt8 = VCPVideoFragment.codecJPEG
    var color: UInt8 = VCPVideoFragment.colorSRGBRec709
    /// JPEG quality 1–100, for display only (NET-VID-005); 0 = not stated.
    var quality: UInt8
    /// Reserved, 0.
    var flags: UInt8 = 0
}

/// `VIDEO_FRAGMENT` (0x05), host → device (§6.5): one datagram's share of an encoded frame.
/// `data` is a slice of the received datagram, so decoding doesn't copy it.
nonisolated struct VCPVideoFragment: Equatable, Sendable {
    static let headerLength = 32
    /// Largest `frag_size`: 1200 − 12 (header) − 8 (tag) − 32.
    static let maxData = 1148
    /// Largest encoded frame (4 MiB); a receiver never buffers more.
    static let maxFrameLength: UInt32 = 4 * 1024 * 1024
    static let codecJPEG: UInt8 = 1
    static let colorSRGBRec709: UInt8 = 0

    var frame: VCPVideoFrameInfo
    var frameLength: UInt32
    var fragIndex: UInt16
    var fragCount: UInt16
    var fragSize: UInt16
    /// Bytes `fragIndex × fragSize` onward of the encoded frame.
    var data: ArraySlice<UInt8>

    /// Decodes and validates one payload (§6.5 Validation). Bytes after `data` are ignored (§2).
    static func decode(_ payload: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPVideoFragment {
        var r = VCPReader(payload)
        guard let frameID = r.u32(), let frameLength = r.u32(), let fragIndex = r.u16(), let fragCount = r.u16(),
              let fragSize = r.u16(), let codec = r.u8(), let color = r.u8(), let renderTime = r.u64(),
              let poseSeq = r.u32(), let quality = r.u8(), let flags = r.u8(), r.skip(2)
        else { throw .tooShort }
        var fragment = VCPVideoFragment(
            frame: VCPVideoFrameInfo(frameID: frameID, renderTimeNs: renderTime, poseSeq: poseSeq, codec: codec,
                                     color: color, quality: quality, flags: flags),
            frameLength: frameLength, fragIndex: fragIndex, fragCount: fragCount, fragSize: fragSize, data: [])
        guard let data = r.bytes(try fragment.dataLength()) else { throw .tooShort }
        fragment.data = data
        return fragment
    }

    /// Fails unless a receiver would accept the fragment, `data` length included.
    func encode(into out: inout [UInt8]) throws(VCPPayloadError) {
        guard data.count == (try dataLength()) else { throw .fragmentLayout }
        out.appendLE(frame.frameID)
        out.appendLE(frameLength)
        out.appendLE(fragIndex)
        out.appendLE(fragCount)
        out.appendLE(fragSize)
        out.append(frame.codec)
        out.append(frame.color)
        out.appendLE(frame.renderTimeNs)
        out.appendLE(frame.poseSeq)
        out.append(contentsOf: [frame.quality, frame.flags, 0, 0])
        out.append(contentsOf: data)
    }

    /// Data bytes a fragment with these fields carries, or why the fields are invalid.
    private func dataLength() throws(VCPPayloadError) -> Int {
        let size = UInt32(fragSize)
        guard frame.frameID != 0, (1...Self.maxFrameLength).contains(frameLength),
              (1...UInt16(Self.maxData)).contains(fragSize),
              (frameLength + size - 1) / size == UInt32(fragCount), fragIndex < fragCount
        else { throw .fragmentLayout }
        guard frame.codec == Self.codecJPEG, frame.color == Self.colorSRGBRec709 else { throw .videoFormat }
        // fragIndex < fragCount = ⌈frameLength / size⌉, so the offset is below frameLength.
        return Int(min(size, frameLength - UInt32(fragIndex) * size))
    }

    /// The fields that must match across one frame's fragments (all but index and data).
    fileprivate var key: VCPVideoFrameKey {
        VCPVideoFrameKey(frame: frame, frameLength: frameLength, fragCount: fragCount, fragSize: fragSize)
    }
}

private nonisolated struct VCPVideoFrameKey: Equatable {
    var frame: VCPVideoFrameInfo
    var frameLength: UInt32
    var fragCount: UInt16
    var fragSize: UInt16
}

/// `VIDEO_REPORT` (0x07), 16 bytes, device → host (§6.6): how the viewfinder stream is arriving,
/// as session totals, so a lost report loses nothing (NET-VID-005).
nonisolated struct VCPVideoReport: Equatable, Sendable {
    static let length = 16

    /// +1 per report, starting at 1; the host keeps only newer ones.
    var reportSeq: UInt32
    /// The reassembly's `newest`: highest `frame_id` of any valid fragment (0 = none).
    var newestFrameID: UInt32
    /// Frames completed this session; never above `newestFrameID`.
    var framesComplete: UInt32
    /// Motion-to-photon p95 since the previous report, in ms; 0 = not measured, 65535 = at least.
    var m2pP95Ms: UInt16

    static func decode(_ payload: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPVideoReport {
        var r = VCPReader(payload)
        guard let seq = r.u32(), let newest = r.u32(), let complete = r.u32(), let m2p = r.u16(), r.skip(2)
        else { throw .tooShort }
        let report = VCPVideoReport(reportSeq: seq, newestFrameID: newest, framesComplete: complete, m2pP95Ms: m2p)
        try report.check()
        return report
    }

    /// Fails for counts a receiver would drop.
    func encode(into out: inout [UInt8]) throws(VCPPayloadError) {
        try check()
        out.appendLE(reportSeq)
        out.appendLE(newestFrameID)
        out.appendLE(framesComplete)
        out.appendLE(m2pP95Ms)
        out.appendLE(UInt16(0))
    }

    /// Each completed frame has its own `frame_id` in 1...`newestFrameID` (§6.6).
    private func check() throws(VCPPayloadError) {
        guard framesComplete <= newestFrameID else { throw .reportCounts }
    }
}

/// Device-side reassembly (§6.5): at most one frame in progress, newest `frame_id` wins
/// (NET-VID-001). One per session. The buffers are reused, so steady-state pushes don't allocate.
nonisolated struct VCPVideoReassembler: Sendable {
    /// What `push` did with a fragment (§6.5 Reassembly).
    enum Outcome: Equatable, Sendable {
        /// Stored; the frame still misses fragments.
        case pending
        /// Stored, and it was the frame's last missing fragment: `frame` is ready to decode.
        case complete
        /// From a frame older than the newest one (rule 1).
        case stale
        /// Its index already arrived for the frame in progress (rule 3).
        case duplicate
        /// Its frame is already complete or abandoned (rule 3).
        case done
        /// Its frame fields differ from the frame's: the frame is abandoned (rule 3).
        case inconsistent
    }

    /// Counters for the HUD and `VIDEO_REPORT` (NET-VID-005).
    struct Stats: Equatable, Sendable {
        /// Frames handed to the decoder.
        var complete: UInt64 = 0
        /// Frames abandoned incomplete: superseded by a newer frame, or inconsistent.
        var lost: UInt64 = 0
        var stale: UInt64 = 0
        var duplicate: UInt64 = 0
        var done: UInt64 = 0
        var inconsistent: UInt64 = 0
    }

    /// Highest `frame_id` accepted in the session (0 = none yet).
    private(set) var newest: UInt32 = 0
    private(set) var stats = Stats()
    /// The newest frame's fields; `nil` before the first fragment.
    private var current: VCPVideoFrameKey?
    private var state = State.open
    private var buffer: [UInt8] = []
    private var have: [Bool] = []
    private var missing = 0

    private enum State {
        case open, complete, abandoned
    }

    /// The newest frame once `push` returned `.complete`: its fields and its `frame_len` bytes.
    /// Valid until the next `push`; `nil` while the newest frame is incomplete or abandoned.
    var frame: (info: VCPVideoFrameInfo, data: ArraySlice<UInt8>)? {
        guard let current, state == .complete else { return nil }
        return (current.frame, buffer[...])
    }

    /// This session's `VIDEO_REPORT` totals (§6.6) with the caller's sequence number and
    /// motion-to-photon p95 (0 = not measured).
    func report(seq: UInt32, m2pP95Ms: UInt16) -> VCPVideoReport {
        // Every completed frame has a distinct id ≤ newest, so this never clamps.
        VCPVideoReport(reportSeq: seq, newestFrameID: newest,
                       framesComplete: UInt32(clamping: min(stats.complete, UInt64(newest))), m2pP95Ms: m2pP95Ms)
    }

    /// Feeds one validated fragment (from `VCPEndpoint.open`).
    mutating func push(_ fragment: VCPVideoFragment) -> Outcome {
        let key = fragment.key
        let id = fragment.frame.frameID
        if id < newest {
            stats.stale += 1
            return .stale
        }
        if id > newest {
            if current != nil, state == .open { stats.lost += 1 }
            start(fragment, key: key)
        } else {
            guard let current, state == .open else {
                stats.done += 1
                return .done
            }
            let index = Int(fragment.fragIndex)
            if index < have.count, have[index] {
                stats.duplicate += 1
                return .duplicate
            }
            if current != key {
                state = .abandoned
                stats.lost += 1
                stats.inconsistent += 1
                return .inconsistent
            }
        }
        let index = Int(fragment.fragIndex)
        let offset = index * Int(fragment.fragSize)
        buffer.replaceSubrange(offset..<offset + fragment.data.count, with: fragment.data)
        have[index] = true
        missing -= 1
        if missing > 0 { return .pending }
        state = .complete
        stats.complete += 1
        return .complete
    }

    private mutating func start(_ fragment: VCPVideoFragment, key: VCPVideoFrameKey) {
        newest = fragment.frame.frameID
        current = key
        state = .open
        // Old bytes left in `buffer` are never exposed: the fragments tile [0, frame_len) exactly,
        // and the frame completes only after every one of them has been copied in.
        let length = Int(fragment.frameLength)
        if buffer.count > length {
            buffer.removeLast(buffer.count - length)
        } else {
            buffer.append(contentsOf: repeatElement(0, count: length - buffer.count))
        }
        have.removeAll(keepingCapacity: true)
        have.append(contentsOf: repeatElement(false, count: Int(fragment.fragCount)))
        missing = Int(fragment.fragCount)
    }
}
