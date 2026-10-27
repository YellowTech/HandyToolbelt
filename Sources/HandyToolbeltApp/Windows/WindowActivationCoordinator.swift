import Foundation

/// Production orchestration, with native effects and queue delivery supplied by the host.
/// Acknowledged requests are deliberately independent from observed focus.
final class WindowActivationCoordinator {
    enum Lane { case worker, main }
    struct Boundary {
        var schedule: (Lane, TimeInterval, @escaping () -> Void) -> Void
        var current: () -> Bool
        var frontmost: () -> Int32?
        var now: () -> TimeInterval
        var available: () -> Bool
        var restore: () -> Bool
        var unhide: () -> Void
        var activateApp: () -> Bool
        var foreground: () -> Void
        var makeMain: () -> Void
        var raise: () -> Bool
        var activateLocal: () -> Bool
        var focused: () -> Bool
        var remember: () -> Void
        var trace: (String) -> Void
    }
    private let boundary: Boundary
    private let origin: Int32?
    private let target: Int32
    private let local: Bool
    private let minimized: Bool
    private let name: String
    private let success: String
    private let completion: (Result<String, Error>) -> Void
    private var finished = false // Accessed only by scheduled work; queues hand off serially.
    private var deadline: TimeInterval = 0
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    init(origin: Int32?, target: Int32, local: Bool, minimized: Bool, name: String, success: String,
         boundary: Boundary, completion: @escaping (Result<String, Error>) -> Void) {
        self.origin = origin; self.target = target; self.local = local; self.minimized = minimized
        self.name = name; self.success = success; self.boundary = boundary; self.completion = completion
    }
    func start() {
        step(.worker) {
            guard self.boundary.available() else { self.fail("That window is no longer available. Open the switcher again."); return }
            if self.local {
                self.step(.main) {
                    guard self.boundary.activateLocal() else { self.fail("That window was closed. Refresh the window list."); return }
                    self.beginVerification()
                }
            } else {
                if self.minimized {
                    guard self.valid(), self.boundary.restore() else {
                        self.fail("\(self.name) did not restore this minimized window."); return
                    }
                }
                self.step(.main) {
                    self.boundary.unhide()
                    guard self.valid() else { return }
                    let accepted = self.boundary.activateApp()
                    self.boundary.trace("AppKit activation accepted=\(accepted)")
                    self.step(.worker) {
                        self.boundary.foreground()
                        guard self.valid() else { return }
                        self.boundary.makeMain()
                        guard self.valid() else { return }
                        guard self.boundary.raise() else { self.fail("\(self.name) did not allow this window to be raised."); return }
                        self.beginVerification()
                    }
                }
            }
        }
    }
    private func valid() -> Bool {
        guard !finished else { return false }
        guard boundary.current() else { fail("Window switch cancelled."); return false }
        let pid = boundary.frontmost()
        guard pid == origin || pid == target else { fail("Window switch cancelled because focus changed."); return false }
        return true
    }
    private func step(_ lane: Lane, delay: TimeInterval = 0, _ work: @escaping () -> Void) {
        boundary.schedule(lane, delay) { guard self.valid() else { return }; work() }
    }
    private func beginVerification() { deadline = boundary.now() + 1.2; observe() }
    private func observe(delay: TimeInterval = 0) {
        step(local ? .main : .worker, delay: delay) {
            let focused = self.boundary.focused()
            guard self.valid() else { return }
            let policy = WindowActivationVerification(originPID: self.origin, targetPID: self.target, deadline: self.deadline)
            let decision = policy.evaluate(frontmostPID: self.boundary.frontmost(), targetWindowFocused: focused, now: self.boundary.now())
            self.boundary.trace("verify decision=\(decision)")
            switch decision {
            case .wait: self.observe(delay: 0.08)
            case .focused:
                self.step(.worker) {
                    self.boundary.remember()
                    self.deliver(.success(self.success))
                }
            case .focusChanged: self.fail("Window switch cancelled because focus changed.")
            case .timedOut: self.fail("\(self.name) did not focus the selected window. Try again; activation was not confirmed.")
            }
        }
    }
    private func fail(_ message: String) { deliver(.failure(Failure(message: message))) }
    private func deliver(_ result: Result<String, Error>) {
        guard !finished else { return }; finished = true
        boundary.schedule(.main, 0) {
            if !self.boundary.current() { self.completion(.failure(Failure(message: "Window switch cancelled."))) }
            else if case .success = result,
                    self.boundary.frontmost() != self.target {
                self.completion(.failure(Failure(message: "Window switch cancelled because focus changed.")))
            } else { self.completion(result) }
        }
    }
}
