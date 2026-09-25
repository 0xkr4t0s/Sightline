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
    /// thread; the connection is closed when the script returns.
    private final class ScriptedHost: @unchecked Sendable {
        let port: UInt16
        private let listener: Int32
        private let finished = DispatchSemaphore(value: 0)
        private var failure: String?

        init(_ script: @escaping @Sendable (HostSide) throws -> Void) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
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
            port = UInt16(bigEndian: addr.sin_port)
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
}
