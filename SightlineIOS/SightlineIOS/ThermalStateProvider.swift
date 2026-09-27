import Foundation

/// A main-actor source so tests can drive thermal transitions without relying on device heat.
@MainActor
protocol ThermalStateProvider: AnyObject {
    var state: ProcessInfo.ThermalState { get }
    var onChange: ((ProcessInfo.ThermalState) -> Void)? { get set }
    func startObserving()
}

@MainActor
final class ProcessThermalStateProvider: ThermalStateProvider {
    private(set) var state: ProcessInfo.ThermalState
    var onChange: ((ProcessInfo.ThermalState) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init(processInfo: ProcessInfo = .processInfo) {
        // Read first: the notification only describes changes, not the initial state.
        state = processInfo.thermalState
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = ProcessInfo.processInfo.thermalState
                guard next != self.state else { return }
                self.state = next
                self.onChange?(next)
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
