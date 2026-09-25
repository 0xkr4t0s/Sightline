import Foundation
import Network
import XCTest

/// Finding Blender over DNS-SD (task 1.4.3a; FR-UX-001, NET-001, vcp.md §3): hosts are listed by
/// machine and `.blend` file name from the `_vcam-ctl._tcp` TXT record, follow record updates, and
/// disappear when the host withdraws.
final class HostDiscoveryTests: XCTestCase {
    func testTxtRecordFieldsFromVcpSection3() {
        let host = DiscoveredHost(
            serviceName: "vcam-0123-50000",
            txt: ["vcp": "1", "blend": "shot_010.blend", "host": "Studio Mac", "tcp": "50000", "udp": "50001"])
        XCTAssertEqual(host.id, "vcam-0123-50000")
        XCTAssertEqual(host.machine, "Studio Mac")
        XCTAssertEqual(host.blendFile, "shot_010.blend")
        XCTAssertEqual(host.fileLabel, "shot_010.blend")
        XCTAssertEqual(host.tcpPort, 50000)
        XCTAssertEqual(host.protocolVersion, 1)
        XCTAssertTrue(host.isCompatible)
    }

    func testUnsavedFileMissingHostAndBadValues() {
        // vcp.md §3: `blend=` is empty for an unsaved file.
        let unsaved = DiscoveredHost(serviceName: "vcam-a-1", txt: ["vcp": "1", "blend": "", "host": "", "tcp": "0"])
        XCTAssertNil(unsaved.blendFile)
        XCTAssertEqual(unsaved.fileLabel, "Unsaved file")
        XCTAssertEqual(unsaved.machine, "vcam-a-1", "no host name: fall back to the instance name")
        XCTAssertNil(unsaved.tcpPort, "port 0 is not a listening port")

        let garbage = DiscoveredHost(serviceName: "x", txt: ["vcp": "one", "tcp": "70000"])
        XCTAssertNil(garbage.protocolVersion)
        XCTAssertFalse(garbage.isCompatible, "a record without a VCP version is not listed as usable")
        XCTAssertNil(garbage.tcpPort)
    }

    func testVersionCompatibilityBoundary() {
        // `vcp=` is the host's highest version; it is usable if that reaches our lowest (1).
        XCTAssertFalse(DiscoveredHost(serviceName: "a", txt: ["vcp": "0"]).isCompatible)
        XCTAssertTrue(DiscoveredHost(serviceName: "b", txt: ["vcp": "1"]).isCompatible)
        XCTAssertTrue(DiscoveredHost(serviceName: "c", txt: ["vcp": "2"]).isCompatible)
    }

    func testListDeduplicatesInterfacesAndSortsByMachineThenFile() {
        let hosts = DiscoveredHost.list([
            ("s3", ["host": "mac 10", "blend": "a.blend"]),
            ("s1", ["host": "Mac 2", "blend": "z.blend"]),
            ("s2", ["host": "mac 2", "blend": "b.blend"]),
            ("s1", ["host": "Duplicate on another interface", "blend": ""]),
        ])
        XCTAssertEqual(hosts.map(\.id), ["s2", "s1", "s3"])
        XCTAssertEqual(hosts.map(\.fileLabel), ["b.blend", "z.blend", "a.blend"])
    }

    // MARK: - Live browsing

    /// Advertises `_vcam-ctl._tcp` like the host's `ControlServer::advertise`.
    private final class FakeHost {
        let listener: NWListener
        let name = "vcam-test-\(UUID().uuidString)"

        init(txt: [String: String]) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { $0.cancel() }
            advertise(txt)
            listener.start(queue: DispatchQueue(label: "FakeHost"))
        }

        func advertise(_ txt: [String: String]) {
            listener.service = NWListener.Service(
                name: name, type: DiscoveredHost.serviceType, domain: "local.", txtRecord: NWTXTRecord(txt))
        }

        func withdraw() {
            listener.cancel()
        }
    }

    @MainActor
    private func eventually(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @MainActor
    func testBrowserListsUpdatesAndDropsAHost() async throws {
        let fake = try FakeHost(txt: ["vcp": "1", "blend": "", "host": "Loopback Mac", "tcp": "1234"])
        let browser = HostBrowser()
        let browsing = Task { await browser.run() }
        defer { browsing.cancel() }
        func ours() -> DiscoveredHost? { browser.hosts.first { $0.id == fake.name } }

        let found = await eventually(10) { ours() != nil }
        XCTAssertTrue(found, "advertised host not found; problem: \(browser.problem ?? "none")")
        XCTAssertEqual(ours()?.machine, "Loopback Mac")
        XCTAssertEqual(ours()?.fileLabel, "Unsaved file")
        XCTAssertEqual(ours()?.tcpPort, 1234)

        // Saving the .blend re-advertises the TXT record (NET-001 "updates").
        fake.advertise(["vcp": "1", "blend": "shot_020.blend", "host": "Loopback Mac", "tcp": "1234"])
        let updated = await eventually(10) { ours()?.blendFile == "shot_020.blend" }
        XCTAssertTrue(updated, "TXT update not seen: \(String(describing: ours()))")

        // Disabling the host session withdraws the service.
        fake.withdraw()
        let gone = await eventually(10) { ours() == nil }
        XCTAssertTrue(gone, "withdrawn host still listed")

        browsing.cancel()
        await browsing.value
        XCTAssertTrue(browser.hosts.isEmpty, "a stopped browser keeps no stale hosts")
    }

    @MainActor
    func testSelectedBonjourServiceConnectsAndResolvesUDPPeer() async throws {
        let name = "vcam-connect-\(UUID().uuidString)"
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "BonjourSelectionTest"))
        }
        listener.service = NWListener.Service(name: name, type: DiscoveredHost.serviceType, domain: "local.",
                                              txtRecord: NWTXTRecord(["vcp": "1", "host": "Test Blender"]))
        listener.start(queue: DispatchQueue(label: "BonjourSelectionListener"))
        defer { listener.cancel() }

        let browser = HostBrowser()
        let browsing = Task { await browser.run() }
        defer { browsing.cancel() }
        let found = await eventually(10) { browser.hosts.contains { $0.id == name } }
        XCTAssertTrue(found)
        let selected = try XCTUnwrap(browser.hosts.first { $0.id == name })
        XCTAssertTrue(selected.isCompatible)
        let channel = VCPControlChannel(serviceName: selected.id)
        defer { channel.close() }
        try await channel.withDeadline(10) { () async throws(VCPLinkError) -> Void in
            try await channel.open()
        }
        XCTAssertNotNil(channel.peerAddress, "UDP must target the resolved TCP peer, not the service name")
    }

    /// Interop with the real Rust advertiser (`mdns-sd`). Opt-in: run a host session that calls
    /// `Session.advertise(<machine>, <blend>)`, then pass the same values as
    /// `TEST_RUNNER_VCAM_INTEROP_HOST` / `TEST_RUNNER_VCAM_INTEROP_BLEND` to `xcodebuild test`.
    @MainActor
    func testFindsTheRustHostAdvertiser() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let machine = env["VCAM_INTEROP_HOST"] else {
            throw XCTSkip("set TEST_RUNNER_VCAM_INTEROP_HOST to run against a live Blender/Rust host")
        }
        let blend = env["VCAM_INTEROP_BLEND"] ?? ""
        let browser = HostBrowser()
        let browsing = Task { await browser.run() }
        defer { browsing.cancel() }
        let found = await eventually(15) { browser.hosts.contains { $0.machine == machine } }
        XCTAssertTrue(found, "hosts seen: \(browser.hosts)")
        let host = try XCTUnwrap(browser.hosts.first { $0.machine == machine })
        XCTAssertEqual(host.blendFile, blend.isEmpty ? nil : blend)
        XCTAssertTrue(host.isCompatible)
        XCTAssertNotNil(host.tcpPort)
        print("VCAM_INTEROP_FOUND id=\(host.id) machine=\(host.machine) file=\(host.fileLabel) tcp=\(host.tcpPort ?? 0)")
    }
}
