import Darwin
import Foundation
import simd
import XCTest

/// The device's TCP control client (task 1.4.2b; vcp.md §3, §9–§11): pairing and session setup
/// against a scripted host on 127.0.0.1 that replays the golden transcripts, the failure paths,
/// and, opt-in, a live session with the Rust host that carries poses and controls.
final class VCPSessionClientTests: XCTestCase {
    private struct ScriptFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// One accepted TCP connection, blocking reads with a 5 s timeout.
    private final class HostSide {
        let fd: Int32

        init(fd: Int32) {
            self.fd = fd
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        func read(_ count: Int) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
                guard n > 0 else { throw ScriptFailure(description: "read \(got) of \(count) bytes") }
                got += n
            }
            return out
        }

        /// One whole control frame (header + payload).
        func frame() throws -> [UInt8] {
            let header = try read(VCPEndpoint.headerLength)
            let length = Int(header[10]) | Int(header[11]) << 8
            return header + (length > 0 ? try read(length) : [])
        }

        func expect(_ expected: [UInt8], _ name: String) throws {
            let got = try frame()
            guard got == expected else { throw ScriptFailure(description: "\(name) differs from the vector") }
        }

        func write(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }
        }

        /// True if the device closes the connection without sending another byte.
        func closedByPeer() -> Bool {
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, 0) == 0
        }
    }

    /// Plays Blender for one connection on 127.0.0.1: accepts it and runs `script` on a background
    /// thread; the connection is closed when the script returns. `port` 0 picks a free one.
    private final class ScriptedHost: @unchecked Sendable {
        let port: UInt16
        private let listener: Int32
        private let finished = DispatchSemaphore(value: 0)
        private var failure: String?

        init(port: UInt16 = 0, _ script: @escaping @Sendable (HostSide) throws -> Void) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = port.bigEndian
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
                }
            }
            guard fd >= 0, bound, listen(fd, 1) == 0 else {
                close(fd)
                throw POSIXError(.EADDRNOTAVAIL)
            }
            listener = fd
            self.port = UInt16(bigEndian: addr.sin_port)
            DispatchQueue.global().async { [self] in
                let conn = accept(listener, nil, nil)
                if conn < 0 {
                    failure = "accept failed"
                } else {
                    do { try script(HostSide(fd: conn)) } catch { failure = "\(error)" }
                    close(conn)
                }
                finished.signal()
            }
        }

        deinit { close(listener) }

        /// Waits for the script; its failure, if any.
        func result() -> String? {
            guard finished.wait(timeout: .now() + 10) == .success else { return "script still running" }
            return failure
        }
    }

    private func load(_ path: String) throws -> [String: Any] {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "testdata", withExtension: nil))
        let data = try Data(contentsOf: root.appending(path: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ s: Any?) -> [UInt8] {
        let s = s as! String
        return stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
        }
    }

    /// `session.json`: its frames, `PK`, and the HELLO's device identity and nonce.
    private func sessionVector() throws -> (m: [String: [UInt8]], s: [String: Any], hello: VCPHello, challenge: VCPSessionChallenge) {
        let s = try load("vcp/session.json")
        let m = (s["messages"] as! [String: Any]).mapValues { hex($0) }
        guard case let .hello(hello) = try VCPControlMessage.decode(m["HELLO"]!),
              case let .sessionChallenge(challenge) = try VCPControlMessage.decode(m["SESSION_CHALLENGE"]!)
        else { throw ScriptFailure(description: "session.json frame types") }
        return (m, s, hello, challenge)
    }

    private func open(_ host: ScriptedHost) async throws -> VCPControlChannel {
        let channel = try VCPControlChannel(host: "127.0.0.1", port: host.port)
        try await channel.open()
        return channel
    }

    /// A 127.0.0.1 TCP port with nothing listening on it (bound once to find it, then closed).
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard fd >= 0, bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// `session.json` over TCP: the client sends the vector's HELLO and SESSION_PROOF byte for
    /// byte, derives its keys, and addresses UDP to the TCP peer with the challenge's port. The
    /// host closing the connection ends the session.
    func testSessionSetupReplaysTheGoldenTranscript() async throws {
        let (m, s, hello, challenge) = try sessionVector()
        let host = try ScriptedHost { conn in
            try conn.expect(m["HELLO"]!, "HELLO")
            conn.write(m["SESSION_CHALLENGE"]!)
            try conn.expect(m["SESSION_PROOF"]!, "SESSION_PROOF")
            conn.write(m["SESSION_ACCEPT"]!)
        }
        let channel = try await open(host)
        let pk = hex(s["PK"])
        let live = try await VCPSessionClient.startSession(
            on: channel, device: VCPDeviceIdentity(deviceID: hello.deviceID, name: hello.deviceName),
            pairingKey: { $0 == challenge.hostID ? pk : nil }, nonce: hello.nonceD)
        XCTAssertNil(host.result())
        XCTAssertEqual(live.keys, VCPSessionKeys(sessionID: challenge.sessionID, kD2H: hex(s["k_d2h"]), kH2D: hex(s["k_h2d"])))
        XCTAssertEqual(live.hostID, challenge.hostID)
        XCTAssertEqual(live.destination.host, "127.0.0.1")
        XCTAssertEqual(live.destination.port, 47000)
        XCTAssertEqual(live.destination.endpoint?.sessionID, challenge.sessionID)
        let end = await live.ended()
        XCTAssertEqual(end, .closed)
    }

    /// Closing the session on the device closes the TCP connection, which ends it for the host.
    func testClosingTheSessionClosesTheConnection() async throws {
        let (m, s, hello, _) = try sessionVector()
        let host = try ScriptedHost { conn in
            _ = try conn.frame()
            conn.write(m["SESSION_CHALLENGE"]!)
            _ = try conn.frame()
            conn.write(m["SESSION_ACCEPT"]!)
            guard conn.closedByPeer() else { throw ScriptFailure(description: "no EOF after close()") }
        }
        let live = try await VCPSessionClient.startSession(
            on: open(host), device: VCPDeviceIdentity(deviceID: hello.deviceID, name: hello.deviceName),
            pairingKey: { _ in hex(s["PK"]) }, nonce: hello.nonceD)
        live.close()
        let end = await live.ended()
        XCTAssertEqual(end, .closed)
        XCTAssertNil(host.result())
    }

    /// §10.2: a `proof_h` that doesn't verify fails setup, and the device sends nothing more.
    func testWrongHostProofFailsAndNothingMoreIsSent() async throws {
        let (m, s, hello, _) = try sessionVector()
        var accept = m["SESSION_ACCEPT"]!
        accept[accept.count - 1] ^= 0x01
        let host = try ScriptedHost { [accept] conn in
            _ = try conn.frame()
            conn.write(m["SESSION_CHALLENGE"]!)
            _ = try conn.frame()
            conn.write(accept)
            guard conn.closedByPeer() else { throw ScriptFailure(description: "device sent more after a bad proof_h") }
        }
        let channel = try await open(host)
        do throws(VCPLinkError) {
            _ = try await VCPSessionClient.startSession(
                on: channel, device: VCPDeviceIdentity(deviceID: hello.deviceID, name: hello.deviceName),
                pairingKey: { _ in hex(s["PK"]) }, nonce: hello.nonceD)
            XCTFail("accepted a wrong proof_h")
        } catch {
            XCTAssertEqual(error, .pairing(.badProof))
        }
        channel.close()
        XCTAssertNil(host.result())
    }

    /// A challenge from a host this device holds no key for is not answered with a proof.
    func testUnknownHostGetsNoProof() async throws {
        let (m, _, hello, _) = try sessionVector()
        let host = try ScriptedHost { conn in
            _ = try conn.frame()
            conn.write(m["SESSION_CHALLENGE"]!)
            guard conn.closedByPeer() else { throw ScriptFailure(description: "device answered an unknown host") }
        }
        let channel = try await open(host)
        do throws(VCPLinkError) {
            _ = try await VCPSessionClient.startSession(
                on: channel, device: VCPDeviceIdentity(deviceID: hello.deviceID, name: hello.deviceName),
                pairingKey: { _ in nil })
            XCTFail("proceeded without a pairing key")
        } catch {
            XCTAssertEqual(error, .unknownHost)
        }
        channel.close()
        XCTAssertNil(host.result())
    }

    /// §10.1: a host without our pairing answers `ERROR` 3, which reaches the caller as such.
    func testHostErrorIsReported() async throws {
        let refusal = try VCPControlMessage.error(VCPControlErrorMessage(code: VCPControlErrorMessage.notPaired,
                                                                         message: "device not paired")).encode()
        let host = try ScriptedHost { conn in
            _ = try conn.frame()
            conn.write(refusal)
        }
        let pairing = VCPHostPairing(hostID: [UInt8](repeating: 1, count: 16), pairingKey: [UInt8](repeating: 2, count: 32))
        do throws(VCPLinkError) {
            _ = try await VCPSessionClient.connect(host: "127.0.0.1", port: host.port,
                                                   device: VCPDeviceIdentity(deviceID: [UInt8](repeating: 3, count: 16), name: "t"),
                                                   pairing: pairing)
            XCTFail("session started against ERROR 3")
        } catch {
            XCTAssertEqual(error, .host(code: VCPControlErrorMessage.notPaired, message: "device not paired"))
        }
        XCTAssertNil(host.result())
    }

    /// A host that never answers doesn't hang the start: the deadline cancels the connection.
    func testSilentHostTimesOut() async throws {
        let host = try ScriptedHost { conn in
            _ = try conn.frame()
            _ = conn.closedByPeer()  // hold the connection open until the device gives up
        }
        let pairing = VCPHostPairing(hostID: [UInt8](repeating: 1, count: 16), pairingKey: [UInt8](repeating: 2, count: 32))
        let started = Date()
        do throws(VCPLinkError) {
            _ = try await VCPSessionClient.connect(host: "127.0.0.1", port: host.port,
                                                   device: VCPDeviceIdentity(deviceID: [UInt8](repeating: 3, count: 16), name: "t"),
                                                   pairing: pairing, timeout: 0.5)
            XCTFail("a silent host produced a session")
        } catch {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertNil(host.result())
    }

    /// A blocked Network callback queue must not delay a handshake timeout or the next retry.
    func testDeadlineDoesNotWaitForStalledConnectionCallbacks() async throws {
        let callbackQueue = DispatchQueue(label: "Sightline.Tests.stalledConnection")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        callbackQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 6)
        }
        defer { release.signal() }
        guard await Task.detached(operation: { Self.block(on: entered, seconds: 2) }).value == .success else {
            XCTFail("callback queue did not start")
            return
        }

        let channel = try VCPControlChannel(host: "127.0.0.1", port: freePort(), callbackQueue: callbackQueue)
        let started = ContinuousClock.now
        do throws(VCPLinkError) {
            try await channel.withDeadline(0.1) { () async throws(VCPLinkError) -> Void in
                try await channel.open()
            }
            XCTFail("connection opened while its callbacks were blocked")
        } catch {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    /// Nothing listening: the start fails at once instead of waiting for the network to change.
    func testRefusedConnectionFailsFast() async throws {
        let host = try ScriptedHost { _ in }
        let port = host.port
        let pairing = VCPHostPairing(hostID: [UInt8](repeating: 1, count: 16), pairingKey: [UInt8](repeating: 2, count: 32))
        // Connect once so the script ends and the listener can be closed.
        let probe = try VCPControlChannel(host: "127.0.0.1", port: port)
        try await probe.open()
        probe.close()
        XCTAssertNil(host.result())
        _ = consume host  // closes the listening socket
        let started = Date()
        do throws(VCPLinkError) {
            _ = try await VCPSessionClient.connect(host: "127.0.0.1", port: port,
                                                   device: VCPDeviceIdentity(deviceID: [UInt8](repeating: 3, count: 16), name: "t"),
                                                   pairing: pairing)
            XCTFail("connected to a closed port")
        } catch {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// `pairing.json` over TCP: HELLO(mode 0) and PAIR_PROOF byte for byte, and the stored
    /// pairing is the challenge's `host_id` with the vector's `PK`.
    func testPairingReplaysTheGoldenTranscript() async throws {
        let p = try load("vcp/pairing.json")
        let m = (p["messages"] as! [String: Any]).mapValues { hex($0) }
        guard case let .hello(hello) = try VCPControlMessage.decode(m["HELLO"]!),
              case let .pairChallenge(challenge) = try VCPControlMessage.decode(m["PAIR_CHALLENGE"]!)
        else { return XCTFail("pairing.json frame types") }
        let host = try ScriptedHost { conn in
            try conn.expect(m["HELLO"]!, "HELLO")
            conn.write(m["PAIR_CHALLENGE"]!)
            try conn.expect(m["PAIR_PROOF"]!, "PAIR_PROOF")
            conn.write(m["PAIR_ACCEPT"]!)
        }
        let pairing = try await VCPSessionClient.pair(
            on: open(host), device: VCPDeviceIdentity(deviceID: hello.deviceID, name: hello.deviceName),
            code: (p["params"] as! [String: Any])["code"] as! String, nonce: hello.nonceD,
            a: hex((p["inputs"] as! [String: Any])["a"]))
        XCTAssertNil(host.result())
        XCTAssertEqual(pairing, VCPHostPairing(hostID: challenge.hostID, pairingKey: hex(p["PK"])))
    }

    // MARK: - Reconnect (task 1.4.2c2, NET-004, vcp.md §8)

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [ContinuousClock.Instant] = []
        private var ends: [ContinuousClock.Instant] = []
        func record() -> Int { lock.withLock { starts.append(.now); return starts.count } }
        func finished() { lock.withLock { ends.append(.now) } }
        var all: [ContinuousClock.Instant] { lock.withLock { starts } }
        var finishes: [ContinuousClock.Instant] { lock.withLock { ends } }
    }

    /// Blender is down (nothing listens), then comes back on the same port: the device retries at
    /// least every 500 ms and has a new session with the stored pairing well within NET-004's 3 s
    /// of the host returning. The host sees a fresh HELLO(mode 1), not a pairing. Attempts don't
    /// overlap, so the next one starts 500 ms after the previous start or as soon as it ends, if a
    /// slow Network callback made it take longer. How many attempts fit into the outage depends on
    /// how fast Network reports the refusal (1–17 ms locally; on the CI simulator the first attempt
    /// once ran into `attemptTimeout`), so the test requires one retry and checks the spacing.
    func testReconnectRetriesUntilTheHostIsBackWithinThreeSeconds() async throws {
        let (m, s, hello, challenge) = try sessionVector()
        let port = try freePort()
        let device = VCPDeviceIdentity(deviceID: hello.deviceID, name: hello.deviceName)
        let pairing = VCPHostPairing(hostID: challenge.hostID, pairingKey: hex(s["PK"]))
        let attempts = Attempts()
        let reconnect = Task { () async -> Result<VCPLiveSession, VCPLinkError> in
            do throws(VCPLinkError) {
                return .success(try await VCPReconnect.run { () async throws(VCPLinkError) -> VCPLiveSession in
                    _ = attempts.record()
                    defer { attempts.finished() }
                    return try await VCPSessionClient.connect(host: "127.0.0.1", port: port, device: device, pairing: pairing,
                                                              timeout: VCPReconnect.attemptTimeout, nonce: hello.nonceD)
                })
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(1_200))
        let host = try ScriptedHost(port: port) { conn in
            try conn.expect(m["HELLO"]!, "HELLO(mode 1)")
            conn.write(m["SESSION_CHALLENGE"]!)
            try conn.expect(m["SESSION_PROOF"]!, "SESSION_PROOF")
            conn.write(m["SESSION_ACCEPT"]!)
            _ = conn.closedByPeer()
        }
        let back = ContinuousClock.now
        let live = try await reconnect.value.get()
        let took = ContinuousClock.now - back
        XCTAssertEqual(live.keys.sessionID, challenge.sessionID)
        XCTAssertLessThan(took, .seconds(3), "NET-004: reconnect within 3 s of the host returning")
        let starts = attempts.all
        let finishes = attempts.finishes
        XCTAssertGreaterThanOrEqual(starts.count, 2, "retries after an attempt failed while the host was down")
        XCTAssertEqual(finishes.count, starts.count)
        for ((earlier, finished), later) in zip(zip(starts, finishes), starts.dropFirst()) {
            let due = max(earlier + VCPReconnect.retryInterval, finished)
            XCTAssertLessThan(later - due, .milliseconds(150),
                              "attempts must start 500 ms apart, or at once after a longer one (took \(finished - earlier))")
        }
        print("NET004_RECONNECT host_back_to_session_ms=\(took.components.attoseconds / 1_000_000_000_000_000 + took.components.seconds * 1000) attempts=\(starts.count) attempt_times=\(zip(starts, finishes).map { $1 - $0 }) start_gaps=\(zip(starts, starts.dropFirst()).map { $1 - $0 })")
        live.close()
        XCTAssertNil(host.result())
    }

    /// Retrying can't fix a pairing Blender no longer accepts: the loop stops at the first such
    /// error and reports it, so the app asks for a new pairing. Transient failures are retried.
    func testReconnectStopsAtARejectedPairing() async throws {
        let refusal = try VCPControlMessage.error(VCPControlErrorMessage(code: VCPControlErrorMessage.notPaired,
                                                                         message: "device not paired")).encode()
        let host = try ScriptedHost { conn in
            _ = try conn.frame()
            conn.write(refusal)
        }
        let port = host.port
        let pairing = VCPHostPairing(hostID: [UInt8](repeating: 1, count: 16), pairingKey: [UInt8](repeating: 2, count: 32))
        let device = VCPDeviceIdentity(deviceID: [UInt8](repeating: 3, count: 16), name: "t")
        let attempts = Attempts()
        do throws(VCPLinkError) {
            _ = try await VCPReconnect.run { () async throws(VCPLinkError) -> VCPLiveSession in
                // A retry would find no listener; end the loop with a different error instead of hanging.
                guard attempts.record() == 1 else { throw .unknownHost }
                return try await VCPSessionClient.connect(host: "127.0.0.1", port: port, device: device, pairing: pairing)
            }
            XCTFail("a refused pairing produced a session")
        } catch {
            XCTAssertEqual(error, .host(code: VCPControlErrorMessage.notPaired, message: "device not paired"))
        }
        XCTAssertEqual(attempts.all.count, 1)
        XCTAssertNil(host.result())

        XCTAssertTrue(VCPReconnect.isFatal(.host(code: VCPControlErrorMessage.proofFailed, message: "")))
        XCTAssertTrue(VCPReconnect.isFatal(.unknownHost))
        XCTAssertTrue(VCPReconnect.isFatal(.pairing(.badProof)))
        for transient: VCPLinkError in [.network("down"), .timeout, .closed, .unexpected("x"),
                                        .host(code: VCPControlErrorMessage.busy, message: "")] {
            XCTAssertFalse(VCPReconnect.isFatal(transient), "\(transient) must be retried")
        }
    }

    /// An explicit stop cancels a reconnect mid-handshake: the TCP connection closes at once (the
    /// host sees EOF) instead of lingering until the handshake deadline, and no session comes back.
    func testCancellingAReconnectClosesTheHandshakeAtOnce() async throws {
        let helloSeen = DispatchSemaphore(value: 0)
        let host = try ScriptedHost { conn in
            _ = try conn.frame()
            helloSeen.signal()
            guard conn.closedByPeer() else { throw ScriptFailure(description: "no EOF after cancel") }
        }
        let port = host.port
        let pairing = VCPHostPairing(hostID: [UInt8](repeating: 1, count: 16), pairingKey: [UInt8](repeating: 2, count: 32))
        let device = VCPDeviceIdentity(deviceID: [UInt8](repeating: 3, count: 16), name: "t")
        let reconnect = Task { () async -> Result<VCPLiveSession, VCPLinkError> in
            do throws(VCPLinkError) {
                return .success(try await VCPReconnect.run { () async throws(VCPLinkError) -> VCPLiveSession in
                    try await VCPSessionClient.connect(host: "127.0.0.1", port: port, device: device, pairing: pairing,
                                                       timeout: VCPSessionClient.handshakeTimeout)
                })
            } catch {
                return .failure(error)
            }
        }
        let seen = await Task.detached { Self.block(on: helloSeen, seconds: 5) }.value
        XCTAssertEqual(seen, .success, "no HELLO reached the host")
        let cancelled = ContinuousClock.now
        reconnect.cancel()
        switch await reconnect.value {
        case .success:
            XCTFail("a cancelled reconnect returned a session")
        case let .failure(error):
            XCTAssertEqual(error, .closed)
        }
        XCTAssertLessThan(ContinuousClock.now - cancelled, .seconds(1))
        XCTAssertNil(host.result())
    }

    /// A blocking semaphore wait, kept out of async code (where `wait` is unavailable).
    private nonisolated static func block(on semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + seconds)
    }

    // MARK: - Live Rust host (opt-in)

    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TrackingSnapshot?
        func set(_ snapshot: TrackingSnapshot) { lock.withLock { value = snapshot } }
        var snapshot: TrackingSnapshot? { lock.withLock { value } }
    }

    /// Sends `frames` poses (translation x = 1…frames cm along ARKit x) through a real pipeline.
    private func feed(_ pipeline: TrackingPipeline, frames: Int) async throws {
        for i in 1...frames {
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(Float(i) / 100, 0, 0, 1)
            pipeline.queue.async {
                pipeline.receive(transform: transform, timestamp: 100 + Double(i) / 60, trackingState: VCPTrackingState.normal)
            }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Pairs with a live Rust host, starts a session on the same connection (§9.3), streams poses
    /// and a control change through `TrackingPipeline` until Blender's STATUS acknowledges them,
    /// then starts a second session on a new connection with the stored pairing.
    ///
    /// Run a host from Blender's Python 3.13 with `vcam_native`: `Session.start(0, dir, host_id)`,
    /// `enable_pairing()`, and a loop that answers `latest_control()` with `update_status(...)`.
    /// Pass its TCP port and code as `TEST_RUNNER_VCAM_INTEROP_TCP` / `TEST_RUNNER_VCAM_INTEROP_CODE`.
    func testLiveSessionWithTheRustHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["VCAM_INTEROP_TCP"], let port = UInt16(portText), let code = env["VCAM_INTEROP_CODE"] else {
            throw XCTSkip("set TEST_RUNNER_VCAM_INTEROP_TCP and TEST_RUNNER_VCAM_INTEROP_CODE to run against a live Rust host")
        }
        let device = VCPDeviceIdentity(deviceID: VCPPairing.randomBytes(16), name: "Sightline interop")
        let channel = try VCPControlChannel(host: "127.0.0.1", port: port)
        try await channel.open()
        let pairing = try await VCPSessionClient.pair(on: channel, device: device, code: code)
        let first = try await VCPSessionClient.startSession(on: channel, device: device) {
            $0 == pairing.hostID ? pairing.pairingKey : nil
        }

        let latest = Latest()
        let pipeline = TrackingPipeline(publish: latest.set)
        var controls = DeviceControls()
        controls.motionScale = 2
        pipeline.setControls(controls)
        pipeline.start(first.destination)
        try await feed(pipeline, frames: 30)
        controls.setOrigin()
        pipeline.setControls(controls)
        try await feed(pipeline, frames: 30)
        let snapshot = try XCTUnwrap(latest.snapshot)
        XCTAssertEqual(snapshot.controlSeq, 2)
        XCTAssertEqual(snapshot.controlAck, 2, "Blender's STATUS didn't acknowledge the controls")
        XCTAssertNil(snapshot.sendError)
        print("VCAM_INTEROP_SESSION n=1 session=\(first.keys.sessionID) udp=\(first.udpHost):\(first.udpPort) " +
              "sent=\(snapshot.packetsSent) ack=\(snapshot.controlAck)")
        pipeline.stop()
        first.close()

        let second = try await VCPSessionClient.connect(host: "127.0.0.1", port: port, device: device, pairing: pairing)
        XCTAssertNotEqual(second.keys.sessionID, first.keys.sessionID)
        pipeline.start(second.destination)
        try await feed(pipeline, frames: 30)
        let again = try XCTUnwrap(latest.snapshot)
        XCTAssertEqual(again.controlAck, 1, "the second session's first CONTROL_STATE wasn't acknowledged")
        print("VCAM_INTEROP_SESSION n=2 session=\(second.keys.sessionID) sent=\(again.packetsSent) ack=\(again.controlAck)")
        pipeline.stop()
        second.close()
    }

    /// NET-004 against the real host: Blender stops its session server (a file reload) and starts
    /// it again on the same port with the same pairings. The device notices the TCP close, retries
    /// with the stored pairing, and its new session's first CONTROL_STATE is acknowledged.
    ///
    /// Run a host from Blender's Python 3.13 that pairs, stops once a device session is up, waits
    /// about 1 s, restarts with the same port, `config_dir` and `host_id`, and prints the wall time
    /// it is listening again. Pass `TEST_RUNNER_VCAM_RESTART_TCP` / `TEST_RUNNER_VCAM_RESTART_CODE`.
    func testReconnectsAfterTheRustHostRestarts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["VCAM_RESTART_TCP"], let port = UInt16(portText), let code = env["VCAM_RESTART_CODE"] else {
            throw XCTSkip("set TEST_RUNNER_VCAM_RESTART_TCP and TEST_RUNNER_VCAM_RESTART_CODE to run against a restarting Rust host")
        }
        let device = VCPDeviceIdentity(deviceID: VCPPairing.randomBytes(16), name: "Sightline reconnect")
        let channel = try VCPControlChannel(host: "127.0.0.1", port: port)
        try await channel.open()
        let pairing = try await VCPSessionClient.pair(on: channel, device: device, code: code)
        let first = try await VCPSessionClient.startSession(on: channel, device: device) {
            $0 == pairing.hostID ? pairing.pairingKey : nil
        }
        let latest = Latest()
        let pipeline = TrackingPipeline(publish: latest.set)
        pipeline.start(first.destination)
        try await feed(pipeline, frames: 20)
        let end = await first.ended()
        let lost = Date()
        let attempts = Attempts()
        let second = try await VCPReconnect.run { () async throws(VCPLinkError) -> VCPLiveSession in
            _ = attempts.record()
            return try await VCPSessionClient.connect(host: "127.0.0.1", port: port, device: device, pairing: pairing,
                                                      timeout: VCPReconnect.attemptTimeout)
        }
        let accepted = Date()
        XCTAssertNotEqual(second.keys.sessionID, first.keys.sessionID)
        pipeline.start(second.destination)
        try await feed(pipeline, frames: 30)
        let snapshot = try XCTUnwrap(latest.snapshot)
        XCTAssertEqual(snapshot.sessionID, second.keys.sessionID)
        XCTAssertEqual(snapshot.controlAck, 1, "the new session's first CONTROL_STATE wasn't acknowledged")
        print(String(format: "VCAM_RESTART end=%@ lost_at=%.3f accepted_at=%.3f loss_to_session_ms=%.0f attempts=%d session=%u ack=%u",
                     "\(end)", lost.timeIntervalSince1970, accepted.timeIntervalSince1970,
                     accepted.timeIntervalSince(lost) * 1000, attempts.all.count, second.keys.sessionID, snapshot.controlAck))
        pipeline.stop()
        second.close()
    }
}
