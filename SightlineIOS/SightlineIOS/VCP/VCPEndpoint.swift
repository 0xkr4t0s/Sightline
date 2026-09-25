import CommonCrypto
import Foundation

/// Authenticated UDP framing for one session (docs/protocol/vcp.md §4): 12-byte header,
/// HMAC-SHA256 truncated to 8 bytes with direction keys, and the ordered receive rules of §4.3.
nonisolated enum VCPRole: Sendable {
    /// The iPhone: sends with `k_d2h`, receives with `k_h2d`.
    case device
    /// Blender: sends with `k_h2d`, receives with `k_d2h`.
    case host

    var peer: VCPRole { self == .device ? .host : .device }
}

/// Why `open` dropped a datagram: one case per §4.3 step (payload errors are §6).
nonisolated enum VCPDropReason: Error, Equatable, Sendable {
    case size, magic, version, length, session, tag, unknownType
    case payload(VCPPayloadError)
}

nonisolated enum VCPSealError: Error, Equatable, Sendable {
    case wrongDirection, tooLarge
    case payload(VCPPayloadError)
}

nonisolated struct VCPEndpoint: Sendable {
    static let magic: [UInt8] = Array("VCP1".utf8)
    static let version: UInt8 = 1
    static let headerLength = 12
    static let tagLength = 8
    static let maxDatagram = 1200

    let role: VCPRole
    let sessionID: UInt32
    private let sendKey: [UInt8]
    private let receiveKey: [UInt8]

    /// `nil` if `sessionID` is 0 (reserved, §10.1) or a key isn't 32 bytes.
    init?(role: VCPRole, sessionID: UInt32, kD2H: [UInt8], kH2D: [UInt8]) {
        guard sessionID != 0, kD2H.count == 32, kH2D.count == 32 else { return nil }
        self.role = role
        self.sessionID = sessionID
        (sendKey, receiveKey) = role == .device ? (kD2H, kH2D) : (kH2D, kD2H)
    }

    /// One complete datagram: header ‖ payload ‖ tag.
    func seal(_ message: VCPMessage) throws(VCPSealError) -> [UInt8] {
        var out: [UInt8] = []
        try seal(message, into: &out)
        return out
    }

    /// Writes one complete datagram into `out`, replacing its contents (undefined after a throw).
    /// Once `out` has `maxDatagram` capacity, sealing a POSE, CONTROL_STATE or CLOCK touches no
    /// heap: the per-pose send path allocates nothing (NFR-LAT-002).
    func seal(_ message: VCPMessage, into out: inout [UInt8]) throws(VCPSealError) {
        guard Self.maySend(role, message) else { throw .wrongDirection }
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(message.type)
        out.appendLE(sessionID)
        out.appendLE(UInt16(0))  // payload length, filled in below
        switch message {
        case let .pose(m): m.encode(into: &out)
        case let .controlState(m): m.encode(into: &out)
        case let .clock(m): m.encode(into: &out)
        case let .status(m):
            do { try m.encode(into: &out) } catch { throw .payload(error) }
        }
        let length = out.count - Self.headerLength
        guard out.count + Self.tagLength <= Self.maxDatagram else { throw .tooLarge }
        out[Self.headerLength - 2] = UInt8(truncatingIfNeeded: length)
        out[Self.headerLength - 1] = UInt8(truncatingIfNeeded: length >> 8)
        let mac = out.withUnsafeBytes { Self.mac($0, key: sendKey) }
        withUnsafeBytes(of: mac) { out.append(contentsOf: $0.prefix(Self.tagLength)) }
    }

    /// Checks one datagram against §4.3 in order and decodes it. Freshness is the caller's job.
    func open(_ datagram: [UInt8]) -> Result<VCPMessage, VCPDropReason> {
        let d = datagram[...]
        guard (Self.headerLength + Self.tagLength...Self.maxDatagram).contains(d.count) else { return .failure(.size) }
        var r = VCPReader(d)
        guard let magic = r.bytes(4), let version = r.u8(), let type = r.u8(), let sid = r.u32(), let len = r.u16()
        else { return .failure(.size) }
        guard Array(magic) == Self.magic else { return .failure(.magic) }
        guard version == Self.version else { return .failure(.version) }
        let authed = Self.headerLength + Int(len)
        guard authed + Self.tagLength == d.count else { return .failure(.length) }
        guard sid != 0, sid == sessionID else { return .failure(.session) }
        let expected = datagram.withUnsafeBytes { Self.mac(UnsafeRawBufferPointer(rebasing: $0[..<authed]), key: receiveKey) }
        guard withUnsafeBytes(of: expected, { Self.constantTimeEqual(Array($0.prefix(Self.tagLength)), Array(d[authed...])) })
        else { return .failure(.tag) }
        let payload = d[Self.headerLength..<authed]
        let message: VCPMessage
        do throws(VCPPayloadError) {
            switch type {
            case VCPMessageType.pose: message = .pose(try VCPPose.decode(payload))
            case VCPMessageType.controlState: message = .controlState(try VCPControlState.decode(payload))
            case VCPMessageType.clock:
                guard let clock = try VCPClock.decode(payload) else { return .failure(.unknownType) }
                message = .clock(clock)
            case VCPMessageType.status: message = .status(try VCPStatus.decode(payload))
            default: return .failure(.unknownType)
            }
        } catch {
            return .failure(.payload(error))
        }
        return Self.maySend(role.peer, message) ? .success(message) : .failure(.unknownType)
    }

    /// HMAC-SHA256 of `data` (§4.2; the tag is its first `tagLength` bytes). CommonCrypto's one-shot
    /// call keeps its state on the stack; CryptoKit's `HMAC` allocates 4–8 blocks per call.
    private static func mac(_ data: UnsafeRawBufferPointer, key: [UInt8]) -> (UInt64, UInt64, UInt64, UInt64) {
        var mac: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        withUnsafeMutableBytes(of: &mac) { out in
            key.withUnsafeBytes { k in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, k.count, data.baseAddress, data.count,
                       out.baseAddress)
            }
        }
        return mac
    }

    /// Compares every byte regardless of where the first difference is.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Who may send what (§5).
    private static func maySend(_ role: VCPRole, _ message: VCPMessage) -> Bool {
        switch (role, message) {
        case (.device, .pose), (.device, .controlState), (.device, .clock(.reply)),
             (.host, .status), (.host, .clock(.request)):
            true
        default:
            false
        }
    }
}
