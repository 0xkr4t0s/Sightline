import Darwin
import Foundation

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

/// A resolved UDP destination (IPv4 or IPv6).
nonisolated struct UDPAddress: Sendable {
    fileprivate var storage = sockaddr_storage()
    fileprivate var length: socklen_t = 0
    fileprivate var family: Int32 = AF_UNSPEC
}

/// A `getaddrinfo` failure.
nonisolated struct UDPResolveError: Error, Sendable {
    let code: Int32

    var message: String { String(cString: gai_strerror(code)) }
}

/// What `UDPSender.send` did with a datagram.
nonisolated enum UDPSendOutcome: Equatable {
    /// Handed to the kernel.
    case sent
    /// No socket yet (a host name still resolving) or any more (closed): dropped.
    case notConnected
    /// The kernel refused it; the `errno`.
    case failed(Int32)
}

/// One connected UDP socket to the host. It is a BSD socket, not an `NWConnection`: `send` hands
/// a datagram to the kernel in one call and touches no heap, where `NWConnection.send` allocates
/// 5–9 blocks per datagram (NFR-LAT-002, measured in task 1.5.1b). The socket is non-blocking, so
/// a full buffer drops a datagram instead of stalling the ARKit queue.
///
/// Not thread-safe: its owner (`TrackingPipeline`) calls it only on `queue`, which is also where
/// `onReceive` runs. The socket reads what the host sends back to it (vcp.md §3: the host replies
/// to the source of the device's datagrams) and hands each datagram to `onReceive`.
nonisolated final class UDPSender {
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// Called on `queue` for every datagram received on the socket `connect` opens next.
    var onReceive: (@Sendable (Data) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        close()
    }

    /// `host` as an address, IPv4 first: Blender's session listens on `0.0.0.0` (`core/session.py`),
    /// so a name's IPv6 addresses (`localhost` → `::1`, `.local` → `fe80::…`) are only a fallback.
    /// `numericOnly` never blocks: it fails (`EAI_NONAME`) for a name, which then has to be
    /// resolved off the ARKit queue.
    static func resolve(host: String, port: UInt16, numericOnly: Bool) -> Result<UDPAddress, UDPResolveError> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_NUMERICSERV | (numericOnly ? AI_NUMERICHOST : 0)
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, String(port), &hints, &list)
        guard code == 0, let first = list else {
            return .failure(UDPResolveError(code: code == 0 ? EAI_NONAME : code))
        }
        defer { freeaddrinfo(list) }
        var chosen = first
        var next = first.pointee.ai_next
        while chosen.pointee.ai_family != AF_INET, let candidate = next {
            chosen = candidate.pointee.ai_family == AF_INET ? candidate : chosen
            next = candidate.pointee.ai_next
        }
        var address = UDPAddress()
        address.family = chosen.pointee.ai_family
        address.length = chosen.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &address.storage) { storage in
            storage.copyMemory(from: UnsafeRawBufferPointer(start: chosen.pointee.ai_addr, count: Int(chosen.pointee.ai_addrlen)))
        }
        return .success(address)
    }

    /// Replaces any socket with one connected to `address`; the `errno` if that fails.
    func connect(to address: UDPAddress) -> Int32? {
        close()
        let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return errno
        }
        var storage = address.storage
        let connected = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, address.length) }
        }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, connected == 0 else {
            let code = errno
            Darwin.close(fd)
            return code
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let deliver = onReceive
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while case let n = recv(fd, &buffer, buffer.count, 0), n > 0 {
                deliver?(Data(buffer[..<n]))
            }
        }
        // The descriptor stays open until the source is done with it.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.fd = fd
        readSource = source
        return nil
    }

    /// Hands one datagram to the kernel.
    func send(_ datagram: [UInt8]) -> UDPSendOutcome {
        guard fd >= 0 else {
            return .notConnected
        }
        let sent = datagram.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        return sent == datagram.count ? .sent : .failed(sent < 0 ? errno : EMSGSIZE)
    }

    func close() {
        readSource?.cancel()
        readSource = nil
        fd = -1
    }
}
