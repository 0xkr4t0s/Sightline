import Foundation

/// VCP v1 TCP control channel (docs/protocol/vcp.md §9–§11): `HELLO`, pairing, session setup and
/// `ERROR`. A frame is the §4.1 header with `session_id` 0 followed by the payload; no trailer.
nonisolated enum VCPControlType {
    static let hello: UInt8 = 0x40
    static let pairChallenge: UInt8 = 0x41
    static let pairProof: UInt8 = 0x42
    static let pairAccept: UInt8 = 0x43
    static let sessionChallenge: UInt8 = 0x44
    static let sessionProof: UInt8 = 0x45
    static let sessionAccept: UInt8 = 0x46
    static let error: UInt8 = 0x4F
}

/// Why a control frame was rejected or couldn't be built.
nonisolated enum VCPControlError: Error, Equatable, Sendable {
    /// Header malformed: size, magic, `session_id` ≠ 0, or `len` inconsistent or over 4096.
    case frame
    /// Not VCP version 1 (the connection answers `ERROR` 1).
    case version
    /// Unknown control type.
    case unknownType
    /// Payload too short for its type, or a string is over its limit or not valid UTF-8.
    case payload
    /// Encoding only: a string over its limit, or a fixed-size field of the wrong length.
    case field
}

/// `HELLO` (0x40), device → host, 37 + name bytes (§9.3).
nonisolated struct VCPHello: Equatable, Sendable {
    static let modePair: UInt8 = 0
    static let modeSession: UInt8 = 1
    static let maxName = 64

    var mode: UInt8
    var protoMin: UInt8 = 1
    var protoMax: UInt8 = 1
    /// 16 bytes, generated once per install.
    var deviceID: [UInt8]
    /// 16 fresh random bytes per `HELLO`.
    var nonceD: [UInt8]
    var deviceName: String
}

/// `PAIR_CHALLENGE` (0x41), host → device, 416 bytes (§9.3).
nonisolated struct VCPPairChallenge: Equatable, Sendable {
    var hostID: [UInt8]
    var salt: [UInt8]
    /// `PAD(B)`, big-endian, 384 bytes.
    var bPub: [UInt8]
}

/// `PAIR_PROOF` (0x42), device → host, 416 bytes (§9.3).
nonisolated struct VCPPairProof: Equatable, Sendable {
    /// `PAD(A)`, big-endian, 384 bytes.
    var aPub: [UInt8]
    var m1: [UInt8]
}

/// `SESSION_CHALLENGE` (0x44), host → device, 40 bytes (§10.1).
nonisolated struct VCPSessionChallenge: Equatable, Sendable {
    var hostID: [UInt8]
    var nonceH: [UInt8]
    var sessionID: UInt32
    var udpPort: UInt16
}

/// `ERROR` (0x4F), either direction (§11). The sender closes the connection after it.
nonisolated struct VCPControlErrorMessage: Equatable, Sendable {
    static let unsupportedVersion: UInt16 = 1
    static let proofFailed: UInt16 = 2
    static let notPaired: UInt16 = 3
    static let busy: UInt16 = 4
    static let pairingDisabled: UInt16 = 5
    static let malformed: UInt16 = 6
    static let maxMessage = 127

    var code: UInt16
    var message: String
}

/// Any v1 control message.
nonisolated enum VCPControlMessage: Equatable, Sendable {
    case hello(VCPHello)
    case pairChallenge(VCPPairChallenge)
    case pairProof(VCPPairProof)
    case pairAccept(m2: [UInt8])
    case sessionChallenge(VCPSessionChallenge)
    case sessionProof([UInt8])
    case sessionAccept([UInt8])
    case error(VCPControlErrorMessage)

    /// Largest TCP payload in v1 (§3).
    static let maxPayload = 4096
    /// `PAD(A)` / `PAD(B)` length for the 3072-bit group.
    static let srpPublicLength = 384
    static let idLength = 16
    static let proofLength = 32

    var type: UInt8 {
        switch self {
        case .hello: VCPControlType.hello
        case .pairChallenge: VCPControlType.pairChallenge
        case .pairProof: VCPControlType.pairProof
        case .pairAccept: VCPControlType.pairAccept
        case .sessionChallenge: VCPControlType.sessionChallenge
        case .sessionProof: VCPControlType.sessionProof
        case .sessionAccept: VCPControlType.sessionAccept
        case .error: VCPControlType.error
        }
    }

    /// The payload bytes: what the pairing and session transcripts hash (§9.3, §10.2).
    func payload() throws(VCPControlError) -> [UInt8] {
        var out: [UInt8] = []
        switch self {
        case let .hello(h):
            out.append(contentsOf: [h.mode, h.protoMin, h.protoMax, 0])
            try Self.fixed(h.deviceID, Self.idLength, into: &out)
            try Self.fixed(h.nonceD, Self.idLength, into: &out)
            try Self.str8(h.deviceName, max: VCPHello.maxName, into: &out)
        case let .pairChallenge(c):
            try Self.fixed(c.hostID, Self.idLength, into: &out)
            try Self.fixed(c.salt, Self.idLength, into: &out)
            try Self.fixed(c.bPub, Self.srpPublicLength, into: &out)
        case let .pairProof(p):
            try Self.fixed(p.aPub, Self.srpPublicLength, into: &out)
            try Self.fixed(p.m1, Self.proofLength, into: &out)
        case let .pairAccept(v), let .sessionProof(v), let .sessionAccept(v):
            try Self.fixed(v, Self.proofLength, into: &out)
        case let .sessionChallenge(c):
            try Self.fixed(c.hostID, Self.idLength, into: &out)
            try Self.fixed(c.nonceH, Self.idLength, into: &out)
            out.appendLE(c.sessionID)
            out.appendLE(c.udpPort)
            out.appendLE(UInt16(0))
        case let .error(e):
            out.appendLE(e.code)
            out.appendLE(UInt16(0))
            try Self.str8(e.message, max: VCPControlErrorMessage.maxMessage, into: &out)
        }
        return out
    }

    /// One complete frame: header (`session_id` 0) ‖ payload.
    func encode() throws(VCPControlError) -> [UInt8] {
        let payload = try payload()
        var out = VCPEndpoint.magic
        out.append(VCPEndpoint.version)
        out.append(type)
        out.appendLE(UInt32(0))
        out.appendLE(UInt16(payload.count))  // ≤ 416 + 1 + 127 by construction
        out.append(contentsOf: payload)
        return out
    }

    /// Total frame length announced by a 12-byte header. A stream reader reads 12 bytes, calls
    /// this, reads the rest, then passes the whole frame to `decode`. Nothing over 4096 is accepted.
    static func frameLength(header: ArraySlice<UInt8>) throws(VCPControlError) -> Int {
        var r = VCPReader(header)
        guard let magic = r.bytes(4), let version = r.u8(), r.skip(1), let sid = r.u32(), let len = r.u16(),
              Array(magic) == VCPEndpoint.magic, sid == 0, Int(len) <= maxPayload
        else { throw .frame }
        guard version == VCPEndpoint.version else { throw .version }
        return VCPEndpoint.headerLength + Int(len)
    }

    /// Decodes exactly one complete frame. Payloads longer than the v1 layout are accepted and the
    /// extra bytes ignored (§2).
    static func decode(_ frame: [UInt8]) throws(VCPControlError) -> VCPControlMessage {
        let f = frame[...]
        guard f.count >= VCPEndpoint.headerLength else { throw .frame }
        guard try frameLength(header: f.prefix(VCPEndpoint.headerLength)) == f.count else { throw .frame }
        var r = VCPReader(f.dropFirst(VCPEndpoint.headerLength))
        let message: VCPControlMessage?
        switch f[f.startIndex + 5] {
        case VCPControlType.hello:
            message = if let mode = r.u8(), let lo = r.u8(), let hi = r.u8(), r.skip(1),
                         let id = r.bytes(idLength), let nonce = r.bytes(idLength),
                         let name = str8(&r, max: VCPHello.maxName) {
                .hello(VCPHello(mode: mode, protoMin: lo, protoMax: hi, deviceID: Array(id), nonceD: Array(nonce),
                                deviceName: name))
            } else { nil }
        case VCPControlType.pairChallenge:
            message = if let id = r.bytes(idLength), let salt = r.bytes(idLength), let b = r.bytes(srpPublicLength) {
                .pairChallenge(VCPPairChallenge(hostID: Array(id), salt: Array(salt), bPub: Array(b)))
            } else { nil }
        case VCPControlType.pairProof:
            message = if let a = r.bytes(srpPublicLength), let m1 = r.bytes(proofLength) {
                .pairProof(VCPPairProof(aPub: Array(a), m1: Array(m1)))
            } else { nil }
        case VCPControlType.pairAccept:
            message = r.bytes(proofLength).map { .pairAccept(m2: Array($0)) }
        case VCPControlType.sessionChallenge:
            message = if let id = r.bytes(idLength), let nonce = r.bytes(idLength), let sid = r.u32(),
                         let port = r.u16(), r.skip(2) {
                .sessionChallenge(VCPSessionChallenge(hostID: Array(id), nonceH: Array(nonce), sessionID: sid,
                                                      udpPort: port))
            } else { nil }
        case VCPControlType.sessionProof:
            message = r.bytes(proofLength).map { .sessionProof(Array($0)) }
        case VCPControlType.sessionAccept:
            message = r.bytes(proofLength).map { .sessionAccept(Array($0)) }
        case VCPControlType.error:
            message = if let code = r.u16(), r.skip(2), let text = str8(&r, max: VCPControlErrorMessage.maxMessage) {
                .error(VCPControlErrorMessage(code: code, message: text))
            } else { nil }
        default:
            throw .unknownType
        }
        guard let message else { throw .payload }
        return message
    }

    private static func fixed(_ bytes: [UInt8], _ length: Int, into out: inout [UInt8]) throws(VCPControlError) {
        guard bytes.count == length else { throw .field }
        out.append(contentsOf: bytes)
    }

    private static func str8(_ s: String, max: Int, into out: inout [UInt8]) throws(VCPControlError) {
        let bytes = Array(s.utf8)
        guard bytes.count <= max else { throw .field }
        out.append(UInt8(bytes.count))
        out.append(contentsOf: bytes)
    }

    private static func str8(_ r: inout VCPReader, max: Int) -> String? {
        guard let length = r.u8(), Int(length) <= max, let bytes = r.bytes(Int(length)) else { return nil }
        return String(validating: bytes, as: UTF8.self)
    }
}
