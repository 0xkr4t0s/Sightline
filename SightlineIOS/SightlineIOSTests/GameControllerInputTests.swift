import GameController
import XCTest

/// Game controllers (FR-CTL-008): connections, the thumbstick dead zone and clamp, and that the
/// locomotion intent stays away from the controls in T2.
final class GameControllerInputTests: XCTestCase {
    private func length(_ v: SIMD2<Float>) -> Float {
        (v * v).sum().squareRoot()
    }

    func testSticksInsideTheDeadZoneAreZero() {
        XCTAssertEqual(LocomotionIntent.deadZone, 0.15)
        for stick: SIMD2<Float> in [[0, 0], [0.1, 0.1], [0.15, 0], [0, -0.15], [-0.1, 0.05]] {
            XCTAssertEqual(LocomotionIntent.shape(stick), .zero, "\(stick)")
        }
        XCTAssertEqual(LocomotionIntent.shape([.nan, 0.5]), .zero, "a non-number is resting")
        XCTAssertEqual(LocomotionIntent.shape([0.5, .infinity]), .zero)
        XCTAssertTrue(LocomotionIntent(left: [0.1, -0.1], right: [0.05, 0.12]).isZero)
    }

    func testSticksOutsideTheDeadZoneAreRescaledAndClamped() {
        let full = LocomotionIntent.shape([1, 0])
        XCTAssertEqual(full.x, 1, accuracy: 1e-6)
        XCTAssertEqual(full.y, 0)
        let half = LocomotionIntent.shape([0, -0.575])
        XCTAssertEqual(half.y, -0.5, accuracy: 1e-6, "the length grows from 0 at the dead-zone edge")
        let justOut = LocomotionIntent.shape([0.16, 0])
        XCTAssertGreaterThan(justOut.x, 0)
        XCTAssertLessThan(justOut.x, 0.02, "no jump at the edge")

        let corner = LocomotionIntent.shape([1, 1])
        XCTAssertEqual(length(corner), 1, accuracy: 1e-6, "a diagonal is clamped to length 1")
        XCTAssertEqual(corner.x, corner.y, accuracy: 1e-6, "the direction is kept")
        let over = LocomotionIntent.shape([-3, 4])
        XCTAssertEqual(over.x, -0.6, accuracy: 1e-6)
        XCTAssertEqual(over.y, 0.8, accuracy: 1e-6)

        for x in stride(from: Float(-1.5), through: 1.5, by: 0.25) {
            for y in stride(from: Float(-1.5), through: 1.5, by: 0.25) {
                XCTAssertLessThanOrEqual(length(LocomotionIntent.shape([x, y])), 1 + 1e-6, "(\(x), \(y))")
            }
        }

        let intent = LocomotionIntent(left: [0, 1], right: [-1, 0])
        XCTAssertEqual(intent.move.y, 1, accuracy: 1e-6, "left stick moves")
        XCTAssertEqual(intent.turn.x, -1, accuracy: 1e-6, "right stick turns")
    }

    /// VAL-INPUT-004
    @MainActor
    func testConnectAndDisconnectUpdateTheConnectedState() {
        let source = FakeGameControllerSource()
        let monitor = GameControllerMonitor(source: source)
        var changes: [GameControllerState] = []
        monitor.onChange = { changes.append($0) }
        monitor.start()
        XCTAssertTrue(source.started)
        XCTAssertFalse(monitor.state.isConnected)

        source.send(.connected(id: 1, name: "Pad"))
        XCTAssertTrue(monitor.state.isConnected)
        XCTAssertEqual(monitor.state.controllers, [1: "Pad"])
        source.send(.sticks(id: 1, left: [0, 1], right: [0.05, 0]))
        XCTAssertEqual(monitor.state.intent.move, [0, 1])
        XCTAssertEqual(monitor.state.intent.turn, .zero)

        source.send(.disconnected(id: 1))
        XCTAssertFalse(monitor.state.isConnected)
        XCTAssertTrue(monitor.state.intent.isZero, "a controller that drops out stops the motion")
        XCTAssertEqual(changes.count, 3)

        source.send(.sticks(id: 1, left: [1, 0], right: [0, 0]))
        source.send(.disconnected(id: 7))
        XCTAssertTrue(monitor.state.intent.isZero, "sticks of a controller that isn't connected are ignored")
        XCTAssertEqual(changes.count, 3, "nothing changed, nothing reported")
    }

    @MainActor
    func testStopForgetsControllersAndTheIntent() {
        let source = FakeGameControllerSource()
        let monitor = GameControllerMonitor(source: source)
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        monitor.start()
        source.send(.connected(id: 1, name: "Pad"))
        source.send(.sticks(id: 1, left: [0.5, 0.5], right: [0, 0]))
        monitor.stop()
        XCTAssertFalse(source.started)
        XCTAssertEqual(monitor.state, GameControllerState())
        XCTAssertEqual(changes, 3)
        monitor.stop()
        XCTAssertEqual(changes, 3, "stopping again reports nothing")
    }

    func testTheControllerBeingPushedKeepsTheIntent() {
        var state = GameControllerState()
        state.handle(.connected(id: 1, name: "One"))
        state.handle(.connected(id: 2, name: "Two"))
        XCTAssertTrue(state.handle(.sticks(id: 1, left: [0, 1], right: [0, 0])))
        XCTAssertFalse(state.handle(.sticks(id: 2, left: [0.01, 0], right: [0, 0])), "a resting second pad")
        XCTAssertEqual(state.intent.move, [0, 1])
        XCTAssertTrue(state.handle(.sticks(id: 2, left: [-1, 0], right: [0, 0])), "a pushed second pad takes over")
        XCTAssertEqual(state.intent.move.x, -1, accuracy: 1e-6)
        XCTAssertTrue(state.handle(.disconnected(id: 1)))
        XCTAssertEqual(state.intent.move.x, -1, accuracy: 1e-6, "pad 1 wasn't driving")
        XCTAssertTrue(state.handle(.sticks(id: 2, left: [0, 0], right: [0, 0])))
        XCTAssertTrue(state.intent.isZero, "letting go stops")
    }

    /// VAL-INPUT-004: in T2 the intent has no path to the rig or the protocol.
    @MainActor
    func testTheIntentNeverReachesTheControls() {
        var controls = DeviceControls()
        controls.motionScale = 10
        controls.lens.setLens(35)
        let before = controls.message(seq: 4)

        let source = FakeGameControllerSource()
        let monitor = GameControllerMonitor(source: source)
        monitor.start()
        source.send(.connected(id: 1, name: "Pad"))
        source.send(.sticks(id: 1, left: [1, 1], right: [-1, 0.5]))
        XCTAssertFalse(monitor.state.intent.isZero)
        XCTAssertEqual(controls.message(seq: 4), before, "the next CONTROL_STATE is unchanged")

        let controlTypes: [Any.Type] = [DeviceControls.self, LensControls.self, TrackingPipeline.self]
        for mirror in [Mirror(reflecting: monitor.state), Mirror(reflecting: monitor)] {
            for child in mirror.children {
                let type = type(of: child.value)
                XCTAssertFalse(
                    controlTypes.contains { $0 == type }, "\(child.label ?? "?") would let the intent reach controls")
            }
        }
    }

    func testAnExtendedGamepadsThumbsticksBecomeASticksEvent() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        pad.leftThumbstick.setValueForXAxis(0.5, yAxis: -0.25)
        pad.rightThumbstick.setValueForXAxis(-1, yAxis: 0.75)
        XCTAssertEqual(
            GameControllerEvent.sticks(id: 3, of: pad), .sticks(id: 3, left: [0.5, -0.25], right: [-1, 0.75]))
    }
}

@MainActor
private final class FakeGameControllerSource: GameControllerSource {
    var onEvent: ((GameControllerEvent) -> Void)?
    private(set) var started = false

    func start() { started = true }
    func stop() { started = false }

    func send(_ event: GameControllerEvent) {
        onEvent?(event)
    }
}
