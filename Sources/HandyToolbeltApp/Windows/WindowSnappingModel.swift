import AppKit
import ApplicationServices
import Combine
import HandyToolbeltCore

protocol WindowSnappingMonitoring: AnyObject {
    var diagnostics: WindowSnapDiagnosticsSnapshot { get }
    var onInteraction: (() -> Bool)? { get set }
    var onUnavailable: (() -> Void)? { get set }
    func start() -> Bool
    func stop()
    func cancel()
    func updateScreens()
    func applicationActivated(_ processID: pid_t)
}
extension WindowSnapMonitor: WindowSnappingMonitoring {}

/// Independent drag listener; no switcher catalog or window capture is needed.
final class WindowSnappingModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var eligible = false
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    @Published private(set) var monitorAvailable = false
    private let monitor: WindowSnappingMonitoring
    private let trusted: () -> Bool
    private let eligibility: () -> Bool
    private let sessionIsActive: () -> Bool
    private let workspaceCenter: NotificationCenter
    private let applicationCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private var running = false
    private var suspended = false
    private var awake = true
    private var active = true
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    var diagnostics: WindowSnapDiagnosticsSnapshot { monitor.diagnostics }

    init(monitor: WindowSnappingMonitoring = WindowSnapMonitor(),
         trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         eligibility: @escaping () -> Bool = { WindowSnapping.eligible(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, separateSpaces: NSScreen.screensHaveSeparateSpaces) },
         sessionIsActive: @escaping () -> Bool = { WindowSnappingModel.sessionActive },
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationCenter: NotificationCenter = .default,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default()) {
        self.monitor = monitor; self.trusted = trusted; self.eligibility = eligibility; self.sessionIsActive = sessionIsActive
        self.workspaceCenter = workspaceCenter; self.applicationCenter = applicationCenter; self.distributedCenter = distributedCenter
        hasAccessibility = trusted(); eligible = eligibility()
    }
    var status: String {
        if !enabled { return "Snapping is turned off" }
        if !eligible { return "macOS window tiling is available" }
        if !hasAccessibility { return "Accessibility needed" }
        if suspended { return "Paused while choosing windows or recording a shortcut" }
        if !monitorAvailable { return "Drag monitoring unavailable" }
        return "Drag windows to screen edges to snap"
    }
    func configure(enabled: Bool, running: Bool) {
        if self.enabled != enabled { self.enabled = enabled }; self.running = running
        if enabled && running { observe() } else { stopObservers() }
        refreshAvailability()
    }
    func setSuspended(_ value: Bool) { guard suspended != value else { return }; suspended = value; refreshAvailability() }
    func stop() { running = false; stopObservers(); monitor.stop(); if monitorAvailable { monitorAvailable = false } }
    deinit { stopObservers(); monitor.stop() }
    private static var sessionActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[kCGSessionOnConsoleKey as String] as? Bool ?? false) && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }
    func refreshAvailability() {
        let trust = trusted(), available = eligibility()
        if hasAccessibility != trust { hasAccessibility = trust }
        if eligible != available { eligible = available }
        guard enabled, running, available, trust, awake, active, sessionIsActive(), !suspended else {
            monitor.stop(); if monitorAvailable { monitorAvailable = false }; return
        }
        monitor.onInteraction = { [weak self] in
            guard let self else { return false }
            let trust = self.trusted(), available = self.eligibility()
            guard self.enabled, self.running, available, trust, self.awake, self.active, self.sessionIsActive(), !self.suspended else {
                self.refreshAvailability(); return false
            }
            return true
        }
        monitor.onUnavailable = { [weak self] in if self?.monitorAvailable == true { self?.monitorAvailable = false } }
        monitor.updateScreens(); let availableMonitor = monitor.start()
        if monitorAvailable != availableMonitor { monitorAvailable = availableMonitor }
    }
    private func observe() {
        guard observers.isEmpty else { return }
        awake = true; active = sessionIsActive()
        let workspace = workspaceCenter
        add(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.monitor.applicationActivated(app.processIdentifier) }
            self?.refreshAvailability()
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            add(workspace, name) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.willSleepNotification { self.awake = false }
                if name == NSWorkspace.didWakeNotification { self.awake = true }
                self.active = name == NSWorkspace.sessionDidResignActiveNotification ? false : self.sessionIsActive()
                self.refreshAvailability()
            }
        }
        add(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.monitor.cancel(); self?.refreshAvailability() }
        add(applicationCenter, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.monitor.cancel(); self?.refreshAvailability() }
        for rawName in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            add(distributedCenter, Notification.Name(rawName)) { [weak self] note in
                self?.active = note.name.rawValue != "com.apple.screenIsLocked" && (self?.sessionIsActive() ?? false)
                self?.refreshAvailability()
            }
        }
    }
    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ callback: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: callback)))
    }
    private func stopObservers() { for (center, observer) in observers { center.removeObserver(observer) }; observers = [] }
}
