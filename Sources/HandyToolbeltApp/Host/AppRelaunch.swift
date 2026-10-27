import AppKit

/// Launch Services starts the same bundle. The replacement waits before starting any listeners.
/// There is no shell command, detached helper, or permanent second process.
final class AppRelaunch {
    private var waitTimer: Timer?
    static let parentArgument = "--relaunch-from-pid"

    func launchReplacement(section: String, completion: @escaping (Error?) -> Void) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            completion(RelaunchError.message("Restart is available when running HandyToolbelt.app. Build and open the app bundle first."))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.arguments = [Self.parentArgument, String(getpid()), "--section", section]
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if let error { completion(error) }
                else if let app, app.processIdentifier != getpid(), !app.isTerminated { completion(nil) }
                else { completion(RelaunchError.message("macOS did not start a replacement. HandyToolbelt is still running; try again.")) }
            }
        }
    }

    func afterPreviousInstanceExits(_ completion: @escaping () -> Void) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: Self.parentArgument), index + 1 < arguments.count,
              let pid = pid_t(arguments[index + 1]), pid > 0, pid != getpid(),
              let previous = NSRunningApplication(processIdentifier: pid), !previous.isTerminated,
              previous.bundleIdentifier == Bundle.main.bundleIdentifier,
              previous.bundleURL?.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath() else {
            completion(); return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            if previous.isTerminated {
                timer.invalidate(); self?.waitTimer = nil; completion()
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                // Never run two sets of input listeners if the old instance failed to exit.
                timer.invalidate(); self?.waitTimer = nil; NSApp.terminate(nil)
            }
        }
    }

    enum RelaunchError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
    }
}
