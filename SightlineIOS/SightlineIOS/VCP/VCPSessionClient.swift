import Darwin
import Foundation
import Network
import os

// Device side of the VCP TCP control channel (docs/protocol/vcp.md §3, §9–§11): connect to
// Blender's control port, pair with a 6-digit code, and start sessions whose keys and UDP address
// the tracking pipeline uses. The frames and the crypto are `VCPControl` and `VCPPairing`; this
// file only moves them over TCP in the order the host expects.

/// Why talking to Blender's control channel failed.
nonisolated enum VCPLinkError: Error, Equatable, Sendable {
    /// TCP couldn't connect (refused, no route) or failed; the Network framework's description.
    case network(String)
    /// No answer before the handshake deadline.
    case timeout
    /// The connection closed: by the host, or by `close()` on this end.
    case closed
    /// A frame that doesn't parse, or a message the protocol doesn't allow at this point.
    case unexpected(String)
    /// The host sent `ERROR` (§11); it closes the connection after it.
    case host(code: UInt16, message: String)
    /// `SESSION_CHALLENGE` named a host this device holds no pairing key for.
    case unknownHost
    /// Pairing or session crypto failed: `M2`/`proof_h` didn't verify, an illegal SRP value, or a
    /// code that isn't 6 digits.
    case pairing(VCPPairError)

    /// One line for the status screen.
    var message: String {
        switch self {
        case let .network(detail): "Can't reach Blender: \(detail)"
        case .timeout: "Blender didn't answer in time."
        case .closed: "Blender closed the connection."
        case let .unexpected(detail): "Unexpected reply from Blender: \(detail)"
        case let .host(code, message):
            switch code {
            case VCPControlErrorMessage.notPaired, VCPControlErrorMessage.proofFailed:
                "Blender doesn't accept this iPhone's pairing (\(message)). Pair again."
            case VCPControlErrorMessage.pairingDisabled: "Pairing is off in Blender, or the code expired."
            case VCPControlErrorMessage.busy: "Blender is pairing another device."
            default: "Blender refused (error \(code)): \(message)"
            }
        case .unknownHost: "This iPhone isn't paired with that Blender. Pair again."
        case .pairing(.badCode): "The pairing code is 6 digits."
        case .pairing: "Blender's proof didn't verify: wrong code, or not the Blender you paired with."
        }
    }
}

/// This app install as Blender sees it: `device_id` (16 random bytes, generated once) and the name
/// shown in Blender's panel (≤ 64 UTF-8 bytes).
nonisolated struct VCPDeviceIdentity: Equatable, Sendable {
    var deviceID: [UInt8]
    var name: String
}

/// A pairing with one Blender install (§9): the host's `host_id` and the 32-byte pairing key `PK`.
nonisolated struct VCPHostPairing: Equatable, Sendable {
    var hostID: [UInt8]
    var pairingKey: [UInt8]
}

/// One TCP connection to Blender's control port that reads and writes whole control frames.
///
/// `withDeadline` bounds a handshake: when it passes, the connection is cancelled and the call in
/// flight throws `.timeout`. After `close()`, calls throw `.closed`.
nonisolated final class VCPControlChannel: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Sightline.VCPControlChannel")
    /// Why the connection was cancelled on this end, if it was.
    private let cancelledBecause = OSAllocatedUnfairLock<VCPLinkError?>(initialState: nil)

    init(host: String, port: UInt16) throws(VCPLinkError) {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port != .any else {
            throw .network("no host address or port")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    /// Connects. Fails at once, instead of waiting for the network to change, when the host
    /// refuses or can't be routed to: the caller decides when to retry.
    func open() async throws(VCPLinkError) {
        try await bridge { (done: @escaping @Sendable (Result<Void, VCPLinkError>) -> Void) in
            let once = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { [self] state in
                let result: Result<Void, VCPLinkError>? = switch state {
                case .ready: .success(())
                case let .waiting(error), let .failed(error): .failure(.network(error.debugDescription))
                case .cancelled: .failure(cancelReason)
                default: nil
                }
                guard let result, once.withLock({ fired in defer { fired = true }; return !fired }) else {
                    return
                }
                done(result)
            }
            connection.start(queue: queue)
        }
    }

    /// Runs `body`; if it hasn't finished after `seconds`, cancels the connection so it throws
    /// `.timeout`.
    func withDeadline<T>(_ seconds: Double, _ body: () async throws(VCPLinkError) -> T) async throws(VCPLinkError) -> T {
        let expire = DispatchWorkItem { [self] in cancel(because: .timeout) }
        queue.asyncAfter(deadline: .now() + seconds, execute: expire)
        defer { expire.cancel() }
        return try await body()
    }

    func send(_ message: VCPControlMessage) async throws(VCPLinkError) {
        let frame: [UInt8]
        do { frame = try message.encode() } catch { throw .unexpected("can't encode message \(message.type): \(error)") }
        try await bridge { (done: @escaping @Sendable (Result<Void, VCPLinkError>) -> Void) in
            connection.send(content: Data(frame), completion: .contentProcessed { [self] error in
                done(error.map { .failure(failure($0)) } ?? .success(()))
            })
        }
    }

    /// The next frame. The host's `ERROR` becomes `.host` (§11: it closes the connection after it).
    func receive() async throws(VCPLinkError) -> VCPControlMessage {
        let header = try await receive(exactly: VCPEndpoint.headerLength)
        let total: Int
        do { total = try VCPControlMessage.frameLength(header: header[...]) } catch {
            throw .unexpected("bad frame header (\(error))")
        }
        let frame = total > header.count ? header + (try await receive(exactly: total - header.count)) : header
        let message: VCPControlMessage
        do { message = try VCPControlMessage.decode(frame) } catch { throw .unexpected("bad frame (\(error))") }
        if case let .error(e) = message {
            throw .host(code: e.code, message: e.message)
        }
        return message
    }

    /// The host's numeric address on this connection. vcp.md §3: the device sends UDP to the
    /// host's TCP peer address. IPv6 link-local addresses keep their interface (`fe80::1%en0`).
    var peerAddress: String? {
        guard case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint else {
            return nil
        }
        switch host {
        case let .ipv4(address):
            return Self.numeric(AF_INET, address.rawValue)
        case let .ipv6(address):
            if let v4 = address.asIPv4 {
                return Self.numeric(AF_INET, v4.rawValue)
            }
            guard let text = Self.numeric(AF_INET6, address.rawValue) else {
                return nil
            }
            return address.interface.map { "\(text)%\($0.name)" } ?? text
        case let .name(name, _):
            return name
        @unknown default:
            return nil
        }
    }

    /// Closes the connection; pending and later calls throw `.closed`. Idempotent.
    func close() {
        cancel(because: .closed)
    }

    private func cancel(because reason: VCPLinkError) {
        cancelledBecause.withLock { $0 = $0 ?? reason }
        connection.cancel()
    }

    private var cancelReason: VCPLinkError {
        cancelledBecause.withLock { $0 } ?? .closed
    }

    /// A Network framework error, unless this end cancelled the connection (then why it did).
    private func failure(_ error: NWError) -> VCPLinkError {
        cancelledBecause.withLock { $0 } ?? .network(error.debugDescription)
    }

    private func receive(exactly count: Int) async throws(VCPLinkError) -> [UInt8] {
        try await bridge { (done: @escaping @Sendable (Result<[UInt8], VCPLinkError>) -> Void) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, _, error in
                if let data, data.count == count {
                    done(.success([UInt8](data)))
                } else if let error {
                    done(.failure(failure(error)))
                } else {
                    done(.failure(cancelledBecause.withLock { $0 } ?? .closed))  // end of stream mid-frame
                }
            }
        }
    }

    /// Adapts a callback that fires exactly once to `async` with a typed error.
    private func bridge<T: Sendable>(
        _ start: (@escaping @Sendable (Result<T, VCPLinkError>) -> Void) -> Void
    ) async throws(VCPLinkError) -> T {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, VCPLinkError>, Never>) in
            start { continuation.resume(returning: $0) }
        }
        return try result.get()
    }

    private static func numeric(_ family: Int32, _ raw: Data) -> String? {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = raw.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &text, socklen_t(text.count)) != nil }
        return ok ? String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }
}

/// An active session (§10.3): the device's UDP endpoint, where to send, and the TCP connection
/// that keeps the session alive. vcp.md §3: the connection stays open for the session; closing it
/// ends the session on both ends (§8).
nonisolated final class VCPLiveSession: Sendable {
    let hostID: [UInt8]
    let keys: VCPSessionKeys
    let endpoint: VCPEndpoint
    /// The host's TCP peer address and the `udp_port` from the authenticated `SESSION_CHALLENGE`.
    let udpHost: String
    let udpPort: UInt16
    private let channel: VCPControlChannel

    fileprivate init(channel: VCPControlChannel, hostID: [UInt8], keys: VCPSessionKeys, endpoint: VCPEndpoint,
                     udpHost: String, udpPort: UInt16) {
        self.channel = channel
        self.hostID = hostID
        self.keys = keys
        self.endpoint = endpoint
        self.udpHost = udpHost
        self.udpPort = udpPort
    }

    /// Where the tracking pipeline sends this session's datagrams.
    var destination: TrackingDestination {
        TrackingDestination(host: udpHost, port: udpPort, endpoint: endpoint)
    }

    /// Returns once the session is over: the host closed the connection or sent `ERROR`, the
    /// network failed, or `close()` ran (`.closed`). v1 sends nothing after `SESSION_ACCEPT`, so
    /// any other frame ends the session as `.unexpected`.
    func ended() async -> VCPLinkError {
        do {
            let message = try await channel.receive()
            return .unexpected("message \(message.type) after SESSION_ACCEPT")
        } catch {
            return error
        }
    }

    /// Ends the session: closes the TCP connection, which the host treats as the end (§8).
    func close() {
        channel.close()
    }
}

/// The device's side of pairing and session setup, over one `VCPControlChannel`.
nonisolated enum VCPSessionClient {
    /// The host allows 10 s from connecting to the end of the handshake (`vcam-net` control.rs).
    static let handshakeTimeout: Double = 10

    /// Pairs with the 6-digit code shown in Blender (§9.3) and returns what to store. The
    /// connection stays open: the host expects `HELLO(mode 1)` on it next (`startSession`).
    /// `nonce` and `a` are parameters only so tests can replay the golden transcript.
    static func pair(on channel: VCPControlChannel, device: VCPDeviceIdentity, code: String,
                     nonce: [UInt8] = VCPPairing.randomBytes(16),
                     a: [UInt8] = VCPPairing.randomSecret()) async throws(VCPLinkError) -> VCPHostPairing {
        let hello = VCPHello(mode: VCPHello.modePair, deviceID: device.deviceID, nonceD: nonce, deviceName: device.name)
        try await channel.send(.hello(hello))
        guard case let .pairChallenge(challenge) = try await channel.receive() else {
            throw .unexpected("expected PAIR_CHALLENGE")
        }
        let (proof, pending): (VCPPairProof, VCPPendingPair)
        do { (proof, pending) = try VCPPairing.devicePair(code: code, hello: hello, challenge: challenge, a: a) } catch {
            throw .pairing(error)
        }
        try await channel.send(.pairProof(proof))
        guard case let .pairAccept(m2) = try await channel.receive() else {
            throw .unexpected("expected PAIR_ACCEPT")
        }
        do { return VCPHostPairing(hostID: challenge.hostID, pairingKey: try pending.finish(m2: m2)) } catch {
            throw .pairing(error)
        }
    }

    /// Starts a session with a stored pairing (§10): `HELLO(mode 1)`, `SESSION_CHALLENGE`,
    /// `SESSION_PROOF`, `SESSION_ACCEPT`. `pairingKey` looks up `PK` by the challenge's `host_id`;
    /// without one, nothing is proven and `.unknownHost` is thrown. Nothing may go over UDP
    /// before this returns (§10.2).
    static func startSession(on channel: VCPControlChannel, device: VCPDeviceIdentity,
                             pairingKey: (_ hostID: [UInt8]) -> [UInt8]?,
                             nonce: [UInt8] = VCPPairing.randomBytes(16)) async throws(VCPLinkError) -> VCPLiveSession {
        let hello = VCPHello(mode: VCPHello.modeSession, deviceID: device.deviceID, nonceD: nonce,
                             deviceName: device.name)
        try await channel.send(.hello(hello))
        guard case let .sessionChallenge(challenge) = try await channel.receive() else {
            throw .unexpected("expected SESSION_CHALLENGE")
        }
        guard let pk = pairingKey(challenge.hostID) else {
            throw .unknownHost
        }
        guard challenge.udpPort != 0 else {
            throw .unexpected("SESSION_CHALLENGE without a UDP port")
        }
        let handshake: VCPSessionHandshake
        do { handshake = try VCPSessionHandshake(pairingKey: pk, hello: hello, challenge: challenge) } catch {
            throw .pairing(error)
        }
        try await channel.send(.sessionProof(handshake.deviceProof))
        guard case let .sessionAccept(proofH) = try await channel.receive() else {
            throw .unexpected("expected SESSION_ACCEPT")
        }
        let keys: VCPSessionKeys
        do { keys = try handshake.accept(hostProof: proofH) } catch { throw .pairing(error) }
        guard let endpoint = keys.deviceEndpoint else {
            throw .unexpected("session_id 0")
        }
        guard let address = channel.peerAddress else {
            throw .network("no peer address")
        }
        return VCPLiveSession(channel: channel, hostID: challenge.hostID, keys: keys, endpoint: endpoint,
                              udpHost: address, udpPort: challenge.udpPort)
    }

    /// Connects to Blender's control port and starts a session with `pairing`, within `timeout`.
    /// On failure the connection is closed.
    static func connect(host: String, port: UInt16, device: VCPDeviceIdentity, pairing: VCPHostPairing,
                        timeout: Double = handshakeTimeout) async throws(VCPLinkError) -> VCPLiveSession {
        let channel = try VCPControlChannel(host: host, port: port)
        do {
            return try await channel.withDeadline(timeout) { () async throws(VCPLinkError) -> VCPLiveSession in
                try await channel.open()
                return try await startSession(on: channel, device: device) {
                    $0 == pairing.hostID ? pairing.pairingKey : nil
                }
            }
        } catch {
            channel.close()
            throw error
        }
    }
}
