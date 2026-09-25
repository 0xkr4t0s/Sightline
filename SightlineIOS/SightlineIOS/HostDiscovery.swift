import Foundation
import Network
import Observation

/// A Blender host advertised over DNS-SD (FR-UX-001, NET-001; vcp.md §3). The instance name is an
/// opaque host ID, so everything shown to the user comes from the TXT record.
nonisolated struct DiscoveredHost: Identifiable, Equatable, Sendable {
    /// The control-channel service the device browses. The UDP service is not browsed: the device
    /// takes the UDP port from the authenticated `SESSION_CHALLENGE`, not from DNS-SD.
    static let serviceType = "_vcam-ctl._tcp"
    /// The lowest VCP version this app speaks (`HELLO.proto_min`, vcp.md §9).
    static let minimumProtocolVersion = 1

    /// The DNS-SD service instance name; unique per host and control port.
    let id: String
    /// `host=`, or the instance name when the host sent none.
    let machine: String
    /// `blend=`; nil for an unsaved file.
    let blendFile: String?
    /// `tcp=`; nil when missing or not a valid port.
    let tcpPort: UInt16?
    /// `vcp=`: the host's highest supported VCP version; nil when missing or not a number.
    let protocolVersion: Int?

    init(serviceName: String, txt: [String: String]) {
        id = serviceName
        machine = txt["host"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
        blendFile = txt["blend"].flatMap { $0.isEmpty ? nil : $0 }
        tcpPort = txt["tcp"].flatMap(UInt16.init).flatMap { $0 == 0 ? nil : $0 }
        protocolVersion = txt["vcp"].flatMap { Int($0) }
    }

    /// False for hosts whose highest version is below ours, or that don't advertise one.
    var isCompatible: Bool {
        (protocolVersion ?? 0) >= Self.minimumProtocolVersion
    }

    var fileLabel: String {
        blendFile ?? "Unsaved file"
    }

    /// One entry per service instance, sorted by machine and then file. The browser can report the
    /// same instance once per interface; the first is kept.
    static func list(_ services: [(name: String, txt: [String: String])]) -> [DiscoveredHost] {
        var seen = Set<String>()
        return services
            .filter { seen.insert($0.name).inserted }
            .map { DiscoveredHost(serviceName: $0.name, txt: $0.txt) }
            .sorted { a, b in
                let byMachine = a.machine.localizedStandardCompare(b.machine)
                if byMachine != .orderedSame {
                    return byMachine == .orderedAscending
                }
                let byFile = a.fileLabel.localizedStandardCompare(b.fileLabel)
                if byFile != .orderedSame {
                    return byFile == .orderedAscending
                }
                return a.id < b.id
            }
    }
}

/// Browses for Blender hosts while `run()` is awaited (for example from a SwiftUI `.task`), and
/// stops when that task is cancelled.
@MainActor
@Observable
final class HostBrowser {
    private(set) var hosts: [DiscoveredHost] = []
    /// A user-facing problem with browsing (for example, local-network permission denied), or nil.
    private(set) var problem: String?

    func run() async {
        let browser = NetworkBrowser(for: .bonjour(DiscoveredHost.serviceType, includeTxtRecord: true))
            .onStateUpdate { [weak self] _, state in
                self?.update(state)
            }
        do {
            try await browser.run { [weak self] endpoints in
                self?.hosts = DiscoveredHost.list(endpoints.map { ($0.name, $0.txtRecord.dictionary) })
            }
        } catch is CancellationError {
        } catch {
            problem = "Can't search for Blender: \(error.localizedDescription)"
        }
        hosts = []
    }

    private func update(_ state: NetworkBrowser<Bonjour>.State) {
        switch state {
        case .ready:
            problem = nil
        case .waiting(let error), .failed(let error):
            problem = "Can't search for Blender: \(error.localizedDescription)"
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }
}
