import AppKit

/// The Commands environment survives closing the main window. Presentation is
/// deferred so registering it from Commands.body never opens a window mid-update.
final class MainWindowAccess {
    private var openWindow: (() -> Void)?
    private var pending = false
    private var scheduled = false
    private let presence: MainWindowPresence?
    private let schedule: (@escaping () -> Void) -> Void

    init(presence: MainWindowPresence? = nil, schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.presence = presence
        self.schedule = schedule
    }

    func register(_ openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        schedulePendingOpen()
    }

    func open() {
        pending = true
        schedulePendingOpen()
    }

    private func schedulePendingOpen() {
        guard pending, openWindow != nil, !scheduled else { return }
        scheduled = true
        schedule { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.pending, let openWindow = self.openWindow else { return }
            self.pending = false
            self.presence?.prepareToOpen()
            openWindow()
            self.presence?.reveal()
        }
    }
}
