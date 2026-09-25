import BigNum
import CryptoKit
import Foundation
import Security
import SRP

// Device side of pairing (SRP-6a, docs/protocol/vcp.md §9) and session setup (§10).
//
// SRP runs on `swift-srp` 2.4.0, but only its RFC 5054 core (`k`, `x`, `u` over `PAD(A) ‖ PAD(B)`
// and `S`); `K`, the proofs and every derived key follow vcp.md, not the library's RFC 2945
// proofs. The random secrets are parameters so the golden vectors can fix them; real callers pass
// `VCPPairing.randomSecret()`.

/// Why pairing or session setup failed. Maps to `ERROR` codes: `badCode`/`illegalValue` → 6,
/// `badProof` → 2.
nonisolated enum VCPPairError: Error, Equatable, Sendable {
    /// The code isn't exactly 6 ASCII digits.
    case badCode
    /// `B mod N = 0` or `u = 0` (§9.2), or a field of the wrong length.
    case illegalValue
    /// `M2` or `proof_h` didn't verify.
    case badProof
    /// A message couldn't be encoded (an over-long name).
    case encode(VCPControlError)
}

/// SRP-6a client over one group and hash (RFC 5054; `PAD` = left-pad to the length of `N`).
/// Generic so RFC 5054 Appendix B (SHA-1, 1024-bit) checks the same code path VCP uses.
nonisolated struct VCPSRPClient<H: HashFunction> {
    let configuration: SRPConfiguration<H>

    /// `PAD(A)`, `A = g^a mod N`.
    func publicKey(a: [UInt8]) -> [UInt8] {
        let A = configuration.g.power(BigNum(bytes: a), modulus: configuration.N)
        return SRPKey(A.bytes, padding: configuration.sizeN).bytes
    }

    /// `PAD(S)`, `S = (B − k·g^x)^(a + u·x) mod N` with `x = H(s ‖ H(I ‖ ":" ‖ P))`.
    func sharedSecret(identity: String, password: String, salt: [UInt8], a: [UInt8],
                      bPad: [UInt8]) throws(VCPPairError) -> [UInt8] {
        guard bPad.count == configuration.sizeN else { throw .illegalValue }
        let keys = SRPKeyPair(public: SRPKey(publicKey(a: a)), private: SRPKey(a))
        do {
            // Throws `nullServerKey` for `B mod N = 0` and for `u = 0`.
            return try SRPClient(configuration: configuration)
                .calculateSharedSecret(username: identity, password: password, salt: salt, clientKeys: keys,
                                       serverPublicKey: SRPKey(bPad))
                .bytes
        } catch {
            throw .illegalValue
        }
    }
}

nonisolated enum VCPPairing {
    /// SRP identity `I` (§9.2).
    static let identity = "vcam"

    /// RFC 5054 3072-bit group, `g = 5`, SHA-256. Built per use: `SRPConfiguration` isn't `Sendable`.
    static var client: VCPSRPClient<SHA256> { VCPSRPClient(configuration: SRPConfiguration(.N3072)) }

    /// 32 bytes from the system CSPRNG, for `a` (≥ 256 bits, §9.2).
    static func randomSecret() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    /// Answers a `PAIR_CHALLENGE` to the `HELLO(mode 0)` this device sent. `a` must be fresh
    /// CSPRNG output, used once.
    static func devicePair(code: String, hello: VCPHello, challenge: VCPPairChallenge,
                           a: [UInt8]) throws(VCPPairError) -> (VCPPairProof, VCPPendingPair) {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { throw .badCode }
        guard a.count == 32 else { throw .illegalValue }
        let client = client
        let aPad = client.publicKey(a: a)
        let s = try client.sharedSecret(identity: identity, password: code, salt: challenge.salt, a: a,
                                        bPad: challenge.bPub)
        let tPair = SHA256.hash(data: try payload(.hello(hello)) + payload(.pairChallenge(challenge)) + aPad)
        let pending = VCPPendingPair(k: SymmetricKey(data: SHA256.hash(data: s)), tPair: Array(tPair))
        return (VCPPairProof(aPub: aPad, m1: pending.m1), pending)
    }

    static func payload(_ message: VCPControlMessage) throws(VCPPairError) -> [UInt8] {
        do { return try message.payload() } catch { throw .encode(error) }
    }

    static func mac(_ key: SymmetricKey, _ parts: [UInt8]...) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Array(parts.joined()), using: key))
    }

    /// Constant-time (CryptoKit compares MACs without early exit).
    static func verify(_ tag: [UInt8], _ key: SymmetricKey, _ parts: [UInt8]...) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Array(parts.joined()), using: key)
    }
}

/// Device side after sending `PAIR_PROOF`: holds `K = H(PAD(S))` and `T_pair` until `PAIR_ACCEPT`.
nonisolated struct VCPPendingPair: Sendable {
    private let k: SymmetricKey
    private let tPair: [UInt8]
    /// `M1 = HMAC(K, "VCP1 pair M1" ‖ T_pair)`, sent in `PAIR_PROOF`.
    let m1: [UInt8]

    fileprivate init(k: SymmetricKey, tPair: [UInt8]) {
        self.k = k
        self.tPair = tPair
        m1 = VCPPairing.mac(k, Array("VCP1 pair M1".utf8), tPair)
    }

    /// Verifies `M2` and returns the 32-byte pairing key `PK` to store with the host's id.
    func finish(m2: [UInt8]) throws(VCPPairError) -> [UInt8] {
        guard VCPPairing.verify(m2, k, Array("VCP1 pair M2".utf8), tPair, m1) else { throw .badProof }
        let pk = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: tPair, info: Array("VCP1 pairing key".utf8),
                                        outputByteCount: 32)
        return pk.withUnsafeBytes { Array($0) }
    }
}

/// Keys for one session (§10.3).
nonisolated struct VCPSessionKeys: Equatable, Sendable {
    var sessionID: UInt32
    var kD2H: [UInt8]
    var kH2D: [UInt8]

    /// The device's UDP endpoint for this session.
    var deviceEndpoint: VCPEndpoint? { VCPEndpoint(role: .device, sessionID: sessionID, kD2H: kD2H, kH2D: kH2D) }
}

/// Device side of session setup over a stored pairing key (§10.2–§10.3), built from the
/// `HELLO(mode 1)` sent and the `SESSION_CHALLENGE` received.
nonisolated struct VCPSessionHandshake: Sendable {
    private let pk: SymmetricKey
    private let tSess: [UInt8]
    private let sessionID: UInt32
    /// `proof_d = HMAC(PK, "VCP1 session D" ‖ T_sess)`, sent in `SESSION_PROOF`.
    let deviceProof: [UInt8]

    init(pairingKey: [UInt8], hello: VCPHello, challenge: VCPSessionChallenge) throws(VCPPairError) {
        guard pairingKey.count == 32 else { throw .illegalValue }
        pk = SymmetricKey(data: pairingKey)
        tSess = Array(SHA256.hash(data: try VCPPairing.payload(.hello(hello))
                + VCPPairing.payload(.sessionChallenge(challenge))))
        sessionID = challenge.sessionID
        deviceProof = VCPPairing.mac(pk, Array("VCP1 session D".utf8), tSess)
    }

    /// Checks `SESSION_ACCEPT`'s `proof_h` in constant time; on success returns the session keys.
    /// No UDP may be sent before this succeeds.
    func accept(hostProof: [UInt8]) throws(VCPPairError) -> VCPSessionKeys {
        guard VCPPairing.verify(hostProof, pk, Array("VCP1 session H".utf8), tSess, deviceProof)
        else { throw .badProof }
        var info = Array("VCP1 session keys".utf8)
        info.appendLE(sessionID)
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: pk, salt: tSess, info: info, outputByteCount: 64)
            .withUnsafeBytes { Array($0) }
        return VCPSessionKeys(sessionID: sessionID, kD2H: Array(okm[..<32]), kH2D: Array(okm[32...]))
    }
}
