import AVKit
import XCTest

/// Hardware buttons (FR-CTL-008): the owner-approved mapping, the press phases, what reaches the
/// lens request and what only shows a message.
final class HardwareInputTests: XCTestCase {
    private func ended(_ button: HardwareButton) -> InputEvent {
        InputEvent(button: button, phase: .ended)
    }

    /// Marks A (1.5 m) and B (6 m) set and a 3 s rack duration chosen on the panel.
    private func markedLens() -> (LensPanelModel, LensControls) {
        var panel = LensPanelModel()
        var lens = LensControls()
        lens.setMark(VCPRackFocus.targetA, to: 1.5)
        lens.setMark(VCPRackFocus.targetB, to: 6)
        panel.stepRackDuration(longer: true)
        XCTAssertEqual(panel.rackDurationMS, 3000)
        return (panel, lens)
    }

    func testEveryButtonActsOnlyWhenThePressEnds() {
        let expected: [HardwareButton: InputAction] = [
            .cameraControlFullPress: .record,
            .cameraControlLightPress: .lens(.tap(u: 0.5, v: 0.5)),
            .volumeDown: .lens(.rackTo(VCPRackFocus.targetA)),
            .volumeUp: .lens(.rackTo(VCPRackFocus.targetB)),
        ]
        XCTAssertEqual(expected.count, HardwareButton.allCases.count)
        for button in HardwareButton.allCases {
            XCTAssertEqual(InputMapper.action(for: ended(button)), expected[button], "\(button) ended")
            XCTAssertNil(InputMapper.action(for: InputEvent(button: button, phase: .began)), "\(button) began")
            XCTAssertNil(
                InputMapper.action(for: InputEvent(button: button, phase: .cancelled)), "\(button) cancelled")
        }
    }

    /// VAL-INPUT-001
    func testFullPressShowsRecordingNotAvailableAndSendsNothing() {
        var controls = DeviceControls()
        controls.lens.setLens(35)
        controls.lens.setFocus(2)
        var (panel, lens) = markedLens()
        controls.lens = lens
        let before = controls
        let panelBefore = panel

        let outcome = InputMapper.handle(
            ended(.cameraControlFullPress), panel: &panel, lens: &controls.lens, applied: nil)
        XCTAssertEqual(outcome, .message("Recording not available (T3)"))
        XCTAssertEqual(InputMapper.recordNotAvailable, "Recording not available (T3)")
        XCTAssertEqual(controls, before, "recording changes no control")
        XCTAssertEqual(controls.message(seq: 9), before.message(seq: 9), "the next CONTROL_STATE is the same")
        XCTAssertEqual(panel, panelBefore)
        lens = controls.lens
        XCTAssertEqual(lens.tap.seq, 0)
        XCTAssertEqual(lens.rack.seq, 0)

        for phase in [InputPhase.began, .cancelled] {
            let none = InputMapper.handle(
                InputEvent(button: .cameraControlFullPress, phase: phase), panel: &panel, lens: &controls.lens,
                applied: nil)
            XCTAssertNil(none, "\(phase)")
            XCTAssertEqual(controls, before)
        }
    }

    /// VAL-INPUT-002
    func testLightPressFocusesAtTheCentreWithANewTap() {
        var panel = LensPanelModel()
        var lens = LensControls()
        panel.setFocus(4, &lens)
        XCTAssertEqual(lens.focusDistanceM, 4)

        let outcome = InputMapper.handle(ended(.cameraControlLightPress), panel: &panel, lens: &lens, applied: nil)
        XCTAssertEqual(outcome, .lens(.tap(u: 0.5, v: 0.5)))
        XCTAssertEqual(lens.tap, VCPTapFocus(u: 0.5, v: 0.5, seq: 1))
        XCTAssertNil(lens.focusDistanceM, "the host picks the distance, as for a viewfinder tap")
        XCTAssertTrue(lens.focusFromHost)

        XCTAssertEqual(
            InputMapper.handle(ended(.cameraControlLightPress), panel: &panel, lens: &lens, applied: nil), outcome)
        XCTAssertEqual(lens.tap.seq, 2, "each light press is a new request at the same point")

        for phase in [InputPhase.began, .cancelled] {
            let none = InputMapper.handle(
                InputEvent(button: .cameraControlLightPress, phase: phase), panel: &panel, lens: &lens, applied: nil)
            XCTAssertNil(none)
            XCTAssertEqual(lens.tap.seq, 2, "\(phase) doesn't tap")
        }
    }

    /// VAL-INPUT-003: volume down racks to A, volume up to B.
    func testVolumeDownRacksToAAndVolumeUpToB() {
        var (panel, lens) = markedLens()

        let down = InputMapper.handle(ended(.volumeDown), panel: &panel, lens: &lens, applied: nil)
        XCTAssertEqual(down, .lens(.rackTo(VCPRackFocus.targetA)))
        XCTAssertEqual(
            lens.rack, VCPRackFocus(aM: 1.5, bM: 6, target: VCPRackFocus.targetA, durationMS: 3000, seq: 1))
        XCTAssertTrue(lens.focusFromHost)

        let up = InputMapper.handle(ended(.volumeUp), panel: &panel, lens: &lens, applied: nil)
        XCTAssertEqual(up, .lens(.rackTo(VCPRackFocus.targetB)))
        XCTAssertEqual(
            lens.rack, VCPRackFocus(aM: 1.5, bM: 6, target: VCPRackFocus.targetB, durationMS: 3000, seq: 2))

        XCTAssertEqual(InputMapper.handle(ended(.volumeUp), panel: &panel, lens: &lens, applied: nil), up)
        XCTAssertEqual(lens.rack.seq, 3, "the same button again is a new rack")
        XCTAssertEqual(lens.rack.target, VCPRackFocus.targetB)

        for button in [HardwareButton.volumeDown, .volumeUp] {
            for phase in [InputPhase.began, .cancelled] {
                XCTAssertNil(
                    InputMapper.handle(
                        InputEvent(button: button, phase: phase), panel: &panel, lens: &lens, applied: nil))
                XCTAssertEqual(lens.rack.seq, 3, "\(button) \(phase) doesn't rack")
            }
        }
    }

    /// VAL-INPUT-003: a volume button whose mark isn't set shows a message and sends nothing.
    func testVolumeWithoutItsMarkShowsAMessageAndChangesNothing() {
        var panel = LensPanelModel()
        var lens = LensControls()
        let before = lens
        XCTAssertEqual(
            InputMapper.handle(ended(.volumeDown), panel: &panel, lens: &lens, applied: nil),
            .message("Set focus mark A first"))
        XCTAssertEqual(
            InputMapper.handle(ended(.volumeUp), panel: &panel, lens: &lens, applied: nil),
            .message("Set focus mark B first"))
        XCTAssertEqual(lens, before)

        lens.setMark(VCPRackFocus.targetA, to: 2)
        XCTAssertEqual(
            InputMapper.handle(ended(.volumeUp), panel: &panel, lens: &lens, applied: nil),
            .message("Set focus mark B first"), "only A is set")
        XCTAssertEqual(lens.rack.seq, 0)
        XCTAssertEqual(
            InputMapper.handle(ended(.volumeDown), panel: &panel, lens: &lens, applied: nil),
            .lens(.rackTo(VCPRackFocus.targetA)))
        XCTAssertEqual(lens.rack.seq, 1)
    }

    /// The rack goes to the pressed mark even when the panel's "Rack A↔B" would pick the other.
    func testRackToIgnoresWhichMarkIsFarther() {
        var (panel, lens) = markedLens()
        let applied = VCPAppliedLens(
            lensMM: 50, focusDistanceM: 6, fstop: 2.8, dofOn: true, sensorFit: VCPAppliedLens.fitAuto,
            sensorWidthMM: 36, renderAspect: 16.0 / 9)
        XCTAssertTrue(panel.perform(.rackTo(VCPRackFocus.targetB), &lens, applied: applied))
        XCTAssertEqual(lens.rack.target, VCPRackFocus.targetB, "B although the focus is already at B")
    }

    /// Volume down (and every other primary button) is the primary handler, volume up the
    /// secondary one.
    func testCaptureEventHandlersMapToTheVolumeButtons() throws {
        XCTAssertEqual(CaptureEventHandler.primary.button, .volumeDown)
        XCTAssertEqual(CaptureEventHandler.secondary.button, .volumeUp)
        XCTAssertEqual(CaptureEventHandler.primary.event(.ended), InputEvent(button: .volumeDown, phase: .ended))
        XCTAssertEqual(CaptureEventHandler.secondary.event(.began), InputEvent(button: .volumeUp, phase: .began))
        XCTAssertEqual(
            CaptureEventHandler.secondary.event(.cancelled), InputEvent(button: .volumeUp, phase: .cancelled))
        XCTAssertEqual(InputPhase(AVCaptureEventPhase.began), .began)
        XCTAssertEqual(InputPhase(AVCaptureEventPhase.ended), .ended)
        XCTAssertEqual(InputPhase(AVCaptureEventPhase.cancelled), .cancelled)
        let unknown = try XCTUnwrap(AVCaptureEventPhase(rawValue: 99))
        XCTAssertNil(InputPhase(unknown), "an unknown phase does nothing")
        XCTAssertNil(CaptureEventHandler.primary.event(unknown))
    }

    /// The source seam: whatever delivers events, a press does its action once, when it ends.
    @MainActor
    func testEventsFromASourceReachTheLensOnlyWhenAPressEnds() {
        let source = FakeInputEventSource()
        var (panel, lens) = markedLens()
        var outcomes: [InputOutcome] = []
        source.onEvent = { event in
            if let outcome = InputMapper.handle(event, panel: &panel, lens: &lens, applied: nil) {
                outcomes.append(outcome)
            }
        }
        source.press(.volumeUp)
        source.press(.cameraControlFullPress)
        source.press(.volumeDown, cancelled: true)
        source.press(.cameraControlLightPress)
        XCTAssertEqual(
            outcomes,
            [
                .lens(.rackTo(VCPRackFocus.targetB)), .message(InputMapper.recordNotAvailable),
                .lens(.tap(u: 0.5, v: 0.5)),
            ])
        XCTAssertEqual(lens.rack.seq, 1, "the cancelled volume down didn't rack")
        XCTAssertEqual(lens.tap.seq, 1)
    }
}

@MainActor
private final class FakeInputEventSource: InputEventSource {
    var isEnabled = true
    var onEvent: ((InputEvent) -> Void)?

    func press(_ button: HardwareButton, cancelled: Bool = false) {
        onEvent?(InputEvent(button: button, phase: .began))
        onEvent?(InputEvent(button: button, phase: cancelled ? .cancelled : .ended))
    }
}
