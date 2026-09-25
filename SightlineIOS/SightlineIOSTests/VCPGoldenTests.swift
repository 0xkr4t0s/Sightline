import BigNum
import CryptoKit
import simd
import SRP
import XCTest

/// Consumes the golden vectors in testdata/ (NFR-QA-003, DM-004, PR-004), bundled as a folder
/// reference named `testdata`.
final class VCPGoldenTests: XCTestCase {
    private func load(_ path: String) throws -> [String: Any] {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "testdata", withExtension: nil),
                                 "testdata folder reference missing from the test bundle")
        let data = try Data(contentsOf: root.appending(path: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func endpoints(_ receiver: [String: Any]) -> (host: VCPEndpoint, device: VCPEndpoint) {
        let sid = UInt32(receiver["session_id"] as! Int)
        let d2h = hex(receiver["k_d2h"] as! String), h2d = hex(receiver["k_h2d"] as! String)
        return (VCPEndpoint(role: .host, sessionID: sid, kD2H: d2h, kH2D: h2d)!,
                VCPEndpoint(role: .device, sessionID: sid, kD2H: d2h, kH2D: h2d)!)
    }

    /// (receiver, sender) for a vector's direction.
    private func pair(_ direction: String, _ e: (host: VCPEndpoint, device: VCPEndpoint)) -> (VCPEndpoint, VCPEndpoint) {
        direction == "d2h" ? (e.host, e.device) : (e.device, e.host)
    }

    private func floats(_ v: Any?) -> [Float] { (v as! [NSNumber]).map(\.floatValue) }
    private func uint(_ v: Any?) -> UInt64 { (v as! NSNumber).uint64Value }

    private func check(_ message: VCPMessage, _ f: [String: Any], _ name: String) {
        switch message {
        case let .pose(p):
            XCTAssertEqual(UInt64(p.seq), uint(f["seq"]), name)
            XCTAssertEqual(p.captureTimeNs, uint(f["capture_time_ns"]), name)
            XCTAssertEqual([p.position.x, p.position.y, p.position.z], floats(f["position_m"]), name)
            XCTAssertEqual([p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w], floats(f["orientation"]), name)
            XCTAssertEqual(UInt64(p.trackingState), uint(f["tracking_state"]), name)
        case let .controlState(c):
            let bits = uint(f["fields"])
            XCTAssertEqual(UInt64(c.stateSeq), uint(f["state_seq"]), name)
            XCTAssertEqual(c.motionScale, bits & 1 != 0 ? (f["motion_scale"] as! NSNumber).floatValue : nil, name)
            XCTAssertEqual(c.lockFlags.map(UInt64.init), bits & 2 != 0 ? uint(f["lock_flags"]) : nil, name)
            XCTAssertEqual(c.originEpoch.map(UInt64.init), bits & 4 != 0 ? uint(f["origin_epoch"]) : nil, name)
        case let .clock(c):
            let (t1, t2, t3) = (uint(f["t1"]), uint(f["t2"]), uint(f["t3"]))
            XCTAssertEqual(c, uint(f["mode"]) == 0 ? .request(t1: t1) : .reply(t1: t1, t2: t2, t3: t3), name)
        case let .status(s):
            XCTAssertEqual(UInt64(s.statusSeq), uint(f["status_seq"]), name)
            XCTAssertEqual(UInt64(s.appliedPoseSeq), uint(f["applied_pose_seq"]), name)
            XCTAssertEqual(UInt64(s.controlAck), uint(f["control_ack"]), name)
            XCTAssertEqual(UInt64(s.errorCode), uint(f["error_code"]), name)
            XCTAssertEqual(UInt64(s.flags), uint(f["flags"]), name)
            XCTAssertEqual(s.cameraName, f["camera_name"] as? String, name)
        }
    }

    func testUDPMessagesDecodeAndReencodeByteExact() throws {
        let e = endpoints(try load("vcp/receive.json")["receiver"] as! [String: Any])
        var checked = 0
        for case let c as [String: Any] in try load("vcp/messages.json")["cases"] as! [Any] where c["channel"] as? String == "udp" {
            let name = c["name"] as! String
            let bytes = hex(c["hex"] as! String)
            let (rx, tx) = pair(c["direction"] as! String, e)
            let message = try rx.open(bytes).get()
            check(message, c["fields"] as! [String: Any], name)
            XCTAssertEqual(try tx.seal(message), bytes, "\(name): re-encoding differs")
            checked += 1
        }
        XCTAssertEqual(checked, 8)
    }

    func testReceiveRulesMatchVectors() throws {
        let vectors = try load("vcp/receive.json")
        let e = endpoints(vectors["receiver"] as! [String: Any])
        let cases = vectors["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 26)
        for c in cases {
            let name = c["name"] as! String
            let (rx, _) = pair(c["direction"] as! String, e)
            let result = rx.open(hex(c["hex"] as! String))
            let accepted = if case .success = result { true } else { false }
            XCTAssertEqual(accepted, c["accept"] as! Bool, "\(name): \(result), rule \(c["rule"] ?? "")")
        }
        func reason(_ name: String) -> VCPDropReason? {
            let c = cases.first { $0["name"] as? String == name }!
            if case let .failure(r) = pair(c["direction"] as! String, e).0.open(hex(c["hex"] as! String)) { return r }
            return nil
        }
        XCTAssertEqual(reason("bad_magic"), .magic)
        XCTAssertEqual(reason("unknown_version"), .version)
        XCTAssertEqual(reason("wrong_session_id"), .session)
        XCTAssertEqual(reason("wrong_direction_key"), .tag)
        XCTAssertEqual(reason("clock_request_from_device"), .unknownType)
        XCTAssertEqual(reason("pose_quat_norm_1_2"), .payload(.quaternionNorm))
    }

    func testFreshnessSequences() throws {
        for case let s as [String: Any] in try load("vcp/freshness.json")["sequences"] as! [Any] {
            guard let applied = s["applied"] as? [Int] else { continue }
            var filter = VCPSeqFilter()
            let got = (s["input"] as! [Int]).filter { filter.accept(UInt32($0)) }
            XCTAssertEqual(got, applied, s["message"] as? String ?? "")
        }
    }

    func testARKitToCanonicalMatchesDM004Vectors() throws {
        let vectors = try load("coords/arkit_to_canonical.json")
        let tolerance = Float(truncating: vectors["tolerance"] as! NSNumber) * 10 // Float vs. the JSON's doubles
        let cases = vectors["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 9)
        for c in cases {
            let name = c["name"] as! String
            let arkit = c["arkit"] as! [String: Any], want = c["canonical"] as! [String: Any]
            let rows = (arkit["transform_row_major"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
            let transform = simd_float4x4(columns: (
                SIMD4(rows[0][0], rows[1][0], rows[2][0], rows[3][0]),
                SIMD4(rows[0][1], rows[1][1], rows[2][1], rows[3][1]),
                SIMD4(rows[0][2], rows[1][2], rows[2][2], rows[3][2]),
                SIMD4(rows[0][3], rows[1][3], rows[2][3], rows[3][3])
            ))
            let (position, q) = VCPCoordinates.canonicalPose(fromARKit: transform)
            let wantPosition = floats(want["position"]), wantQ = floats(want["orientation"])
            for i in 0..<3 { XCTAssertEqual(position[i], wantPosition[i], accuracy: tolerance, "\(name) position") }
            for i in 0..<4 { XCTAssertEqual(q[i], wantQ[i], accuracy: tolerance, "\(name) orientation") }
            let quat = simd_quatf(vector: q)
            let matrix = (want["matrix_world_row_major"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
            for col in 0..<3 {
                var axis = SIMD3<Float>(0, 0, 0)
                axis[col] = 1
                let got = quat.act(axis)
                for row in 0..<3 { XCTAssertEqual(got[row], matrix[row][col], accuracy: tolerance, "\(name) matrix[\(row)][\(col)]") }
            }
            let view = quat.act(SIMD3(0, 0, -1)), wantView = floats(want["view_direction"])
            for i in 0..<3 { XCTAssertEqual(view[i], wantView[i], accuracy: tolerance, "\(name) view") }
        }
    }

    func testSealEnforcesDirectionAndLimits() throws {
        let e = endpoints(try load("vcp/receive.json")["receiver"] as! [String: Any])
        let status = VCPMessage.status(VCPStatus(statusSeq: 1, appliedPoseSeq: 0, controlAck: 0, errorCode: 0, flags: 0,
                                                 cameraName: String(repeating: "x", count: 64)))
        XCTAssertThrowsError(try e.device.seal(status)) { XCTAssertEqual($0 as? VCPSealError, .wrongDirection) }
        XCTAssertThrowsError(try e.host.seal(status)) { XCTAssertEqual($0 as? VCPSealError, .payload(.badName)) }
        let control = VCPMessage.controlState(VCPControlState(stateSeq: 1, motionScale: nil, lockFlags: 1, originEpoch: nil))
        XCTAssertEqual(try e.host.open(e.device.seal(control)).get(), control)
        XCTAssertNil(VCPEndpoint(role: .host, sessionID: 0, kD2H: Array(repeating: 0, count: 32), kH2D: Array(repeating: 0, count: 32)))
    }

    /// PR-005: every prefix and every single-byte flip of every vector is rejected without crashing.
    func testMalformedInputIsRejected() throws {
        let e = endpoints(try load("vcp/receive.json")["receiver"] as! [String: Any])
        for case let c as [String: Any] in try load("vcp/messages.json")["cases"] as! [Any] where c["channel"] as? String == "udp" {
            let bytes = hex(c["hex"] as! String)
            let (rx, _) = pair(c["direction"] as! String, e)
            for n in 0..<bytes.count {
                if case .success = rx.open(Array(bytes[..<n])) { XCTFail("prefix \(n) accepted") }
            }
            for i in bytes.indices {
                var m = bytes
                m[i] ^= 0xFF
                if case .success = rx.open(m) { XCTFail("\(c["name"]!): flip at \(i) accepted") }
            }
        }
    }

    // MARK: TCP control channel, pairing and session setup (§9–§11, O-3)

    private func control(_ s: Any?) throws -> VCPControlMessage { try VCPControlMessage.decode(hex(s as! String)) }

    /// Every TCP frame in the vectors decodes and re-encodes byte-exact.
    func testControlFramesDecodeAndReencodeByteExact() throws {
        var frames: [(String, String)] = []
        for case let c as [String: Any] in try load("vcp/messages.json")["cases"] as! [Any] where c["channel"] as? String == "tcp" {
            frames.append((c["name"] as! String, c["hex"] as! String))
            switch try control(c["hex"]) {
            case let .hello(h):
                let f = c["fields"] as! [String: Any]
                XCTAssertEqual(h, VCPHello(mode: UInt8(uint(f["mode"])), protoMin: UInt8(uint(f["proto_min"])),
                                           protoMax: UInt8(uint(f["proto_max"])), deviceID: hex(f["device_id"] as! String),
                                           nonceD: hex(f["nonce_d"] as! String), deviceName: f["device_name"] as! String))
            case let .error(e):
                let f = c["fields"] as! [String: Any]
                XCTAssertEqual(e, VCPControlErrorMessage(code: UInt16(uint(f["code"])), message: f["message"] as! String))
            case let other:
                XCTFail("unexpected \(other)")
            }
        }
        XCTAssertEqual(frames.count, 2)
        for file in ["vcp/pairing.json", "vcp/session.json"] {
            for case let (name, value as String) in try load(file)["messages"] as! [String: Any] where name != "first_POSE_udp" {
                frames.append(("\(file) \(name)", value))
            }
        }
        XCTAssertEqual(frames.count, 10)
        for (name, value) in frames {
            let bytes = hex(value)
            let message = try VCPControlMessage.decode(bytes)
            XCTAssertEqual(try message.encode(), bytes, "\(name): re-encoding differs")
            XCTAssertEqual(try VCPControlMessage.frameLength(header: bytes.prefix(12)), bytes.count, name)
        }
    }

    func testMalformedControlFramesAreRejected() throws {
        let hello = hex((try load("vcp/pairing.json")["messages"] as! [String: Any])["HELLO"] as! String)
        func decode(_ edit: (inout [UInt8]) -> Void) -> VCPControlError? {
            var b = hello
            edit(&b)
            do { _ = try VCPControlMessage.decode(b); return nil } catch { return error }
        }
        XCTAssertEqual(decode { $0.removeLast($0.count - 11) }, .frame)
        XCTAssertEqual(decode { $0.removeLast() }, .frame)
        XCTAssertEqual(decode { $0.append(0) }, .frame)
        XCTAssertEqual(decode { $0[0] = UInt8(ascii: "X") }, .frame)
        XCTAssertEqual(decode { $0[4] = 2 }, .version)
        XCTAssertEqual(decode { $0[6] = 1 }, .frame, "session_id must be 0 on TCP")
        XCTAssertEqual(decode { $0[5] = 0x4E }, .unknownType)
        XCTAssertEqual(decode { $0[10] = 0x01; $0[11] = 0x10 }, .frame, "len 4097")
        XCTAssertEqual(decode { $0[12 + 36] = 200 }, .payload, "name length past the end")
        XCTAssertEqual(decode { $0[12 + 36] = 65; $0 += Array(repeating: 0x61, count: 59); $0[10] = UInt8($0.count - 12) },
                       .payload, "name over 64 bytes")
        XCTAssertEqual(decode { $0[$0.count - 1] = 0xFF }, .payload, "name not UTF-8")
        // A longer payload than v1 knows is accepted, the extra ignored (§2).
        var longer = hello
        longer.append(0xEE)
        longer[10] += 1
        XCTAssertEqual(try VCPControlMessage.decode(longer), try VCPControlMessage.decode(hello))
        for n in 0..<hello.count { XCTAssertThrowsError(try VCPControlMessage.decode(Array(hello[..<n]))) }
        for i in hello.indices {
            var b = hello
            b[i] ^= 0xFF
            _ = try? VCPControlMessage.decode(b)
        }
        guard case var .hello(h) = try VCPControlMessage.decode(hello) else { return XCTFail("not a HELLO") }
        h.deviceName = String(repeating: "x", count: 65)
        XCTAssertThrowsError(try VCPControlMessage.hello(h).encode()) { XCTAssertEqual($0 as? VCPControlError, .field) }
        XCTAssertThrowsError(try VCPControlMessage.sessionProof([0]).encode()) { XCTAssertEqual($0 as? VCPControlError, .field) }
    }

    /// RFC 5054 Appendix B (SHA-1, 1024-bit) through the same client code VCP uses.
    func testSRPClientMatchesRFC5054AppendixB() throws {
        let v = try load("vcp/srp-rfc5054-appendix-b.json")
        let x = { (k: String) in self.hex(v[k] as! String) }
        let client = VCPSRPClient<Insecure.SHA1>(configuration: SRPConfiguration(.N1024))
        XCTAssertEqual(client.configuration.N.bytes, x("N"))
        XCTAssertEqual(client.configuration.k.bytes, x("k"))
        XCTAssertEqual(client.publicKey(a: x("a")), x("A"))
        XCTAssertEqual(try client.sharedSecret(identity: v["I"] as! String, password: v["P"] as! String, salt: x("s"),
                                               a: x("a"), bPad: x("B")), x("S"))
    }

    func testPairingTranscriptMatchesVector() throws {
        let p = try load("vcp/pairing.json")
        let (inputs, messages, srp) = (p["inputs"] as! [String: Any], p["messages"] as! [String: Any], p["srp"] as! [String: Any])
        let code = (p["params"] as! [String: Any])["code"] as! String
        guard case let .hello(hello) = try control(messages["HELLO"]),
              case let .pairChallenge(challenge) = try control(messages["PAIR_CHALLENGE"]),
              case let .pairAccept(m2) = try control(messages["PAIR_ACCEPT"])
        else { return XCTFail("unexpected message types") }
        XCTAssertEqual(VCPPairing.client.configuration.N.bytes, hex((p["params"] as! [String: Any])["N"] as! String))
        let a = hex(inputs["a"] as! String)
        XCTAssertEqual(try VCPPairing.client.sharedSecret(identity: "vcam", password: code, salt: challenge.salt, a: a,
                                                          bPad: challenge.bPub), hex(srp["S"] as! String))

        let (proof, pending) = try VCPPairing.devicePair(code: code, hello: hello, challenge: challenge, a: a)
        XCTAssertEqual(proof.m1, hex(p["M1"] as! String))
        XCTAssertEqual(try VCPControlMessage.pairProof(proof).encode(), hex(messages["PAIR_PROOF"] as! String))
        XCTAssertEqual(try pending.finish(m2: m2), hex(p["PK"] as! String))
        for i in m2.indices {
            var bad = m2
            bad[i] ^= 0x01
            XCTAssertThrowsError(try pending.finish(m2: bad)) { XCTAssertEqual($0 as? VCPPairError, .badProof) }
        }

        let wrong = p["wrong_code"] as! [String: Any]
        let (wrongProof, wrongPending) = try VCPPairing.devicePair(code: wrong["code"] as! String, hello: hello,
                                                                  challenge: challenge, a: a)
        XCTAssertEqual(wrongProof.m1, hex(wrong["M1"] as! String))
        XCTAssertThrowsError(try wrongPending.finish(m2: m2)) { XCTAssertEqual($0 as? VCPPairError, .badProof) }
    }

    /// §9.2: abort on `B mod N = 0`; the code must be 6 ASCII digits.
    func testPairingRejectsIllegalValuesAndCodes() throws {
        let p = try load("vcp/pairing.json")
        let messages = p["messages"] as! [String: Any]
        guard case let .hello(hello) = try control(messages["HELLO"]),
              case let .pairChallenge(challenge) = try control(messages["PAIR_CHALLENGE"])
        else { return XCTFail("unexpected message types") }
        let a = hex((p["inputs"] as! [String: Any])["a"] as! String)
        let n = hex((p["params"] as! [String: Any])["N"] as! String)
        for bPub in [[UInt8](repeating: 0, count: 384), n] {
            var c = challenge
            c.bPub = bPub
            XCTAssertThrowsError(try VCPPairing.devicePair(code: "042917", hello: hello, challenge: c, a: a)) {
                XCTAssertEqual($0 as? VCPPairError, .illegalValue)
            }
        }
        for code in ["04291", "0429170", "04291a", "٠٤٢٩١٧"] {
            XCTAssertThrowsError(try VCPPairing.devicePair(code: code, hello: hello, challenge: challenge, a: a), code) {
                XCTAssertEqual($0 as? VCPPairError, .badCode)
            }
        }
    }

    func testSessionSetupMatchesVectorAndKeysSealFirstPose() throws {
        let s = try load("vcp/session.json")
        let messages = s["messages"] as! [String: Any]
        guard case let .hello(hello) = try control(messages["HELLO"]),
              case let .sessionChallenge(challenge) = try control(messages["SESSION_CHALLENGE"]),
              case let .sessionProof(proofD) = try control(messages["SESSION_PROOF"]),
              case let .sessionAccept(proofH) = try control(messages["SESSION_ACCEPT"])
        else { return XCTFail("unexpected message types") }
        XCTAssertEqual(hello.mode, VCPHello.modeSession)
        let pk = hex(s["PK"] as! String)
        let handshake = try VCPSessionHandshake(pairingKey: pk, hello: hello, challenge: challenge)
        XCTAssertEqual(handshake.deviceProof, proofD)
        let keys = try handshake.accept(hostProof: proofH)
        XCTAssertEqual(keys, VCPSessionKeys(sessionID: challenge.sessionID, kD2H: hex(s["k_d2h"] as! String),
                                            kH2D: hex(s["k_h2d"] as! String)))
        // The derived keys produce the vector's first POSE datagram byte for byte.
        let pose = hex(messages["first_POSE_udp"] as! String)
        let host = try XCTUnwrap(VCPEndpoint(role: .host, sessionID: keys.sessionID, kD2H: keys.kD2H, kH2D: keys.kH2D))
        XCTAssertEqual(try XCTUnwrap(keys.deviceEndpoint).seal(host.open(pose).get()), pose)
        for i in proofH.indices {
            var bad = proofH
            bad[i] ^= 0x80
            XCTAssertThrowsError(try handshake.accept(hostProof: bad)) { XCTAssertEqual($0 as? VCPPairError, .badProof) }
        }
        var otherPK = pk
        otherPK[0] ^= 1
        XCTAssertThrowsError(try VCPSessionHandshake(pairingKey: otherPK, hello: hello, challenge: challenge)
            .accept(hostProof: proofH)) { XCTAssertEqual($0 as? VCPPairError, .badProof) }
    }
}
