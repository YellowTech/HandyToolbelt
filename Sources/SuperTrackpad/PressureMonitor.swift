import AppKit

/// Observes macOS pressure stages without replacing or suppressing input.
final class PressureMonitor {
    var onStage: ((Int, Double) -> Void)?
    private var local: Any?
    private var global: Any?
    func start() {
        guard local == nil else { return }
        local = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] event in
            self?.onStage?(event.stage, event.timestamp)
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .pressure) { [weak self] event in
            self?.onStage?(event.stage, event.timestamp)
        }
    }
    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil
    }
}
