//! Pairing (SRP-6a, vcp.md §9) and session setup (§10). Pure: the caller supplies the random
//! secrets (`a`, `b`, salt, nonces) from a CSPRNG, which keeps this crate free of I/O.
//!
//! The SRP core is generic over the group size and hash so the same code path is checked
//! against RFC 5054 Appendix B (SHA-1, 1024-bit) in the tests and used for VCP (SHA-256,
//! 3072-bit). Secret exponents go through `pow_bounded_exp` with fixed bounds (constant time
//! for a given bound); only public values use variable-time operations.

use crypto_bigint::modular::{FixedMontyForm, FixedMontyParams};
use crypto_bigint::{NonZero, Odd, U3072, Uint};
use hkdf::Hkdf;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use sha2::digest::Digest;

use crate::control::{
    ControlError, ControlMessage, Hello, PairChallenge, PairProof, SRP_PUBLIC_LEN, SessionChallenge,
};

type HmacSha256 = Hmac<Sha256>;

/// Private exponents `a`/`b` are 256 bits (vcp.md §9.2).
const SECRET_BITS: u32 = 256;

/// RFC 5054 Appendix A 3072-bit group; `g = 5`.
const N3072_HEX: &str = concat!(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879",
    "8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B",
    "0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836",
    "1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804",
    "F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6",
    "955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64",
    "ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226",
    "1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2",
    "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
);
const IDENTITY: &[u8] = b"vcam";

/// Why pairing failed. Maps to `ERROR` codes: `IllegalValue`/`BadCode` → 6, `BadProof` → 2.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairError {
    /// The code is not exactly 6 ASCII digits.
    BadCode,
    /// `A mod N = 0`, `B mod N = 0`, or `u = 0` (vcp.md §9.2).
    IllegalValue,
    /// `M1` or `M2` did not verify.
    BadProof,
    /// A message could not be encoded (only possible with an over-long name).
    Encode(ControlError),
}

/// SRP-6a over one group, per RFC 5054 (`PAD` = left-pad to the length of N).
pub(crate) struct SrpGroup<const L: usize> {
    n: NonZero<Uint<L>>,
    params: FixedMontyParams<L>,
    g: Uint<L>,
}

impl<const L: usize> SrpGroup<L> {
    pub(crate) fn new(n: Uint<L>, g: u64) -> Option<Self> {
        let odd = Odd::new(n).into_option()?;
        Some(Self {
            n: NonZero::new(n).into_option()?,
            params: FixedMontyParams::new(odd),
            g: Uint::from_u64(g),
        })
    }

    pub(crate) fn pad(v: &Uint<L>) -> Vec<u8> {
        v.to_be_bytes().as_ref().to_vec()
    }

    /// Big-endian bytes (at most the width of N) to an integer, reduced mod N. `None` if longer.
    pub(crate) fn reduce_be(&self, bytes: &[u8]) -> Option<Uint<L>> {
        let width = Uint::<L>::BYTES;
        let pad = width.checked_sub(bytes.len())?;
        let mut buf = vec![0u8; width];
        buf.get_mut(pad..)?.copy_from_slice(bytes);
        Some(Uint::<L>::from_be_slice(&buf).rem_vartime(&self.n))
    }

    fn hash<D: Digest>(parts: &[&[u8]]) -> Vec<u8> {
        let mut d = D::new();
        for p in parts {
            d.update(p);
        }
        d.finalize().to_vec()
    }

    fn hash_int<D: Digest>(&self, parts: &[&[u8]]) -> Option<Uint<L>> {
        self.reduce_be(&Self::hash::<D>(parts))
    }

    fn mont(&self, v: &Uint<L>) -> FixedMontyForm<L> {
        FixedMontyForm::new(v, &self.params)
    }

    fn hash_bits<D: Digest>() -> u32 {
        u32::try_from(<D as Digest>::output_size() * 8).unwrap_or(u32::MAX)
    }

    /// `k = H(N ‖ PAD(g))`.
    pub(crate) fn k<D: Digest>(&self) -> Option<Uint<L>> {
        self.hash_int::<D>(&[&Self::pad(self.n.as_ref()), &Self::pad(&self.g)])
    }

    /// `x = H(s ‖ H(I ‖ ":" ‖ P))`.
    pub(crate) fn x<D: Digest>(
        &self,
        salt: &[u8],
        identity: &[u8],
        password: &[u8],
    ) -> Option<Uint<L>> {
        let inner = Self::hash::<D>(&[identity, b":", password]);
        self.hash_int::<D>(&[salt, &inner])
    }

    /// `v = g^x`.
    pub(crate) fn verifier<D: Digest>(&self, x: &Uint<L>) -> Uint<L> {
        self.mont(&self.g)
            .pow_bounded_exp(x, Self::hash_bits::<D>())
            .retrieve()
    }

    /// `A = g^a`.
    pub(crate) fn a_pub(&self, a: &Uint<L>) -> Uint<L> {
        self.mont(&self.g)
            .pow_bounded_exp(a, SECRET_BITS)
            .retrieve()
    }

    /// `B = k·v + g^b`.
    pub(crate) fn b_pub(&self, k: &Uint<L>, v: &Uint<L>, b: &Uint<L>) -> Uint<L> {
        let gb = self.mont(&self.g).pow_bounded_exp(b, SECRET_BITS);
        self.mont(k).mul(&self.mont(v)).add(&gb).retrieve()
    }

    /// `u = H(PAD(A) ‖ PAD(B))`; `None` if `u = 0`.
    pub(crate) fn u<D: Digest>(&self, a_pad: &[u8], b_pad: &[u8]) -> Option<Uint<L>> {
        self.hash_int::<D>(&[a_pad, b_pad])
            .filter(|u| !u.is_zero_vartime())
    }

    /// Device: `S = (B − k·g^x)^(a + u·x)`.
    pub(crate) fn client_s<D: Digest>(
        &self,
        b_pub: &Uint<L>,
        k: &Uint<L>,
        x: &Uint<L>,
        a: &Uint<L>,
        u: &Uint<L>,
    ) -> Uint<L> {
        let hb = Self::hash_bits::<D>();
        let gx = self.mont(&self.g).pow_bounded_exp(x, hb);
        let base = self.mont(b_pub).sub(&self.mont(k).mul(&gx));
        // u, x < 2^hb and a < 2^256, so a + u·x < 2^(2·hb + 1) ≤ 2^513, which fits in L ≥ 16 limbs.
        let exp = u.wrapping_mul(x).wrapping_add(a);
        base.pow_bounded_exp(&exp, (2 * hb).max(SECRET_BITS) + 1)
            .retrieve()
    }

    /// Host: `S = (A · v^u)^b`.
    pub(crate) fn server_s<D: Digest>(
        &self,
        a_pub: &Uint<L>,
        v: &Uint<L>,
        u: &Uint<L>,
        b: &Uint<L>,
    ) -> Uint<L> {
        let vu = self.mont(v).pow_bounded_exp(u, Self::hash_bits::<D>());
        self.mont(a_pub)
            .mul(&vu)
            .pow_bounded_exp(b, SECRET_BITS)
            .retrieve()
    }
}

fn vcp_group() -> Option<SrpGroup<{ U3072::LIMBS }>> {
    SrpGroup::new(U3072::from_be_hex(N3072_HEX), 5)
}

fn check_code(code: &str) -> Result<&[u8], PairError> {
    let b = code.as_bytes();
    if b.len() == 6 && b.iter().all(u8::is_ascii_digit) {
        Ok(b)
    } else {
        Err(PairError::BadCode)
    }
}

fn hmac256(key: &[u8], parts: &[&[u8]]) -> Option<HmacSha256> {
    let mut mac = HmacSha256::new_from_slice(key).ok()?;
    for p in parts {
        mac.update(p);
    }
    Some(mac)
}

fn tag(key: &[u8], parts: &[&[u8]]) -> Option<[u8; 32]> {
    Some(hmac256(key, parts)?.finalize().into_bytes().into())
}

fn verify(key: &[u8], parts: &[&[u8]], expected: &[u8; 32]) -> bool {
    hmac256(key, parts).is_some_and(|m| m.verify_slice(expected).is_ok())
}

fn hkdf32(ikm: &[u8], salt: &[u8], info: &[u8]) -> Option<[u8; 32]> {
    let mut out = [0u8; 32];
    Hkdf::<Sha256>::new(Some(salt), ikm)
        .expand(info, &mut out)
        .ok()?;
    Some(out)
}

fn payload(msg: ControlMessage) -> Result<Vec<u8>, PairError> {
    msg.payload().map_err(PairError::Encode)
}

/// Pairing keys and proofs derived from the SRP secret `K` (vcp.md §9.3).
struct PairKeys {
    t_pair: [u8; 32],
    k: [u8; 32],
}

impl PairKeys {
    fn new(hello: &[u8], challenge: &[u8], a_pad: &[u8], s: &[u8]) -> Self {
        Self {
            t_pair: Sha256::new()
                .chain_update(hello)
                .chain_update(challenge)
                .chain_update(a_pad)
                .finalize()
                .into(),
            k: Sha256::digest(s).into(),
        }
    }

    fn m1(&self) -> Option<[u8; 32]> {
        tag(&self.k, &[b"VCP1 pair M1", &self.t_pair])
    }

    fn m2(&self, m1: &[u8; 32]) -> Option<[u8; 32]> {
        tag(&self.k, &[b"VCP1 pair M2", &self.t_pair, m1])
    }

    fn pairing_key(&self) -> Option<[u8; 32]> {
        hkdf32(&self.k, &self.t_pair, b"VCP1 pairing key")
    }
}

/// Host side of one pairing attempt: holds `v` and `b` until the device's proof arrives.
pub struct HostPairing {
    group: SrpGroup<{ U3072::LIMBS }>,
    hello: Vec<u8>,
    challenge: PairChallenge,
    v: Uint<{ U3072::LIMBS }>,
    b: Uint<{ U3072::LIMBS }>,
}

impl HostPairing {
    /// `salt` and `b` must be fresh CSPRNG output for this attempt.
    pub fn new(
        code: &str,
        hello: &Hello,
        host_id: [u8; 16],
        salt: [u8; 16],
        b: &[u8; 32],
    ) -> Result<Self, PairError> {
        let group = vcp_group().ok_or(PairError::IllegalValue)?;
        let code = check_code(code)?;
        let k = group.k::<Sha256>().ok_or(PairError::IllegalValue)?;
        let x = group
            .x::<Sha256>(&salt, IDENTITY, code)
            .ok_or(PairError::IllegalValue)?;
        let v = group.verifier::<Sha256>(&x);
        let b = group.reduce_be(b).ok_or(PairError::IllegalValue)?;
        let b_pub = group.b_pub(&k, &v, &b);
        let b_pub: [u8; SRP_PUBLIC_LEN] = SrpGroup::pad(&b_pub)
            .try_into()
            .map_err(|_| PairError::IllegalValue)?;
        Ok(Self {
            hello: payload(ControlMessage::Hello(hello.clone()))?,
            challenge: PairChallenge {
                host_id,
                salt,
                b_pub,
            },
            group,
            v,
            b,
        })
    }

    #[must_use]
    pub fn challenge(&self) -> &PairChallenge {
        &self.challenge
    }

    /// Verifies `M1`. On success returns `M2` (for `PAIR_ACCEPT`) and the pairing key `PK`.
    pub fn verify(&self, proof: &PairProof) -> Result<([u8; 32], [u8; 32]), PairError> {
        let g = &self.group;
        let a_pub = g.reduce_be(&proof.a_pub).ok_or(PairError::IllegalValue)?;
        if a_pub.is_zero_vartime() {
            return Err(PairError::IllegalValue);
        }
        let u = g
            .u::<Sha256>(&proof.a_pub, &self.challenge.b_pub)
            .ok_or(PairError::IllegalValue)?;
        let s = g.server_s::<Sha256>(&a_pub, &self.v, &u, &self.b);
        let challenge = payload(ControlMessage::PairChallenge(self.challenge.clone()))?;
        let keys = PairKeys::new(&self.hello, &challenge, &proof.a_pub, &SrpGroup::pad(&s));
        if !verify(&keys.k, &[b"VCP1 pair M1", &keys.t_pair], &proof.m1) {
            return Err(PairError::BadProof);
        }
        let m2 = keys.m2(&proof.m1).ok_or(PairError::BadProof)?;
        Ok((m2, keys.pairing_key().ok_or(PairError::BadProof)?))
    }
}

/// Device side after sending `PAIR_PROOF`: waits for `PAIR_ACCEPT`.
pub struct PendingPair {
    keys: PairKeys,
    m1: [u8; 32],
}

impl PendingPair {
    /// Verifies `M2` and returns the pairing key `PK`.
    pub fn finish(&self, m2: &[u8; 32]) -> Result<[u8; 32], PairError> {
        if !verify(
            &self.keys.k,
            &[b"VCP1 pair M2", &self.keys.t_pair, &self.m1],
            m2,
        ) {
            return Err(PairError::BadProof);
        }
        self.keys.pairing_key().ok_or(PairError::BadProof)
    }
}

/// Device side: answers a `PAIR_CHALLENGE`. `a` must be fresh CSPRNG output.
pub fn device_pair(
    code: &str,
    hello: &Hello,
    challenge: &PairChallenge,
    a: &[u8; 32],
) -> Result<(PairProof, PendingPair), PairError> {
    let g = vcp_group().ok_or(PairError::IllegalValue)?;
    let code = check_code(code)?;
    let b_pub = g
        .reduce_be(&challenge.b_pub)
        .ok_or(PairError::IllegalValue)?;
    if b_pub.is_zero_vartime() {
        return Err(PairError::IllegalValue);
    }
    let a = g.reduce_be(a).ok_or(PairError::IllegalValue)?;
    let a_pad: [u8; SRP_PUBLIC_LEN] = SrpGroup::pad(&g.a_pub(&a))
        .try_into()
        .map_err(|_| PairError::IllegalValue)?;
    let u = g
        .u::<Sha256>(&a_pad, &challenge.b_pub)
        .ok_or(PairError::IllegalValue)?;
    let k = g.k::<Sha256>().ok_or(PairError::IllegalValue)?;
    let x = g
        .x::<Sha256>(&challenge.salt, IDENTITY, code)
        .ok_or(PairError::IllegalValue)?;
    let s = g.client_s::<Sha256>(&b_pub, &k, &x, &a, &u);
    let hello = payload(ControlMessage::Hello(hello.clone()))?;
    let chal = payload(ControlMessage::PairChallenge(challenge.clone()))?;
    let keys = PairKeys::new(&hello, &chal, &a_pad, &SrpGroup::pad(&s));
    let m1 = keys.m1().ok_or(PairError::BadProof)?;
    Ok((PairProof { a_pub: a_pad, m1 }, PendingPair { keys, m1 }))
}

/// Keys for one session (vcp.md §10.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionKeys {
    pub session_id: u32,
    pub k_d2h: [u8; 32],
    pub k_h2d: [u8; 32],
}

/// Session setup over an existing pairing key (vcp.md §10.2–§10.3).
pub struct SessionHandshake {
    pk: [u8; 32],
    t_sess: [u8; 32],
    session_id: u32,
}

impl SessionHandshake {
    /// Both ends build this from the `HELLO(mode 1)` and `SESSION_CHALLENGE` they exchanged.
    pub fn new(
        pk: &[u8; 32],
        hello: &Hello,
        challenge: &SessionChallenge,
    ) -> Result<Self, PairError> {
        let h = payload(ControlMessage::Hello(hello.clone()))?;
        let c = payload(ControlMessage::SessionChallenge(*challenge))?;
        Ok(Self {
            pk: *pk,
            t_sess: Sha256::new()
                .chain_update(&h)
                .chain_update(&c)
                .finalize()
                .into(),
            session_id: challenge.session_id,
        })
    }

    /// `proof_d` (sent by the device in `SESSION_PROOF`).
    pub fn device_proof(&self) -> Option<[u8; 32]> {
        tag(&self.pk, &[b"VCP1 session D", &self.t_sess])
    }

    /// `proof_h` (sent by the host in `SESSION_ACCEPT`).
    pub fn host_proof(&self, proof_d: &[u8; 32]) -> Option<[u8; 32]> {
        tag(&self.pk, &[b"VCP1 session H", &self.t_sess, proof_d])
    }

    /// Host: constant-time check of the device's proof.
    #[must_use]
    pub fn verify_device_proof(&self, proof_d: &[u8; 32]) -> bool {
        verify(&self.pk, &[b"VCP1 session D", &self.t_sess], proof_d)
    }

    /// Device: constant-time check of the host's proof.
    #[must_use]
    pub fn verify_host_proof(&self, proof_d: &[u8; 32], proof_h: &[u8; 32]) -> bool {
        verify(
            &self.pk,
            &[b"VCP1 session H", &self.t_sess, proof_d],
            proof_h,
        )
    }

    /// `k_d2h ‖ k_h2d = HKDF(PK, salt = T_sess, info = "VCP1 session keys" ‖ session_id LE)`.
    pub fn keys(&self) -> Option<SessionKeys> {
        let mut info = b"VCP1 session keys".to_vec();
        info.extend_from_slice(&self.session_id.to_le_bytes());
        let mut okm = [0u8; 64];
        Hkdf::<Sha256>::new(Some(&self.t_sess), &self.pk)
            .expand(&info, &mut okm)
            .ok()?;
        let (d2h, h2d) = okm.split_at(32);
        Some(SessionKeys {
            session_id: self.session_id,
            k_d2h: d2h.try_into().ok()?,
            k_h2d: h2d.try_into().ok()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crypto_bigint::U1024;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// RFC 5054 Appendix B, through the same generic code path VCP uses (open item O-3).
    #[test]
    fn rfc5054_appendix_b() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../testdata/vcp/srp-rfc5054-appendix-b.json");
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let s = |k: &str| v[k].as_str().unwrap().to_owned();
        let g = SrpGroup::<{ U1024::LIMBS }>::new(U1024::from_be_hex(&s("N")), 2).unwrap();
        let int = |k: &str| g.reduce_be(&hex(&s(k))).unwrap();
        let k = g.k::<sha1::Sha1>().unwrap();
        let x = g
            .x::<sha1::Sha1>(&hex(&s("s")), s("I").as_bytes(), s("P").as_bytes())
            .unwrap();
        let v_ = g.verifier::<sha1::Sha1>(&x);
        let (a, b) = (int("a"), int("b"));
        let a_pub = g.a_pub(&a);
        let b_pub = g.b_pub(&k, &v_, &b);
        let u = g
            .u::<sha1::Sha1>(&SrpGroup::pad(&a_pub), &SrpGroup::pad(&b_pub))
            .unwrap();
        for (name, got) in [
            ("k", k),
            ("x", x),
            ("v", v_),
            ("A", a_pub),
            ("B", b_pub),
            ("u", u),
        ] {
            assert_eq!(got, int(name), "{name}");
        }
        let premaster = int("S");
        assert_eq!(
            g.client_s::<sha1::Sha1>(&b_pub, &k, &x, &a, &u),
            premaster,
            "client S"
        );
        assert_eq!(
            g.server_s::<sha1::Sha1>(&a_pub, &v_, &u, &b),
            premaster,
            "server S"
        );
    }

    #[test]
    fn rejects_bad_codes_and_zero_public_values() {
        let hello = Hello {
            mode: 0,
            proto_min: 1,
            proto_max: 1,
            device_id: [0; 16],
            nonce_d: [0; 16],
            device_name: String::new(),
        };
        for code in ["12345", "1234567", "12a456", "１２３４５６"] {
            assert!(
                matches!(
                    HostPairing::new(code, &hello, [0; 16], [0; 16], &[1; 32]),
                    Err(PairError::BadCode)
                ),
                "{code}"
            );
        }
        let host = HostPairing::new("123456", &hello, [0; 16], [0; 16], &[1; 32]).unwrap();
        // A = 0 and A = N (≡ 0 mod N) are both illegal.
        let n: [u8; 384] = hex(N3072_HEX).try_into().unwrap();
        for a_pub in [[0u8; 384], n] {
            assert_eq!(
                host.verify(&PairProof { a_pub, m1: [0; 32] }),
                Err(PairError::IllegalValue)
            );
        }
        let challenge = PairChallenge {
            host_id: [0; 16],
            salt: [0; 16],
            b_pub: [0; 384],
        };
        assert!(matches!(
            device_pair("123456", &hello, &challenge, &[1; 32]),
            Err(PairError::IllegalValue)
        ));
    }
}
