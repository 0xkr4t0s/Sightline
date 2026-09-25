import Foundation

/// VCP v1 UDP message payloads (docs/protocol/vcp.md §6). Decoding is exact: the values are
/// the binary32/integers on the wire. Validation follows §6 and rejects rather than clamps.
nonisolated enum VCPMessageType {
    static let pose: UInt8 = 0x01
    static let controlState: UInt8 = 0x02
    static let clock: UInt8 = 0x03
    static let status: UInt8 = 0x04
}

/// Why a payload was rejected after the frame checks passed (§4.3 step 8, §6).
nonisolated enum VCPPayloadError: Error, Equatable, Sendable {
    case tooShort
    case nonFinite
    case quaternionNorm
    case motionScaleRange
    case badName
}

/// `POSE` (0x01), 42 bytes (§6.1). Position and orientation are in canonical axes (§7).
nonisolated struct VCPPose: Equatable, Sendable {
    static let length = 42
    static let trackingNormal: UInt8 = 5

    var seq: UInt32
    var captureTimeNs: UInt64
    var position: SIMD3<Float>
    /// Unit quaternion x, y, z, w (the same order as `simd_quatf.vector`).
    var orientation: SIMD4<Float>
    var trackingState: UInt8
    var flags: UInt8 = 0

    static func decode(_ payload: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPPose {
        var r = VCPReader(payload)
        guard let seq = r.u32(), let time = r.u64(),
              let px = r.f32(), let py = r.f32(), let pz = r.f32(),
              let qx = r.f32(), let qy = r.f32(), let qz = r.f32(), let qw = r.f32(),
              let state = r.u8(), let flags = r.u8()
        else { throw .tooShort }
        let pose = VCPPose(seq: seq, captureTimeNs: time, position: SIMD3(px, py, pz),
                           orientation: SIMD4(qx, qy, qz, qw), trackingState: state, flags: flags)
        let all = [px, py, pz, qx, qy, qz, qw]
        guard all.allSatisfy(\.isFinite) else { throw .nonFinite }
        let norm = (pose.orientation * pose.orientation).sum().squareRoot()
        guard (0.9...1.1).contains(norm) else { throw .quaternionNorm }
        return pose
    }

    func encode(into out: inout [UInt8]) {
        out.appendLE(seq)
        out.appendLE(captureTimeNs)
        for v in [position.x, position.y, position.z, orientation.x, orientation.y, orientation.z, orientation.w] {
            out.appendLE(v.bitPattern)
        }
        out.append(trackingState)
        out.append(flags)
    }
}

/// `CONTROL_STATE` (0x02), T1 subset, 16 bytes (§6.2). Absent fields are `nil`.
nonisolated struct VCPControlState: Equatable, Sendable {
    static let length = 16
    private static let hasScale: UInt32 = 1 << 0
    private static let hasLocks: UInt32 = 1 << 1
    private static let hasEpoch: UInt32 = 1 << 2

    var stateSeq: UInt32
    var motionScale: Float?
    var lockFlags: UInt8?
    var originEpoch: UInt16?

    static func decode(_ payload: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPControlState {
        var r = VCPReader(payload)
        guard let seq = r.u32(), let fields = r.u32(), let scale = r.f32(), let locks = r.u8(),
              r.u8() != nil, let epoch = r.u16()
        else { throw .tooShort }
        let motionScale = fields & hasScale != 0 ? scale : nil
        if let s = motionScale, !(s.isFinite && (0.001...1000).contains(s)) { throw .motionScaleRange }
        return VCPControlState(stateSeq: seq, motionScale: motionScale,
                               lockFlags: fields & hasLocks != 0 ? locks : nil,
                               originEpoch: fields & hasEpoch != 0 ? epoch : nil)
    }

    func encode(into out: inout [UInt8]) {
        let fields = (motionScale == nil ? 0 : Self.hasScale) | (lockFlags == nil ? 0 : Self.hasLocks)
            | (originEpoch == nil ? 0 : Self.hasEpoch)
        out.appendLE(stateSeq)
        out.appendLE(fields)
        out.appendLE((motionScale ?? 0).bitPattern)
        out.append(lockFlags ?? 0)
        out.append(0)
        out.appendLE(originEpoch ?? 0)
    }
}

/// `CLOCK` (0x03), 28 bytes (§6.3).
nonisolated enum VCPClock: Equatable, Sendable {
    static let length = 28

    /// Host → device: `t1` = host clock at send.
    case request(t1: UInt64)
    /// Device → host: `t1` echoed; `t2`/`t3` = device clock at receive/send.
    case reply(t1: UInt64, t2: UInt64, t3: UInt64)

    /// `nil` for an unknown mode (treated as an unknown type, §4.3 step 7).
    static func decode(_ payload: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPClock? {
        var r = VCPReader(payload)
        guard let mode = r.u8(), r.skip(3), let t1 = r.u64(), let t2 = r.u64(), let t3 = r.u64()
        else { throw .tooShort }
        switch mode {
        case 0: return .request(t1: t1)
        case 1: return .reply(t1: t1, t2: t2, t3: t3)
        default: return nil
        }
    }

    func encode(into out: inout [UInt8]) {
        let (mode, t1, t2, t3): (UInt8, UInt64, UInt64, UInt64) = switch self {
        case let .request(t1): (0, t1, 0, 0)
        case let .reply(t1, t2, t3): (1, t1, t2, t3)
        }
        out.append(contentsOf: [mode, 0, 0, 0])
        out.appendLE(t1)
        out.appendLE(t2)
        out.appendLE(t3)
    }
}

/// `STATUS` (0x04), at least 16 bytes (§6.4).
nonisolated struct VCPStatus: Equatable, Sendable {
    static let minLength = 16
    static let maxName = 63

    var statusSeq: UInt32
    var appliedPoseSeq: UInt32
    var controlAck: UInt32
    var errorCode: UInt16
    var flags: UInt8
    var cameraName: String

    static func decode(_ payload: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPStatus {
        var r = VCPReader(payload)
        guard let seq = r.u32(), let applied = r.u32(), let ack = r.u32(), let error = r.u16(),
              let flags = r.u8(), let nameLength = r.u8()
        else { throw .tooShort }
        guard let nameBytes = r.bytes(Int(nameLength)) else { throw .tooShort }
        guard nameBytes.count <= maxName, let name = String(validating: nameBytes, as: UTF8.self)
        else { throw .badName }
        return VCPStatus(statusSeq: seq, appliedPoseSeq: applied, controlAck: ack, errorCode: error,
                         flags: flags, cameraName: name)
    }

    func encode(into out: inout [UInt8]) throws(VCPPayloadError) {
        let name = Array(cameraName.utf8)
        guard name.count <= Self.maxName else { throw .badName }
        out.appendLE(statusSeq)
        out.appendLE(appliedPoseSeq)
        out.appendLE(controlAck)
        out.appendLE(errorCode)
        out.append(flags)
        out.append(UInt8(name.count))
        out.append(contentsOf: name)
    }
}

/// Any v1 UDP message.
nonisolated enum VCPMessage: Equatable, Sendable {
    case pose(VCPPose)
    case controlState(VCPControlState)
    case clock(VCPClock)
    case status(VCPStatus)

    var type: UInt8 {
        switch self {
        case .pose: VCPMessageType.pose
        case .controlState: VCPMessageType.controlState
        case .clock: VCPMessageType.clock
        case .status: VCPMessageType.status
        }
    }
}

/// Newest-sequence-wins filter (§6.1, §6.2, §6.4). One per session.
nonisolated struct VCPSeqFilter: Sendable {
    private var last: UInt32?

    /// Returns `true` (and remembers `seq`) if `seq` is newer than every one accepted before.
    mutating func accept(_ seq: UInt32) -> Bool {
        if let last, seq <= last { return false }
        last = seq
        return true
    }
}

/// Bounds-checked little-endian reader: every read returns `nil` past the end.
nonisolated struct VCPReader {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    mutating func bytes(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, count <= bytes.endIndex - index else { return nil }
        defer { index += count }
        return bytes[index..<index + count]
    }

    mutating func skip(_ count: Int) -> Bool { bytes(count) != nil }

    private mutating func uint<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> T? {
        guard let raw = bytes(MemoryLayout<T>.size) else { return nil }
        return raw.reversed().reduce(T(0)) { $0 << 8 | T($1) }
    }

    mutating func u8() -> UInt8? { uint(UInt8.self) }
    mutating func u16() -> UInt16? { uint(UInt16.self) }
    mutating func u32() -> UInt32? { uint(UInt32.self) }
    mutating func u64() -> UInt64? { uint(UInt64.self) }
    mutating func f32() -> Float? { u32().map(Float.init(bitPattern:)) }
}

nonisolated extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
