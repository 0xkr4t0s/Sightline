import Foundation
import Security
import XCTest

final class PairingStoreTests: XCTestCase {
    func testPairingSurvivesReloadAndDoesNotCrossHostSelection() throws {
        let first = "manual:store-test-\(UUID().uuidString):47000"
        let second = "bonjour:store-test-\(UUID().uuidString)"
        defer {
            for account in [first, second] {
                SecItemDelete([
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: "kr8t0s.Sightline.vcp.pairing",
                    kSecAttrAccount: account,
                ] as CFDictionary)
            }
        }
        let original = VCPHostPairing(hostID: Array(0..<16), pairingKey: Array(16..<48))
        let replacement = VCPHostPairing(hostID: Array(repeating: 7, count: 16),
                                         pairingKey: Array(repeating: 9, count: 32))
        XCTAssertNil(try PairingStore.load(first))
        try PairingStore.save(original, for: first)
        XCTAssertEqual(try PairingStore.load(first), original)
        XCTAssertNil(try PairingStore.load(second), "selecting another host must not reuse its key")
        try PairingStore.save(replacement, for: first)
        XCTAssertEqual(try PairingStore.load(first), replacement, "re-pairing replaces the old key")
        XCTAssertNil(try PairingStore.load(second))
    }
}
