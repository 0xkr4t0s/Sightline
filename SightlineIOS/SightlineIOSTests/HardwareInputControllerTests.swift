import AVKit
import UIKit
import XCTest

/// Hardware buttons wired into the app (FR-CTL-008): when they act, the capture-event interaction
/// on the viewfinder, and that a disabled source's events go nowhere.
@MainActor
final class HardwareInputControllerTests: XCTestCase {
    private func ended(_ button: HardwareButton) -> InputEvent {
        InputEvent(button: button, phase: .ended)
    }

    /// VAL-INPUT-005: only a tracking run with the viewfinder on screen takes the buttons.
    func testTheGateOpensOnlyWhileTrackingWithoutSettings() {
        XCTAssertTrue(InputGate.isEnabled(tracking: true, settingsOpen: false))
        XCTAssertFalse(InputGate.isEnabled(tracking: true, settingsOpen: true), "Settings covers the viewfinder")
        XCTAssertFalse(InputGate.isEnabled(tracking: false, settingsOpen: false), "not tracking")
        XCTAssertFalse(InputGate.isEnabled(tracking: false, settingsOpen: true))
    }

    /// VAL-INPUT-005: every source follows the gate, including one added later.
    func testEverySourceIsDisabledWhenTheAppCantAct() {
        let controller = HardwareInputController()
        let first = FakeInputSource()
        first.isEnabled = true
        controller.add(first)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(first.isEnabled, "a new source starts disabled until the app can act")

        controller.update(tracking: true, settingsOpen: false)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(first.isEnabled)
        let second = FakeInputSource()
        controller.add(second)
        XCTAssertTrue(second.isEnabled, "a source added while enabled is enabled")

        controller.update(tracking: true, settingsOpen: true)
        XCTAssertFalse(first.isEnabled, "Settings open")
        XCTAssertFalse(second.isEnabled)
        controller.update(tracking: true, settingsOpen: false)
        XCTAssertTrue(first.isEnabled, "Settings closed again")
        controller.update(tracking: false, settingsOpen: false)
        XCTAssertFalse(first.isEnabled, "stopped")
        XCTAssertFalse(second.isEnabled)
    }

    /// VAL-CROSS-014 (unit level): an event that arrives while disabled is dropped, not queued.
    func testEventsWhileDisabledAreDropped() {
        let controller = HardwareInputController()
        let source = FakeInputSource()
        controller.add(source)
        var received: [InputEvent] = []
        controller.onEvent = { received.append($0) }

        source.send(ended(.volumeDown))
        XCTAssertEqual(received, [], "not tracking")
        controller.update(tracking: true, settingsOpen: true)
        source.send(ended(.cameraControlFullPress))
        XCTAssertEqual(received, [], "Settings open")

        controller.update(tracking: true, settingsOpen: false)
        XCTAssertEqual(received, [], "nothing held back comes through later")
        source.send(InputEvent(button: .volumeUp, phase: .began))
        source.send(ended(.volumeUp))
        XCTAssertEqual(received, [InputEvent(button: .volumeUp, phase: .began), ended(.volumeUp)])
    }

    /// VAL-INPUT-005 / VAL-INPUT-006: the real interaction, created and driven on the main actor.
    func testTheCaptureEventInteractionFollowsTheGate() {
        let source = CaptureEventSource()
        XCTAssertFalse(source.interaction.isEnabled, "the system keeps the buttons until the app can act")
        let controller = HardwareInputController()
        controller.add(source)
        XCTAssertFalse(source.interaction.isEnabled)

        controller.update(tracking: true, settingsOpen: false)
        XCTAssertTrue(source.interaction.isEnabled)
        XCTAssertTrue(source.isEnabled)
        controller.update(tracking: true, settingsOpen: true)
        XCTAssertFalse(source.interaction.isEnabled, "Settings open gives the buttons back to the system")
        controller.update(tracking: true, settingsOpen: false)
        XCTAssertTrue(source.interaction.isEnabled)
        controller.update(tracking: false, settingsOpen: false)
        XCTAssertFalse(source.interaction.isEnabled, "not tracking gives the buttons back to the system")
    }

    func testTheInteractionIsInstalledOnceOnTheView() {
        let source = CaptureEventSource()
        let view = UIView()
        source.install(on: view)
        source.install(on: view)
        XCTAssertEqual(view.interactions.filter { $0 === source.interaction }.count, 1)
        XCTAssertTrue(source.interaction.view === view)

        let other = UIView()
        source.install(on: other)
        XCTAssertTrue(source.interaction.view === other, "a new viewfinder view takes the interaction")
        XCTAssertFalse(view.interactions.contains { $0 === source.interaction })
    }

    /// Primary is volume down (rack to A), secondary volume up (rack to B); unknown phases are
    /// dropped.
    func testCaptureEventsBecomeButtonEvents() throws {
        let source = CaptureEventSource()
        var received: [InputEvent] = []
        source.onEvent = { received.append($0) }
        source.receive(.primary, phase: .began)
        source.receive(.primary, phase: .ended)
        source.receive(.secondary, phase: .cancelled)
        source.receive(.secondary, phase: try XCTUnwrap(AVCaptureEventPhase(rawValue: 99)))
        XCTAssertEqual(
            received,
            [
                InputEvent(button: .volumeDown, phase: .began), InputEvent(button: .volumeDown, phase: .ended),
                InputEvent(button: .volumeUp, phase: .cancelled),
            ])
    }

    /// The notice a message outcome shows: a new one each time, even with the same text, so a
    /// second press flashes it again.
    func testEachNoticeIsNew() {
        let first = InputNotice(InputMapper.recordNotAvailable)
        let second = InputNotice(InputMapper.recordNotAvailable)
        XCTAssertEqual(first.text, "Recording not available (T3)")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
    }
}

@MainActor
private final class FakeInputSource: InputEventSource {
    var isEnabled = false
    var onEvent: ((InputEvent) -> Void)?

    func send(_ event: InputEvent) {
        onEvent?(event)
    }
}
