import Foundation
import XCTest

@MainActor
final class FakeThermalStateProvider: ThermalStateProvider {
    private(set) var state: ProcessInfo.ThermalState
    var onChange: ((ProcessInfo.ThermalState) -> Void)?

    init(_ state: ProcessInfo.ThermalState) {
        self.state = state
    }

    func change(to state: ProcessInfo.ThermalState) {
        guard state != self.state else { return }
        self.state = state
        onChange?(state)
    }

    func startObserving() {}
}

@MainActor
final class ThermalStateProviderTests: XCTestCase {
    func testChangeBetweenInitAndObservationIsDeliveredAndNotificationsRefreshState() {
        var current: ProcessInfo.ThermalState = .nominal
        let notifications = NotificationCenter()
        let provider = ProcessThermalStateProvider(readState: { current }, notifications: notifications)
        var received: [ProcessInfo.ThermalState] = []
        provider.onChange = { received.append($0) }
        current = .serious
        provider.startObserving()
        XCTAssertEqual(provider.state, .serious)
        XCTAssertEqual(received, [.serious])
        current = .critical
        notifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(received, [.serious, .critical])
        provider.startObserving()
        XCTAssertEqual(received.count, 2, "observation is idempotent")
    }

    func testInjectedStateMapsToVCPAndHUD() {
        let provider = FakeThermalStateProvider(.nominal)
        XCTAssertEqual(ThermalStatus(state: provider.state).code, 0)
        XCTAssertEqual(HUDFields.thermal(ThermalStatus(state: provider.state)), "Thermal: Normal")
        provider.change(to: .serious)
        XCTAssertEqual(ThermalStatus(state: provider.state).code, 2)
        XCTAssertEqual(HUDFields.thermal(ThermalStatus(state: provider.state)), "Stream reduced (thermal)")
        provider.change(to: .critical)
        XCTAssertEqual(ThermalStatus(state: provider.state).code, 3)
        provider.change(to: .fair)
        XCTAssertEqual(ThermalStatus(state: provider.state).code, 1)
        XCTAssertEqual(HUDFields.thermal(ThermalStatus(state: provider.state)), "Thermal: Fair")
    }
}
