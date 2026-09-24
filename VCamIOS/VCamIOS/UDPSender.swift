import Foundation
import Network

enum UDPSenderError: LocalizedError {
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Enter a destination host."
        case .invalidPort:
            return "Enter a valid UDP port between 1 and 65535."
        }
    }
}

final class UDPSender {
    private let queue = DispatchQueue(label: "VCamIOS.UDPSender")
    private var connection: NWConnection?
    private var destinationKey: String?

    func send(
        _ data: Data,
        host: String,
        port: UInt16,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            try configure(host: host, port: port)
            connection?.send(content: data, completion: .contentProcessed { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            })
        } catch {
            completion(.failure(error))
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
        destinationKey = nil
    }

    private func configure(host: String, port: UInt16) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw UDPSenderError.invalidHost
        }
        guard port > 0 else {
            throw UDPSenderError.invalidPort
        }

        let key = "\(trimmedHost):\(port)"
        guard key != destinationKey else {
            return
        }

        close()

        let nwHost = NWEndpoint.Host(trimmedHost)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw UDPSenderError.invalidPort
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: .udp)
        connection.start(queue: queue)
        self.connection = connection
        destinationKey = key
    }
}
