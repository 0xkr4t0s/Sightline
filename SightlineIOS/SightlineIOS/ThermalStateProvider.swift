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
    private let readState: @MainActor () -> ProcessInfo.ThermalState
    private let notifications: NotificationCenter

    init(
        readState: @escaping @MainActor () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        notifications: NotificationCenter = .default
    ) {
        self.readState = readState
        self.notifications = notifications
        state = readState()
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = notifications.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // The state may have changed after init but before the observer was registered.
        refresh()
    }

    private func refresh() {
        let next = readState()
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    isolated deinit {
        if let observer { notifications.removeObserver(observer) }
    }
}
