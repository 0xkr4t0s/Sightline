import AVKit
import Foundation

// Hardware buttons (FR-CTL-008), with the owner-approved mapping:
//
// | Button                        | Action                                                   |
// |-------------------------------|----------------------------------------------------------|
// | Camera Control full press     | record; in T2 only "Recording not available (T3)"        |
// | Camera Control light press    | focus at the centre: a tap at (0.5, 0.5), new `tap_seq`  |
// | Volume down                   | rack to mark A, new `rack_seq`                           |
// | Volume up                     | rack to mark B, new `rack_seq`                           |
//
// An action fires when the press ends (`.ended`), like a shutter; `.began` and `.cancelled`
// (the system took the press back, e.g. the app went to the background) do nothing.
//
// What the SDK delivers (AVKit headers, iOS 27 SDK, and WWDC25 session 253):
// - `AVCaptureEventInteraction(primary:secondary:)` has two handlers. Volume down, the Action
//   button, the Camera Control click and AirPods stem clicks all arrive as primary; volume up
//   arrives as secondary. `AVCaptureEvent` carries only a phase, not the button. So a Camera
//   Control full press and volume down can't be told apart: both come through as primary, which
//   `CaptureEventHandler` maps to volume down (rack to A).
// - A Camera Control light press is not an `AVCaptureEvent` at all. The system uses it for the
//   `AVCaptureControl` overlay, which needs an app-owned `AVCaptureSession`
//   (`supportsControls`), and ARKit owns the camera here. The light-press mapping therefore has
//   no hardware source; only an injected `InputEvent` reaches it.
// - The system sends capture events only to apps that actively use the camera. Whether an
//   ARKit-only app gets them at all is not verified and needs the owner's device.

/// A hardware button the app responds to.
nonisolated enum HardwareButton: Equatable, Sendable, CaseIterable {
    case cameraControlFullPress
    case cameraControlLightPress
    case volumeDown
    case volumeUp
}

/// Where a press is in its life (`AVCaptureEventPhase`).
nonisolated enum InputPhase: Equatable, Sendable, CaseIterable {
    case began
    case ended
    case cancelled

    init?(_ phase: AVCaptureEventPhase) {
        switch phase {
        case .began: self = .began
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        @unknown default: return nil
        }
    }
}

/// One step of a hardware button press.
nonisolated struct InputEvent: Equatable, Sendable {
    var button: HardwareButton
    var phase: InputPhase
}

/// The handler of `AVCaptureEventInteraction(primary:secondary:)` an event arrived through.
nonisolated enum CaptureEventHandler: Equatable, Sendable {
    case primary
    case secondary

    /// Primary is volume down (also the Action button and the Camera Control click, which the
    /// SDK doesn't tell apart); secondary is volume up.
    var button: HardwareButton {
        switch self {
        case .primary: .volumeDown
        case .secondary: .volumeUp
        }
    }

    /// The app's event for a capture event on this handler; nil for a phase this SDK didn't know.
    func event(_ phase: AVCaptureEventPhase) -> InputEvent? {
        InputPhase(phase).map { InputEvent(button: button, phase: $0) }
    }
}

/// Something that delivers hardware button events: the capture-event interaction on a device, a
/// fake in tests, or an injected event in the simulator. Disabling it hands the buttons back to
/// the system (volume, launching the camera).
@MainActor
protocol InputEventSource: AnyObject {
    var isEnabled: Bool { get set }
    var onEvent: ((InputEvent) -> Void)? { get set }
}

/// What a hardware button asks for.
nonisolated enum InputAction: Equatable, Sendable {
    /// Start or stop recording; takes arrive in T3.
    case record
    case lens(LensAction)
}

/// What handling an input led to: a lens request for the pipeline to send, or a message to show
/// with nothing sent.
nonisolated enum InputOutcome: Equatable, Sendable {
    case lens(LensAction)
    case message(String)
}

/// The hardware-button mapping, free of UIKit so tests can run it.
nonisolated enum InputMapper {
    static let recordNotAvailable = "Recording not available (T3)"
    static let centre: (u: Float, v: Float) = (0.5, 0.5)

    /// The action for `event`, or nil for a phase that does nothing.
    static func action(for event: InputEvent) -> InputAction? {
        guard event.phase == .ended else { return nil }
        switch event.button {
        case .cameraControlFullPress: return .record
        case .cameraControlLightPress: return .lens(.tap(u: centre.u, v: centre.v))
        case .volumeDown: return .lens(.rackTo(VCPRackFocus.targetA))
        case .volumeUp: return .lens(.rackTo(VCPRackFocus.targetB))
        }
    }

    /// Shown when a volume button asks for a mark the operator hasn't set; nothing is sent.
    static func markNotSet(_ target: UInt8) -> String {
        "Set focus mark \(target == VCPRackFocus.targetA ? "A" : "B") first"
    }

    /// Carries out `action` on the lens request. Recording changes nothing in T2. Nil if the lens
    /// refused a request with nothing to tell the operator.
    static func perform(
        _ action: InputAction, panel: inout LensPanelModel, lens: inout LensControls, applied: VCPAppliedLens?
    ) -> InputOutcome? {
        switch action {
        case .record:
            return .message(recordNotAvailable)
        case .lens(let lensAction):
            if panel.perform(lensAction, &lens, applied: applied) { return .lens(lensAction) }
            if case .rackTo(let target) = lensAction { return .message(markNotSet(target)) }
            return nil
        }
    }

    /// Maps and carries out `event`; nil for a phase that does nothing.
    static func handle(
        _ event: InputEvent, panel: inout LensPanelModel, lens: inout LensControls, applied: VCPAppliedLens?
    ) -> InputOutcome? {
        guard let action = action(for: event) else { return nil }
        return perform(action, panel: &panel, lens: &lens, applied: applied)
    }
}
