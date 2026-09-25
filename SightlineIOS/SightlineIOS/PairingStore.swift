import Foundation
import Security

/// VCP pairing keys stay in the device Keychain, not in preferences or the discovery TXT record.
/// The account identifies a destination; SESSION_CHALLENGE must still prove its host_id before use.
nonisolated enum PairingStore {
    private static let service = "kr8t0s.Sightline.vcp.pairing"

    static func load(_ account: String) throws -> VCPHostPairing? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PairingStoreError.keychain(status) }
        guard let data = result as? Data, data.count == 48 else { throw PairingStoreError.invalidRecord }
        return VCPHostPairing(hostID: Array(data.prefix(16)), pairingKey: Array(data.suffix(32)))
    }

    static func save(_ pairing: VCPHostPairing, for account: String) throws {
        guard pairing.hostID.count == 16, pairing.pairingKey.count == 32 else {
            throw PairingStoreError.invalidRecord
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        var data = Data(capacity: 48)
        data.append(contentsOf: pairing.hostID)
        data.append(contentsOf: pairing.pairingKey)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PairingStoreError.keychain(status) }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw PairingStoreError.keychain(added) }
    }
}

nonisolated enum PairingStoreError: LocalizedError {
    case invalidRecord
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "Invalid pairing record in Keychain. Pair with Blender again."
        case .keychain(let status): "Couldn't access the pairing Keychain (OSStatus \(status))."
        }
    }
}
