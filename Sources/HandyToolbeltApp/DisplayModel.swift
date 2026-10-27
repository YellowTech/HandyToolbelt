import AppKit
import ApplicationServices
import Combine
import HandyToolbeltCore

final class DisplayModel: ObservableObject {
    @Published private(set) var enabled = true
    @Published private(set) var available = true
    @Published private(set) var progress = ProgressSessions()
    var onSessionUnavailable: (() -> Void)?
    private let presenter: VisualFeedbackPresenter?
    private var previewID: UUID?
    private var previewWork: DispatchWorkItem?
    private var expiration: DispatchWorkItem?
    private var expirationLifetime = FeedbackLifetime()
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var awake = true
    private var sessionActive = true
    init(presenter: VisualFeedbackPresenter? = VisualFeedbackPresenter(), observeSession: Bool = true) {
        self.presenter = presenter
        guard observeSession else { return }
        sessionActive = Self.currentSessionIsActive()
        available = awake && sessionActive
        let distributed = DistributedNotificationCenter.default()
        for rawName in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            lockObservers.append(distributed.addObserver(forName: Notification.Name(rawName), object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.sessionActive = note.name.rawValue == "com.apple.screenIsLocked" ? false : Self.currentSessionIsActive()
                self.updateAvailability()
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                switch note.name {
                case NSWorkspace.willSleepNotification: self.awake = false
                case NSWorkspace.didWakeNotification: self.awake = true; self.sessionActive = Self.currentSessionIsActive()
                case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                default: self.sessionActive = Self.currentSessionIsActive()
                }
                self.updateAvailability()
            })
        }
    }
    deinit {
        expiration?.cancel(); previewWork?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    private static func currentSessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[kCGSessionOnConsoleKey as String] as? Bool ?? false)
            && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }
    private func updateAvailability() {
        available = awake && sessionActive
        if !available { dismiss(); onSessionUnavailable?() }
    }
    var canDisplay: Bool { enabled && available }
    func configure(enabled: Bool) {
        self.enabled = enabled
        if !canDisplay { dismiss() }
    }
    @discardableResult func text(_ text: String, duration: Double = GestureAction.defaultTextDuration) -> Bool {
        guard canDisplay else { return false }
        presenter?.showText(.init(kind: .showText, text: text, textDuration: duration)); return true
    }
    @discardableResult func toast(_ text: String, duration: Double = GestureAction.defaultTextDuration) -> Bool {
        guard canDisplay, progress.latest == nil else { return false }
        presenter?.showToast(text, duration: duration); return true
    }
    @discardableResult func begin(_ value: WorkflowProgress, lifetime: ProgressSessions.Lifetime = .external) -> Bool {
        guard canDisplay else { return false }
        cancelProgressPreview()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        progress.begin(value, screenID: screenID?.stringValue, lifetime: lifetime); render(); return true
    }
    @discardableResult func update(_ value: WorkflowProgress) -> Bool {
        guard canDisplay else { return false }
        if value.id != previewID { cancelProgressPreview() }
        let updated = progress.update(value); render(); return updated
    }
    /// A bounded visual demo; no actions or automation runner are involved.
    @discardableResult func previewProgress() -> Bool {
        cancelProgressPreview()
        guard canDisplay, progress.latest == nil else { return false }
        var value = WorkflowProgress(title: "Progress demo", steps: ["Prepare", "Process", "Finish"])
        value.steps[0].state = .running
        guard begin(value) else { return false }
        previewID = value.id
        advancePreview(value, completed: 0)
        return true
    }
    private func advancePreview(_ value: WorkflowProgress, completed: Int) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.canDisplay, self.previewID == value.id else { return }
            var next = value
            next.steps[completed].state = .completed
            let count = completed + 1
            if count == next.steps.count {
                next.state = .completed
                self.previewWork = nil
                _ = self.update(next)
            } else {
                next.steps[count].state = .running
                _ = self.update(next)
                self.advancePreview(next, completed: count)
            }
        }
        previewWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }
    func cancelProgressPreview() {
        previewWork?.cancel(); previewWork = nil
        guard let id = previewID else { return }
        previewID = nil
        progress.dismiss(id); render()
    }
    func dismissToast() { presenter?.dismissToast() }
    func dismiss(_ id: UUID? = nil) {
        if id == nil || id == previewID { cancelProgressPreview() }
        progress.dismiss(id)
        if id == nil { presenter?.cancelAll() }
        render()
    }
    private func render() {
        expiration?.cancel(); expiration = nil
        expirationLifetime.cancel()
        if let session = progress.latest { presenter?.showProgress(session.progress, screenID: session.screenID) }
        else { presenter?.dismissProgress() }
        guard let next = progress.nextExpiry else { return }
        let token = expirationLifetime.replace()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.expirationLifetime.expire(token) else { return }
            self.progress.expire(); self.render()
        }
        expiration = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next - Date.timeIntervalSinceReferenceDate), execute: item)
    }
}
