import Foundation

struct TrackingSettings {
    static let defaultPort = 7000

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
