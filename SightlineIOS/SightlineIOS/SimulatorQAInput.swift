// Simulator QA: hardware-button presses injected by name. The Simulator has no volume buttons or
// Camera Control that reach the app, and a Camera Control light press is never a capture event
// (HardwareInput.swift), so this is how scripts and UI tests press them.
//
// Compiled only into simulator debug builds, like the rest of the QA mode (SimulatorQA.swift).
#if targetEnvironment(simulator) && DEBUG
import Foundation
import notify
import os

extension HardwareButton {
    /// The button's QA name: `fullPress`, `lightPress`, `volumeDown` or `volumeUp`.
    nonisolated var qaName: String {
        switch self {
        case .cameraControlFullPress: "fullPress"
        case .cameraControlLightPress: "lightPress"
        case .volumeDown: "volumeDown"
        case .volumeUp: "volumeUp"
        }
    }
}

/// Presses posted as Darwin notifications named `kr8t0s.Sightline.qa.input.<qaName>` inside the
/// simulator: `tools/mission/qa_ios.sh input volumeDown` (`notifyutil -p`), or `notify_post` from
/// a UI test. Each post is one press, began then ended. The presses go through the same
/// `HardwareInputController` as the real buttons, which drops them while the app can't act.
@MainActor
final class QAInjectedInputSource: InputEventSource {
    static let prefix = "kr8t0s.Sightline.qa.input."

    var isEnabled = false
    var onEvent: ((InputEvent) -> Void)?
    private var tokens: [Int32] = []

    func start() {
        guard tokens.isEmpty else { return }
        for button in HardwareButton.allCases {
            var token: Int32 = 0
            let status = notify_register_dispatch(Self.prefix + button.qaName, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inject(button) }
            }
            if status == NOTIFY_STATUS_OK {
                tokens.append(token)
            } else {
                Log.qa.error("Can't listen for injected \(button.qaName, privacy: .public): status \(status)")
            }
        }
        Log.qa.notice("Injected hardware input: listening for \(Self.prefix, privacy: .public)<button>")
    }

    private func inject(_ button: HardwareButton) {
        Log.qa.notice(
            "Injected \(button.qaName, privacy: .public)\(self.isEnabled ? "" : " (hardware input off: ignored)", privacy: .public)"
        )
        onEvent?(InputEvent(button: button, phase: .began))
        onEvent?(InputEvent(button: button, phase: .ended))
    }
}
#endif
