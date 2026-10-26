import AppKit
import ApplicationServices
import SuperTrackpadCore
import OSLog

/// Accessibility work stays off the UI/event-tap thread. No private window IDs.
final class WindowCatalog {
    struct Snapshot {
        var windows: [WindowItem]
        var focusedID: UUID?
        var unavailableApps: Int
    }
    private struct NativeWindow { var item: WindowItem; let element: AXUIElement? }
    private struct AppInfo { let pid: pid_t; let name: String; let bundle: String; let hidden: Bool }
    private let queue = DispatchQueue(label: "SuperTools.WindowCatalog", qos: .userInitiated)
    private var windows: [NativeWindow] = [] // Owned by queue.
    private var history: [UUID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var enabled = false
    private let cancellationLock = NSLock()
    private var activationGeneration: UInt64 = 0
    var onWindowsChanged: (() -> Void)?
    private let diagnosticLock = NSLock()
    private var diagnosticEvents: [String] = []
    var activationDiagnostics: [String] {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }; return diagnosticEvents
    }
    private func trace(_ stage: String) {
        diagnosticLock.lock()
        diagnosticEvents.append(stage)
        if diagnosticEvents.count > 24 { diagnosticEvents.removeFirst(diagnosticEvents.count - 24) }
        diagnosticLock.unlock()
        Logger(subsystem: "local.SuperTrackpad", category: "WindowActivation").notice("\(stage, privacy: .public)")
    }


    func start() { queue.async { self.enabled = true } }
    func stop() {
        cancelPendingActivations()
        queue.async {
            self.enabled = false
            for observer in self.observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            self.observers = [:]; self.windows = []; self.history = []
        }
    }
    func cancelPendingActivations() {
        cancellationLock.lock(); activationGeneration &+= 1; cancellationLock.unlock()
    }
    private func activationToken() -> UInt64 {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return activationGeneration
    }

    func noteFocus(processID: pid_t) {
        queue.async {
            guard self.enabled else { return }
            self.recordFocus(processID)
        }
    }

    func refresh(includePreviewMetadata: Bool = false, completion: @escaping (Snapshot) -> Void) {
        // Never synchronously dispatch back to main from the AX worker.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(includePreviewMetadata: includePreviewMetadata, completion: completion) }
            return
        }
        let local = MainWindowPresence.shared.snapshot(includeFrame: includePreviewMetadata)
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != getpid() else { return nil }
            return AppInfo(pid: app.processIdentifier, name: app.localizedName ?? "Application", bundle: app.bundleIdentifier ?? "", hidden: app.isHidden)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async {
            guard self.enabled else { return }
            var result: [NativeWindow] = []
            var unavailable = 0
            var focusedID: UUID?
            let livePIDs = Set(apps.map(\.pid))
            for pid in Array(self.observers.keys) where !livePIDs.contains(pid) {
                if let observer = self.observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            }
            for app in apps {
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, 0.12)
                guard let elements: [AXUIElement] = self.attribute(element, kAXWindowsAttribute) else { unavailable += 1; continue }
                self.observe(app.pid, element: element)
                let focused: AXUIElement? = app.pid == focusedPID ? self.attribute(element, kAXFocusedWindowAttribute) : nil
                for window in Self.deduplicatedElements(elements) {
                    AXUIElementSetMessagingTimeout(window, 0.12)
                    guard self.isEligible(window) else { continue }
                    let id = self.windows.first { $0.item.processID == app.pid && ($0.element.map { CFEqual($0, window) } ?? false) }?.item.id ?? UUID()
                    let title: String = self.attribute(window, kAXTitleAttribute) ?? ""
                    let minimized: Bool = self.attribute(window, kAXMinimizedAttribute) ?? false
                    let item = WindowItem(id: id, processID: app.pid, appName: app.name, bundleIdentifier: app.bundle,
                                          title: title, isMinimized: minimized, isHidden: app.hidden, frame: includePreviewMetadata ? self.frame(window) : nil)
                    result.append(NativeWindow(item: item, element: window))
                    if let focused, CFEqual(focused, window) { focusedID = id }
                    if let observer = self.observers[app.pid] {
                        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
                    }
                }
            }
            if let local {
                result.append(NativeWindow(item: local.item, element: nil))
                if local.focused { focusedID = local.item.id }
            }
            self.windows = result
            let ids = Set(result.map { $0.item.id })
            self.history = self.history.filter { ids.contains($0) }
            if let focusedID { self.remember(focusedID) }
            let items = WindowOrdering.recentFirst(result.map(\.item), history: self.history, focusedID: focusedID)
            let snapshot = Snapshot(windows: items, focusedID: focusedID, unavailableApps: unavailable)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func activate(_ id: UUID, expectedProcessID: pid_t?, completion: @escaping (Result<String, Error>) -> Void) {
        // Each request supersedes all pending work, including queued main-thread effects.
        cancelPendingActivations()
        let token = activationToken()
        diagnosticLock.lock(); diagnosticEvents.removeAll(keepingCapacity: true); diagnosticLock.unlock()
        queue.async {
            guard let window = self.windows.first(where: { $0.item.id == id }) else {
                DispatchQueue.main.async { completion(.failure(WindowActivationCoordinator.Failure(message: "That window is no longer available. Open the switcher again."))) }; return
            }
            let local = window.item.processID == getpid()
            let application = local ? nil : AXUIElementCreateApplication(window.item.processID)
            if let application { AXUIElementSetMessagingTimeout(application, 0.12) }
            let coordinator = WindowActivationCoordinator(
                origin: expectedProcessID, target: window.item.processID, local: local,
                minimized: window.item.isMinimized, name: window.item.appName,
                success: "\(window.item.appName) — \(window.item.title)",
                boundary: .init(
                    schedule: { lane, delay, work in
                        let destination = lane == .main ? DispatchQueue.main : self.queue
                        destination.asyncAfter(deadline: .now() + delay, execute: work)
                    },
                    current: { self.activationToken() == token },
                    frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    now: { ProcessInfo.processInfo.systemUptime },
                    available: {
                        guard self.enabled, AXIsProcessTrusted(),
                              let app = NSRunningApplication(processIdentifier: window.item.processID), !app.isTerminated else { return false }
                        return local || window.element.map { self.isEligible($0) } == true
                    },
                    restore: { window.element.map { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success } ?? false },
                    unhide: { NSRunningApplication(processIdentifier: window.item.processID)?.unhide() },
                    activateApp: { NSRunningApplication(processIdentifier: window.item.processID)?.activate(options: []) ?? false },
                    foreground: {
                        guard let application else { return }
                        var settable: DarwinBoolean = false
                        if AXUIElementIsAttributeSettable(application, kAXFrontmostAttribute as CFString, &settable) == .success && settable.boolValue {
                            // Recheck after the remote query before the foreground write.
                            guard self.activationToken() == token else { return }
                            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                            guard pid == expectedProcessID || pid == window.item.processID else { return }
                            let result = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                            self.trace("AX frontmost result=\(result.rawValue)")
                        }
                    },
                    makeMain: { if let element = window.element { _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) } },
                    raise: { window.element.map { AXUIElementPerformAction($0, kAXRaiseAction as CFString) == .success } ?? false },
                    activateLocal: { MainWindowPresence.shared.activate(id) },
                    focused: {
                        if local {
                            let snapshot = MainWindowPresence.shared.snapshot(includeFrame: false)
                            return snapshot?.item.id == id && snapshot?.focused == true
                        }
                        guard let application, let element = window.element,
                              let focused: AXUIElement = self.attribute(application, kAXFocusedWindowAttribute) else { return false }
                        return CFEqual(element, focused)
                    },
                    remember: { self.remember(id) },
                    trace: { self.trace($0) }
                ), completion: { result in
                    switch result {
                    case .success: self.trace("result: verified success")
                    case .failure(let error): self.trace("result: failure \(error.localizedDescription)")
                    }
                    completion(result)
                })
            coordinator.start()
        }
    }

    /// AX providers can repeat equivalent references in AXWindows. Compare remote identity before
    /// assigning UUIDs, preserving genuinely distinct windows even when their titles are identical.
    static func deduplicatedElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var unique: [AXUIElement] = []
        for element in elements where !unique.contains(where: { CFEqual($0, element) }) { unique.append(element) }
        return unique
    }

    private func isEligible(_ element: AXUIElement) -> Bool {
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        // Standard windows need no extra AX calls, including minimized/hidden windows or other Spaces.
        if WindowEligibility.isEligible(role: role, subrole: subrole) { return true }
        guard role == kAXWindowRole, subrole == kAXDialogSubrole else { return false }
        let isMain: Bool? = attribute(element, kAXMainAttribute)
        if isMain == true { return true }
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, kAXMainAttribute as CFString, &settable)
        let mainIsSettable: Bool? = result == .success ? settable.boolValue : nil
        return WindowEligibility.isEligible(role: role, subrole: subrole, isMain: isMain, mainIsSettable: mainIsSettable)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let position = positionRef as! AXValue, size = sizeRef as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    private func remember(_ id: UUID) { history.removeAll { $0 == id }; history.insert(id, at: 0) }
    private func recordFocus(_ pid: pid_t) {
        if pid == getpid() {
            DispatchQueue.main.async {
                guard let local = MainWindowPresence.shared.snapshot(includeFrame: false), local.focused else { return }
                self.queue.async { if self.enabled { self.remember(local.item.id) } }
            }
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        guard let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute),
              let window = windows.first(where: { $0.item.processID == pid && ($0.element.map { CFEqual($0, focused) } ?? false) }) else { return }
        remember(window.item.id)
    }
    private func observe(_ pid: pid_t, element: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else { return }
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    private static let callback: AXObserverCallback = { _, element, notification, context in
        guard let context else { return }
        let service = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        service.queue.async {
            guard service.enabled else { return }
            if notification as String == kAXFocusedWindowChangedNotification { service.recordFocus(pid) }
            else { DispatchQueue.main.async { service.onWindowsChanged?() } }
        }
    }
}
