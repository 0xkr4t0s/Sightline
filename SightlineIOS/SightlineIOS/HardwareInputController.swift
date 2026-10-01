import AVKit
import Foundation
import UIKit

// Hardware buttons wired into the app (FR-CTL-008); the mapping and what the SDK delivers are in
// HardwareInput.swift. The buttons belong to the app only while it can act on them; the rest of
// the time every source is disabled, which gives volume and the camera launch back to the system.

/// When the hardware buttons act.
nonisolated enum InputGate {
    /// Only during a tracking run with the viewfinder on screen: not while stopped, starting or
    /// with the Settings sheet over it.
    static func isEnabled(tracking: Bool, settingsOpen: Bool) -> Bool {
        tracking && !settingsOpen
    }
}

/// A message a button press shows for a moment, e.g. "Recording not available (T3)". Every notice
/// is new, so pressing again flashes the same text again.
nonisolated struct InputNotice: Equatable, Sendable {
    let text: String
    let id = UUID()

    init(_ text: String) { self.text = text }
}

/// Holds the input sources, keeps them enabled or disabled by `InputGate`, and passes their events
/// on while enabled.
@MainActor
final class HardwareInputController {
    private(set) var isEnabled = false
    /// Called with each event from an enabled source.
    var onEvent: ((InputEvent) -> Void)?
    private var sources: [any InputEventSource] = []

    func add(_ source: any InputEventSource) {
        source.isEnabled = isEnabled
        source.onEvent = { [weak self] event in self?.receive(event) }
        sources.append(source)
    }

    func update(tracking: Bool, settingsOpen: Bool) {
        isEnabled = InputGate.isEnabled(tracking: tracking, settingsOpen: settingsOpen)
        for source in sources where source.isEnabled != isEnabled {
            source.isEnabled = isEnabled
        }
    }

    // A disabled system interaction delivers nothing; an injected QA press still arrives and is
    // dropped here, so it behaves like the real button.
    private func receive(_ event: InputEvent) {
        guard isEnabled else { return }
        onEvent?(event)
    }
}

/// The volume buttons, Action button and Camera Control click through
/// `AVCaptureEventInteraction(primary:secondary:)`, installed on the viewfinder's view. Created,
/// installed and called on the main actor (the interaction is a `UIInteraction`).
@MainActor
final class CaptureEventSource: InputEventSource {
    var onEvent: ((InputEvent) -> Void)?

    private(set) lazy var interaction = AVCaptureEventInteraction(
        primary: { [weak self] event in self?.receive(.primary, phase: event.phase) },
        secondary: { [weak self] event in self?.receive(.secondary, phase: event.phase) })

    var isEnabled: Bool {
        get { interaction.isEnabled }
        set { interaction.isEnabled = newValue }
    }

    init() {
        interaction.isEnabled = false
    }

    /// Puts the interaction on `view`. UIKit keeps an interaction on one view at a time and adds it
    /// only once, so a new viewfinder view simply takes it over.
    func install(on view: UIView) {
        view.addInteraction(interaction)
    }

    func receive(_ handler: CaptureEventHandler, phase: AVCaptureEventPhase) {
        guard let event = handler.event(phase) else { return }
        onEvent?(event)
    }
}
