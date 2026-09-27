import Foundation
import GameController

// Game controllers (FR-CTL-008, joystick groundwork): connections and thumbsticks become a
// locomotion intent. Nothing drives the rig with it and nothing is sent until Phase 3, so the
// state here holds no controls and has no way to reach them.

/// What the thumbsticks ask for, each vector with length ≤ 1: `move` from the left stick (x right,
/// y forward), `turn` from the right stick (x yaw right, y pitch up).
nonisolated struct LocomotionIntent: Equatable, Sendable {
    static let zero = LocomotionIntent(move: .zero, turn: .zero)
    /// Stick deflection that counts as resting; worn sticks rarely centre exactly.
    static let deadZone: Float = 0.15

    var move: SIMD2<Float>
    var turn: SIMD2<Float>

    init(move: SIMD2<Float>, turn: SIMD2<Float>) {
        self.move = move
        self.turn = turn
    }

    init(left: SIMD2<Float>, right: SIMD2<Float>) {
        self.init(move: Self.shape(left), turn: Self.shape(right))
    }

    var isZero: Bool { self == .zero }

    /// A radial dead zone: inside it the stick is zero; outside, the length is rescaled so it
    /// grows from 0 at the dead-zone edge and is clamped to 1, keeping the direction.
    static func shape(_ stick: SIMD2<Float>, deadZone: Float = deadZone) -> SIMD2<Float> {
        guard stick.x.isFinite, stick.y.isFinite else { return .zero }
        let length = (stick * stick).sum().squareRoot()
        guard length > deadZone else { return .zero }
        let scaled = min((length - deadZone) / (1 - deadZone), 1)
        return stick / length * scaled
    }
}

/// A change on the game controllers. `id` stays the same for one controller while connected.
nonisolated enum GameControllerEvent: Equatable, Sendable {
    case connected(id: Int, name: String)
    case disconnected(id: Int)
    /// Raw thumbstick positions, each axis -1...1.
    case sticks(id: Int, left: SIMD2<Float>, right: SIMD2<Float>)

    /// The raw thumbsticks of an extended gamepad.
    static func sticks(id: Int, of pad: GCExtendedGamepad) -> GameControllerEvent {
        .sticks(
            id: id,
            left: SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value),
            right: SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value))
    }
}

/// Something that delivers game controller events: `GCController` notifications on a device, a
/// fake in tests.
@MainActor
protocol GameControllerSource: AnyObject {
    var onEvent: ((GameControllerEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// The connected controllers and the current locomotion intent.
nonisolated struct GameControllerState: Equatable, Sendable {
    /// Connected controllers by id, with their names.
    private(set) var controllers: [Int: String] = [:]
    private(set) var intent = LocomotionIntent.zero
    /// The controller the intent came from.
    private var driver: Int?

    var isConnected: Bool { !controllers.isEmpty }

    /// Applies `event`; returns true if the connected set or the intent changed.
    @discardableResult
    mutating func handle(_ event: GameControllerEvent) -> Bool {
        let before = self
        switch event {
        case let .connected(id, name):
            controllers[id] = name
        case .disconnected(let id):
            controllers[id] = nil
            // A controller that drops out mid-push must not leave the camera moving.
            if driver == id {
                driver = nil
                intent = .zero
            }
        case let .sticks(id, left, right):
            guard controllers[id] != nil else { break }
            let next = LocomotionIntent(left: left, right: right)
            // A resting stick on a second controller doesn't cancel the one being pushed.
            guard driver == id || driver == nil || !next.isZero else { break }
            intent = next
            driver = next.isZero ? nil : id
        }
        return self != before
    }
}

/// Keeps a `GameControllerState` up to date from a source.
@MainActor
final class GameControllerMonitor {
    private(set) var state = GameControllerState()
    /// Called after a change to the connected set or the intent.
    var onChange: ((GameControllerState) -> Void)?
    private let source: any GameControllerSource

    init(source: any GameControllerSource) {
        self.source = source
        source.onEvent = { [weak self] event in self?.receive(event) }
    }

    func start() { source.start() }

    /// Stops listening and forgets the controllers, so a later start doesn't act on stale sticks.
    func stop() {
        source.stop()
        guard state != GameControllerState() else { return }
        state = GameControllerState()
        onChange?(state)
    }

    private func receive(_ event: GameControllerEvent) {
        guard state.handle(event) else { return }
        onChange?(state)
    }
}
