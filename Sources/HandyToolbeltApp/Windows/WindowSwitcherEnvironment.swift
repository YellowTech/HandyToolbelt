import AppKit
import ApplicationServices
import HandyToolbeltCore

/// Native catalogue work is asynchronous; completions are delivered on main.
protocol WindowSwitchCatalog: AnyObject {
    var onWindowsChanged: (() -> Void)? { get set }
    var activationDiagnostics: [String] { get }
    func cachedSnapshot() -> WindowCatalog.Snapshot?
    func start()
    func stop()
    func applicationsChanged()
    func noteFocus(processID: pid_t)
    func cancelPendingActivations()
    func refresh(includePreviewMetadata: Bool, completion: @escaping (WindowCatalog.Snapshot) -> Void)
    func cancelPreviewMetadata()
    func previewMetadata(for ids: [UUID], completion: @escaping ([WindowItem]) -> Void)
    func activate(_ id: UUID, expectedProcessID: pid_t?, completion: @escaping (Result<String, Error>) -> Void)
}
extension WindowCatalog: WindowSwitchCatalog {}
extension WindowSwitchCatalog {
    func cachedSnapshot() -> WindowCatalog.Snapshot? { nil }
    func applicationsChanged() { refresh { _ in } }
    func refresh(completion: @escaping (WindowCatalog.Snapshot) -> Void) { refresh(includePreviewMetadata: false, completion: completion) }
}

/// Only OS entry points are replaced by deterministic flow checks. Selection,
/// keyboard interpretation and activation orchestration remain production code.
struct WindowSwitcherEnvironment {
    var accessibility: () -> Bool
    var sessionActive: () -> Bool
    var frontmostPID: () -> pid_t?
    var startKeyboard: (WindowKeyboardMonitor) -> Bool
    var nativeServices: Bool
    static var live: Self {
        Self(accessibility: { AXIsProcessTrusted() }, sessionActive: {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
            return (session[kCGSessionOnConsoleKey as String] as? Bool ?? false)
                && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
        }, frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        startKeyboard: { $0.start() }, nativeServices: true)
    }
}
