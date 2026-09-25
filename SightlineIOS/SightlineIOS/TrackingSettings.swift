import Foundation
import UIKit

struct TrackingSettings {
    /// Blender's default control (TCP) port (`BlenderAddOn/core/session.py` `DEFAULT_PORT`).
    static let defaultPort = 47000

    var host: String
    var port: Int

    func save(userDefaults: UserDefaults = .standard) {
        userDefaults.set(host, forKey: Keys.host)
        userDefaults.set(port, forKey: Keys.port)
    }

    static func load(userDefaults: UserDefaults = .standard) -> TrackingSettings {
        let storedPort = userDefaults.integer(forKey: Keys.port)
        return TrackingSettings(
            host: userDefaults.string(forKey: Keys.host) ?? "",
            port: storedPort == 0 ? defaultPort : storedPort
        )
    }

    private enum Keys {
        static let host = "tracking.destination.host"
        static let port = "tracking.destination.port"
    }
}

/// This install's VCP identity (vcp.md §9.3): `device_id` is 16 random bytes made on first use and
/// kept for the life of the install; the name is the device's, cut to `VCPHello.maxName` bytes.
enum DeviceIdentityStore {
    private static let key = "vcp.deviceID"

    static func load(userDefaults: UserDefaults = .standard) -> VCPDeviceIdentity {
        var id = userDefaults.data(forKey: key).map { [UInt8]($0) } ?? []
        if id.count != VCPControlMessage.idLength {
            id = VCPPairing.randomBytes(VCPControlMessage.idLength)
            userDefaults.set(Data(id), forKey: key)
        }
        var name = UIDevice.current.name
        while name.utf8.count > VCPHello.maxName {
            name.removeLast()
        }
        return VCPDeviceIdentity(deviceID: id, name: name)
    }
}
