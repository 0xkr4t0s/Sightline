import Foundation
import Network

nonisolated enum UDPSenderError: LocalizedError {
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

/// One UDP connection, reused while the destination stays the same. Not thread-safe: its owner
/// (`TrackingPipeline`) calls it only on `queue`, which is also where completions run.
///
/// The connection also reads what the host sends back to the same port (vcp.md §3: the host
/// replies to the source of the device's datagrams) and hands each datagram to `onReceive`.
nonisolated final class UDPSender {
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var destinationKey: String?
    /// Called on `queue` for every datagram received on the current connection.
    var onReceive: (@Sendable (Data) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Sends one datagram; `completion` gets nil on success, else the error text, on `queue`.
    func send(_ data: Data, host: String, port: UInt16, completion: @escaping @Sendable (String?) -> Void) {
        do {
            try configure(host: host, port: port)
            connection?.send(content: data, completion: .contentProcessed { error in
                completion(error?.localizedDescription)
            })
        } catch {
            let message = error.localizedDescription
            queue.async { completion(message) }
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
        if let onReceive {
            Self.receive(on: connection, deliver: onReceive)
        }
        self.connection = connection
        destinationKey = key
    }

    /// Reads datagrams until the connection fails or is cancelled (`close`).
    private static func receive(on connection: NWConnection, deliver: @escaping @Sendable (Data) -> Void) {
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty {
                deliver(data)
            }
            guard error == nil else {
                return
            }
            switch connection.state {
            case .cancelled, .failed:
                return
            default:
                receive(on: connection, deliver: deliver)
            }
        }
    }
}
