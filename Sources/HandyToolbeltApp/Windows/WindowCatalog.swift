import AppKit
import ApplicationServices
import HandyToolbeltCore
import OSLog

/// Accessibility work stays off the UI/event-tap thread.
final class WindowCatalog {
    struct Snapshot {
        var windows: [WindowItem]
        var focusedID: UUID?
        var unavailableApps: Int
    }
    private struct NativeWindow {
        var item: WindowItem
        let element: AXUIElement?
        var windowID: CGWindowID? = nil
    }
    private struct AppInfo { let pid: pid_t; let name: String; let bundle: String; let hidden: Bool }
    private let queue: DispatchQueue
    private let focusQueue = DispatchQueue(label: "HandyToolbelt.WindowFocus", qos: .userInitiated)
    private var pendingFocus = Set<pid_t>()
    private var dirtyFocus = Set<pid_t>()
    private var processFocusRevision: [pid_t: UInt64] = [:]
    private var focusedElements: [pid_t: AXUIElement] = [:] // Protected by stateLock.
    private let activationQueue: DispatchQueue
    private let stateLock = NSLock()
    private var published: [NativeWindow]?
    private var destroyedElements: [AXUIElement] = []
    private var focusedByProcess: [pid_t: UUID] = [:]
    private var focusRevision: UInt64 = 0
    private var stateGeneration: UInt64 = 0
    private var accepting = false
    private var refreshSchedule = WindowRefreshSchedule() // Main-thread owned.
    private var refreshCompletions: [(Snapshot) -> Void] = []
    private let metadataQueue = DispatchQueue(label: "HandyToolbelt.WindowPreviewMetadata", qos: .utility)
    private var metadataGeneration: UInt64 = 0 // Protected by cancellationLock.
    private var windows: [NativeWindow] = [] // Owned by queue.
    private var history: [UUID] = []
    private let otherSpaces = OtherSpaceWindows()
    private var spaceRetry: DispatchWorkItem? // Main-thread owned.
    private var remainingSpaceRetries = 4
    private var nextScanAppOffset = 0 // Worker-owned fairness after a shared read budget is exhausted.
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
        Logger(subsystem: "local.HandyToolbelt", category: "WindowActivation").notice("\(stage, privacy: .public)")
    }


    init(scanQueue: DispatchQueue = DispatchQueue(label: "HandyToolbelt.WindowCatalog", qos: .userInitiated),
         activationQueue: DispatchQueue = DispatchQueue(label: "HandyToolbelt.WindowActivation", qos: .userInitiated)) {
        self.queue = scanQueue; self.activationQueue = activationQueue
    }
    /// Retain only previously observed handles when a live app temporarily fails enumeration.
    static func retainedDuringEnumerationFailure<Handle>(_ known: [Handle], unavailablePIDs: Set<pid_t>,
        livePIDs: Set<pid_t>, processID: (Handle) -> pid_t, destroyed: (Handle) -> Bool) -> [Handle] {
        known.filter { livePIDs.contains(processID($0)) && unavailablePIDs.contains(processID($0)) && !destroyed($0) }
    }

    func start() {
        stateLock.lock(); accepting = true; stateLock.unlock()
        queue.async { self.enabled = true }
    }
    /// Main-thread reads only local process state; no remote AX calls on the opening path.
    func cachedSnapshot() -> Snapshot? {
        precondition(Thread.isMainThread)
        guard AXIsProcessTrusted() else { return nil }
        stateLock.lock()
        let cached = accepting ? published : nil
        let focus = focusedByProcess
        stateLock.unlock()
        guard let cached else { return nil }
        let local = MainWindowPresence.shared.snapshot(includeFrame: false)
        var items = cached.compactMap { window -> WindowItem? in
            if window.item.processID == getpid() { return local?.item.id == window.item.id ? local?.item : nil }
            guard let app = NSRunningApplication(processIdentifier: window.item.processID), !app.isTerminated else { return nil }
            var item = window.item; item.isHidden = app.isHidden; return item
        }
        if let local, !items.contains(where: { $0.id == local.item.id }) { items.append(local.item) }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = pid == getpid() ? (local?.focused == true ? local?.item.id : nil) : pid.flatMap { focus[$0] }
        return Snapshot(windows: items, focusedID: focused, unavailableApps: 0)
    }
    func stop() {
        precondition(Thread.isMainThread)
        refreshSchedule.invalidate(); refreshCompletions = []
        spaceRetry?.cancel(); spaceRetry = nil; remainingSpaceRetries = 4
        cancelPendingActivations()
        cancelPreviewMetadata()
        stateLock.lock(); accepting = false; published = nil; focusedByProcess = [:]; focusedElements = [:]; processFocusRevision = [:]; destroyedElements = []; stateGeneration &+= 1; stateLock.unlock()
        queue.async {
            self.enabled = false
            for observer in self.observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            self.observers = [:]; self.windows = []; self.history = []; self.otherSpaces.reset()
        }
    }
    func cancelPendingActivations() {
        cancellationLock.lock(); activationGeneration &+= 1; cancellationLock.unlock()
    }
    private func activationToken() -> UInt64 {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return activationGeneration
    }

    func noteFocus(processID: pid_t) {
        if processID == getpid() {
            stateLock.lock(); let generation = stateGeneration; stateLock.unlock()
            DispatchQueue.main.async {
                guard let local = MainWindowPresence.shared.snapshot(includeFrame: false), local.focused else { return }
                self.stateLock.lock()
                guard self.accepting, self.stateGeneration == generation else { self.stateLock.unlock(); return }
                self.focusRevision &+= 1
                if self.published != nil {
                    self.published?.removeAll { $0.item.processID == getpid() && $0.item.id != local.item.id }
                    if self.published?.contains(where: { $0.item.id == local.item.id }) == false {
                        self.published?.append(NativeWindow(item: local.item, element: nil))
                    }
                    self.promotePublished(local.item.id)
                }
                self.stateLock.unlock()
                self.queue.async { if self.matchesGeneration(generation) { self.remember(local.item.id) } }
            }
            return
        }
        stateLock.lock()
        guard accepting else { stateLock.unlock(); return }
        focusRevision &+= 1; processFocusRevision[processID, default: 0] &+= 1
        guard pendingFocus.insert(processID).inserted else { dirtyFocus.insert(processID); stateLock.unlock(); return }
        let generation = stateGeneration, revision = processFocusRevision[processID, default: 0]
        stateLock.unlock()
        focusQueue.async {
            self.recordFocus(processID, generation: generation, revision: revision)
            self.stateLock.lock()
            self.pendingFocus.remove(processID)
            let again = self.dirtyFocus.remove(processID) != nil && self.accepting
            self.stateLock.unlock()
            if again { self.noteFocus(processID: processID) }
        }
    }

    func refresh(includePreviewMetadata: Bool = false, completion: @escaping (Snapshot) -> Void) {
        // Never synchronously dispatch back to main from the AX worker.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(includePreviewMetadata: includePreviewMetadata, completion: completion) }
            return
        }
        refreshCompletions.append(completion)
        guard isAccepting else { refreshCompletions = []; return }
        guard let run = refreshSchedule.begin() else { return }
        stateLock.lock(); let generation = stateGeneration; let revision = focusRevision; let processRevisions = processFocusRevision; stateLock.unlock()
        let local = MainWindowPresence.shared.snapshot(includeFrame: includePreviewMetadata)
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
            guard app.activationPolicy != .prohibited, !app.isTerminated, app.processIdentifier != getpid() else { return nil }
            return AppInfo(pid: app.processIdentifier, name: app.localizedName ?? "Application", bundle: app.bundleIdentifier ?? "", hidden: app.isHidden)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async {
            guard self.enabled else { return }
            var result: [NativeWindow] = []
            var unavailable = 0
            var unavailablePIDs = Set<pid_t>()
            var focusedID: UUID?
            var scanFocus: [pid_t: UUID] = [:]
            let eligibilityBudget = EligibilityReadBudget()
            var scanOrder = EligibilityScanOrder(count: apps.count, startOffset: self.nextScanAppOffset)
            let livePIDs = Set(apps.map(\.pid))
            let inventory = Self.windowInventory(livePIDs: livePIDs)
            self.otherSpaces.begin(inventory)
            let current = { self.matchesGeneration(generation) }
            var visibleWindows = inventory.visible
            var hasVisibleEvidence = !visibleWindows.isEmpty
            func visibleEvidence() -> [VisibleWindowEvidence] {
                if !hasVisibleEvidence {
                    visibleWindows = Self.visibleWindowEvidence()
                    hasVisibleEvidence = true
                }
                return visibleWindows
            }
            for pid in Array(self.observers.keys) where !livePIDs.contains(pid) {
                if let observer = self.observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            }
            for appIndex in scanOrder.indices {
                let app = apps[appIndex]
                guard self.matchesGeneration(generation) else { return }
                guard eligibilityBudget.available else {
                    scanOrder.exhausted(at: appIndex)
                    unavailable += 1; unavailablePIDs.insert(app.pid); continue
                }
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, 0.12)
                let published = self.publishedWindows(element)
                if published.windows == nil {
                    unavailable += 1; unavailablePIDs.insert(app.pid)
                } else {
                    self.observe(app.pid, element: element)
                }
                let focused = published.focused
                let targets = inventory.offscreenByProcess[app.pid] ?? []
                var unique = Self.deduplicatedElements(Array((published.windows ?? []).prefix(512)) + [focused, published.main].compactMap { $0 })
                var exactIDs: [AXUIElement: CGWindowID] = [:]
                if !targets.isEmpty {
                    let start = ProcessInfo.processInfo.systemUptime
                    for window in unique {
                        guard current(), ProcessInfo.processInfo.systemUptime - start < 0.035 else { break }
                        AXUIElementSetMessagingTimeout(window, 0.045)
                        if let id = OtherSpaceWindows.id(of: window) { exactIDs[window] = id }
                    }
                    var known = Set(exactIDs.values)
                    for prior in self.windows where prior.item.processID == app.pid {
                        guard current(), ProcessInfo.processInfo.systemUptime - start < 0.065 else { break }
                        if let id = prior.windowID, !targets.contains(id) || known.contains(id) { continue }
                        guard let element = prior.element, exactIDs[element] == nil,
                              let id = OtherSpaceWindows.id(of: element), targets.contains(id), !known.contains(id),
                              prior.windowID == nil || prior.windowID == id else { continue }
                        unique.append(element)
                        exactIDs[element] = id
                        known.insert(id)
                    }
                    let recovered = self.otherSpaces.recover(pid: app.pid, targets: targets, excluding: known, current: current)
                    for (id, element) in recovered.sorted(by: { $0.key < $1.key }) {
                        unique.append(element)
                        exactIDs[element] = id
                    }
                }
                for window in unique.prefix(512) { AXUIElementSetMessagingTimeout(window, 0.12) }
                let classification = self.eligibleElements(unique, processID: app.pid, focused: focused,
                    current: current, budget: eligibilityBudget, visible: visibleEvidence,
                    offscreen: { exactIDs[$0].map(targets.contains) == true })
                guard current() else { return }
                if classification.incomplete {
                    if unavailablePIDs.insert(app.pid).inserted { unavailable += 1 }
                    if !eligibilityBudget.available { scanOrder.exhausted(at: appIndex) }
                }
                var collectedWindowIDs = Set<CGWindowID>()
                for window in classification.elements {
                    guard current() else { return }
                    let exactID = exactIDs[window]
                    let prior = self.windows.first {
                        $0.item.processID == app.pid &&
                        ((exactID != nil && $0.windowID == exactID) || $0.element.map { CFEqual($0, window) } == true)
                    }
                    let windowID = exactID ?? prior?.windowID
                    if let windowID, !collectedWindowIDs.insert(windowID).inserted { continue }
                    let id = prior?.item.id ?? UUID()
                    let title: String = self.attribute(window, kAXTitleAttribute) ?? ""
                    let minimized: Bool = self.attribute(window, kAXMinimizedAttribute) ?? false
                    let item = WindowItem(id: id, processID: app.pid, appName: app.name, bundleIdentifier: app.bundle,
                                          title: title, isMinimized: minimized, isHidden: app.hidden, frame: includePreviewMetadata ? self.frame(window) : nil)
                    result.append(NativeWindow(item: item, element: window, windowID: windowID))
                    if let focused, CFEqual(focused, window) {
                        scanFocus[app.pid] = id
                        if app.pid == focusedPID { focusedID = id }
                    }
                    if let observer = self.observers[app.pid] {
                        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
                    }
                }
            }
            let hasMoreSpaceWork = self.otherSpaces.hasMoreWork
            if let deferred = self.otherSpaces.firstDeferredProcess, let index = apps.firstIndex(where: { $0.pid == deferred }) {
                scanOrder.exhausted(at: index)
            }
            self.nextScanAppOffset = scanOrder.nextStartOffset
            // Budget rotation affects work order, not the chooser's stable alphabetical fallback order.
            let appOrder = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($0.element.pid, $0.offset) })
            result = Self.catalogueOrder(result, appOrder: appOrder, processID: { $0.item.processID })
            if let local {
                result.append(NativeWindow(item: local.item, element: nil))
                if local.focused { focusedID = local.item.id }
            }
            self.stateLock.lock()
            let dead = self.destroyedElements
            let collectedIDs = Set(result.map { $0.item.id })
            result += Self.retainedDuringEnumerationFailure(self.windows.filter { !collectedIDs.contains($0.item.id) }, unavailablePIDs: unavailablePIDs,
                livePIDs: livePIDs, processID: { $0.item.processID },
                destroyed: { window in dead.contains { element in window.element.map { CFEqual(element, $0) } == true } })
            result.removeAll { window in dead.contains { element in window.element.map { CFEqual(element, $0) } == true } }
            if let focusedPID, unavailablePIDs.contains(focusedPID), scanFocus[focusedPID] == nil { focusedID = self.focusedByProcess[focusedPID] }
            self.stateLock.unlock()
            self.windows = result
            let ids = Set(result.map { $0.item.id })
            self.history = self.history.filter { ids.contains($0) }
            if let focusedID { self.remember(focusedID) }
            let items = WindowOrdering.recentFirst(result.map(\.item), history: self.history, focusedID: focusedID)
            self.stateLock.lock()
            let canPublish = self.accepting && self.stateGeneration == generation
            if canPublish {
                let fresh = items.compactMap { item in result.first { $0.item.id == item.id } }.filter { window in
                    !self.destroyedElements.contains { dead in window.element.map { CFEqual(dead, $0) } == true }
                }
                if self.focusRevision != revision, let prior = self.published {
                    let order = prior.map { $0.item.id }
                    self.published = order.compactMap { id in fresh.first { $0.item.id == id } } + fresh.filter { !order.contains($0.item.id) }
                } else { self.published = fresh }
                for pid in livePIDs {
                    if unavailablePIDs.contains(pid) { continue }
                    if self.processFocusRevision[pid, default: 0] == processRevisions[pid, default: 0] {
                        self.focusedByProcess[pid] = scanFocus[pid]
                    } else if let element = self.focusedElements[pid] {
                        self.focusedByProcess[pid] = fresh.first { $0.item.processID == pid && $0.element.map { CFEqual($0, element) } == true }?.item.id
                    }
                }
                self.focusedByProcess = self.focusedByProcess.filter { livePIDs.contains($0.key) && ids.contains($0.value) }
                self.focusedElements = self.focusedElements.filter { livePIDs.contains($0.key) }
                self.processFocusRevision = self.processFocusRevision.filter { livePIDs.contains($0.key) }
            }
            self.stateLock.unlock()
            DispatchQueue.main.async {
                guard let again = self.refreshSchedule.finish(run) else { return }
                self.stateLock.lock()
                let deliver = self.accepting && self.stateGeneration == generation
                self.stateLock.unlock()
                let completions = self.refreshCompletions; self.refreshCompletions = []
                if deliver, var latest = self.cachedSnapshot() {
                    latest.unavailableApps = unavailable
                    completions.forEach { $0(latest) }
                }
                if again, deliver { self.refreshAfterEvent() }
                if deliver { self.retrySpaceDiscovery(if: hasMoreSpaceWork) }
            }
        }
    }

    func applicationsChanged() {
        remainingSpaceRetries = 4
        refreshAfterEvent()
    }

    private func retrySpaceDiscovery(if needed: Bool) {
        guard needed else {
            spaceRetry?.cancel(); spaceRetry = nil; remainingSpaceRetries = 4
            return
        }
        guard spaceRetry == nil, remainingSpaceRetries > 0 else { return }
        let delay = 0.25 * Double(5 - remainingSpaceRetries)
        remainingSpaceRetries -= 1
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.spaceRetry = nil
            self.refreshAfterEvent()
        }
        spaceRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }
    private func refreshAfterEvent() {
        precondition(Thread.isMainThread)
        guard isAccepting else { return }
        if refreshSchedule.token != nil { refreshSchedule.noteChange(); return }
        refresh { _ in self.onWindowsChanged?() }
    }
    func cancelPreviewMetadata() {
        cancellationLock.lock(); metadataGeneration &+= 1; cancellationLock.unlock()
    }
    private func metadataToken() -> UInt64 {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return metadataGeneration
    }
    /// Enrichment never occupies the activation/catalogue lane. Only visible windows and
    /// their title peers are queried, with a fixed bound even for very large catalogues.
    func previewMetadata(for ids: [UUID], completion: @escaping ([WindowItem]) -> Void) {
        precondition(Thread.isMainThread)
        cancelPreviewMetadata()
        let token = metadataToken()
        let local = MainWindowPresence.shared.snapshot(includeFrame: true)
        stateLock.lock(); var candidates = accepting ? (published ?? []) : []; let active = accepting; stateLock.unlock()
        if active, let local, !candidates.contains(where: { $0.item.id == local.item.id }) {
            candidates.append(NativeWindow(item: local.item, element: nil))
        }
        let visible = candidates.filter { ids.contains($0.item.id) }
        let peers = candidates.filter { window in
            !ids.contains(window.item.id) && visible.contains { $0.item.processID == window.item.processID && $0.item.captureTitle == window.item.captureTitle }
        }
        let targets = Array((visible + peers).prefix(64))
        self.metadataQueue.async {
            var result: [WindowItem] = []
            for window in targets {
                guard self.metadataToken() == token else { return }
                var item = window.item
                if let element = window.element { item.frame = self.frame(element) }
                else if local?.item.id == item.id { item.frame = local?.item.frame }
                result.append(item)
            }
            DispatchQueue.main.async {
                guard self.metadataToken() == token else { return }
                completion(result)
            }
        }
    }

    func activate(_ id: UUID, expectedProcessID: pid_t?, completion: @escaping (Result<String, Error>) -> Void) {
        // Each request supersedes all pending work, including queued main-thread effects.
        cancelPendingActivations()
        let token = activationToken()
        diagnosticLock.lock(); diagnosticEvents.removeAll(keepingCapacity: true); diagnosticLock.unlock()
        let localSnapshot = MainWindowPresence.shared.snapshot(includeFrame: false)
        stateLock.lock()
        let target = accepting ? (localSnapshot?.item.id == id ? NativeWindow(item: localSnapshot!.item, element: nil) : published?.first(where: { $0.item.id == id })) : nil
        stateLock.unlock()
        activationQueue.async {
            guard let window = target else {
                DispatchQueue.main.async { completion(.failure(WindowActivationCoordinator.Failure(message: "That window is no longer available. Open the switcher again."))) }; return
            }
            let local = window.item.processID == getpid()
            // Cached rows can outlive a manual minimize; restoring uses current target state.
            let minimized: Bool = window.element.flatMap { self.attribute($0, kAXMinimizedAttribute) } ?? window.item.isMinimized
            let application = local ? nil : AXUIElementCreateApplication(window.item.processID)
            if let application { AXUIElementSetMessagingTimeout(application, 0.12) }
            let eligibilityBudget = EligibilityReadBudget()
            let coordinator = WindowActivationCoordinator(
                origin: expectedProcessID, target: window.item.processID, local: local,
                minimized: minimized, name: window.item.appName,
                success: "\(window.item.appName) — \(window.item.title)",
                boundary: .init(
                    schedule: { lane, delay, work in
                        let destination = lane == .main ? DispatchQueue.main : self.activationQueue
                        destination.asyncAfter(deadline: .now() + delay, execute: work)
                    },
                    current: { self.activationToken() == token },
                    frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    now: { ProcessInfo.processInfo.systemUptime },
                    available: {
                        guard self.isAccepting, AXIsProcessTrusted(),
                              let app = NSRunningApplication(processIdentifier: window.item.processID), !app.isTerminated else { return false }
                        return local || window.element.map { self.isEligible($0, processID: window.item.processID,
                            current: { self.activationToken() == token && self.isAccepting }, budget: eligibilityBudget,
                            windowID: window.windowID) } == true
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
                        return CFEqual(element, focused) || window.windowID.map { OtherSpaceWindows.id(of: focused) == $0 } == true
                    },
                    remember: {
                        self.stateLock.lock(); self.focusRevision &+= 1; self.processFocusRevision[window.item.processID, default: 0] &+= 1; self.focusedElements[window.item.processID] = window.element; self.focusedByProcess[window.item.processID] = id; self.promotePublished(id); self.stateLock.unlock()
                        self.queue.async { if self.isAccepting { self.remember(id) } }
                    },
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

    private func publishedWindows(_ element: AXUIElement) -> (windows: [AXUIElement]?, focused: AXUIElement?, main: AXUIElement?) {
        let names = [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute]
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        if status == .cannotComplete || status == .invalidUIElement { return (nil, nil, nil) }
        if status == .success,
           let attributes = values as? [Any], attributes.count == names.count {
            // Unsupported attributes are returned as AXValue errors when stop-on-error is disabled.
            func window(at index: Int) -> AXUIElement? {
                let value = attributes[index] as CFTypeRef
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return (value as! AXUIElement)
            }
            return (attributes[0] as? [AXUIElement], window(at: 1), window(at: 2))
        }
        return (attribute(element, kAXWindowsAttribute), attribute(element, kAXFocusedWindowAttribute), attribute(element, kAXMainWindowAttribute))
    }

    private static func windowInventory(livePIDs: Set<pid_t>) -> OtherSpaceWindows.Inventory {
        let rows = OtherSpaceWindows.isAvailable ?
            CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] : nil
        return OtherSpaceWindows.Inventory(rows: rows ?? [], livePIDs: livePIDs,
            assignedWindows: rows == nil ? [] : OtherSpaceWindows.assignedWindowIDs())
    }

    /// WindowServer metadata only: no image capture or Screen Recording permission.
    /// Called on a catalogue/activation worker, at most once per discovery pass.
    static func visibleWindowEvidence() -> [VisibleWindowEvidence] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return visibleWindowEvidence(rows: rows)
    }

    static func visibleWindowEvidence(rows: [[String: Any]]) -> [VisibleWindowEvidence] {
        rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber, layer.intValue >= 0,
                  let alpha = row[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue.isFinite, alpha.doubleValue > 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), WindowEligibility.validFrame(frame) else { return nil }
            return VisibleWindowEvidence(processID: pid.int32Value, frame: frame, title: row[kCGWindowName as String] as? String)
        }
    }

    struct EligibilityScanOrder {
        let indices: [Int]
        private(set) var nextStartOffset = 0
        private var hasResume = false
        init(count: Int, startOffset: Int) {
            let start = count == 0 ? 0 : startOffset % count
            indices = Array(start..<count) + Array(0..<start)
        }
        mutating func exhausted(at index: Int) {
            guard !hasResume else { return }
            hasResume = true; nextStartOffset = index
        }
    }
    static func catalogueOrder<Handle>(_ handles: [Handle], appOrder: [pid_t: Int], processID: (Handle) -> pid_t) -> [Handle] {
        handles.sorted { (appOrder[processID($0)] ?? Int.max) < (appOrder[processID($1)] ?? Int.max) }
    }

    enum EligibilityAttribute { case role, subrole, position, size, title, main, minimized }
    /// Worker-owned accounting spans all apps in a scan (or all revalidations of an activation).
    final class EligibilityReadBudget {
        let maximumQueries: Int
        let maximumDuration: TimeInterval
        private(set) var queries = 0
        private(set) var duration: TimeInterval = 0
        init(maximumQueries: Int = 2048, maximumDuration: TimeInterval = 1.2) {
            self.maximumQueries = maximumQueries; self.maximumDuration = maximumDuration
        }
        var available: Bool { queries < maximumQueries && duration < maximumDuration }
        func record(duration: TimeInterval) { queries += 1; self.duration += max(0, duration) }
    }
    struct EligibilityCollection { var indices: Set<Int>; var incomplete: Bool }

    /// Production native-read boundary, also exercised with fake readers/clocks by flow checks.
    /// A partial collection keeps classified standard windows, but never uses partial reservations.
    static func collectEligibility(count: Int, processID: pid_t, focusedIndex: Int?,
                                   current: () -> Bool, now: () -> TimeInterval,
                                   budget: EligibilityReadBudget, maximumAppQueries: Int = 512,
                                   maximumAppDuration: TimeInterval = 0.3,
                                   read: (Int, EligibilityAttribute) -> Any?,
                                   visible: () -> [VisibleWindowEvidence],
                                   offscreen: (Int) -> Bool = { _ in false }) -> EligibilityCollection {
        let limit = min(count, 512)
        var candidates = Array(repeating: WindowEligibilityCandidate(role: nil, subrole: nil), count: limit)
        var appQueries = 0, appDuration: TimeInterval = 0
        var aborted = false
        func canRead() -> Bool {
            !aborted && current() && budget.available && appQueries < maximumAppQueries && appDuration < maximumAppDuration
        }
        func record(_ start: TimeInterval) {
            let duration = max(0, now() - start)
            budget.record(duration: duration); appQueries += 1; appDuration += duration
            if !current() || !budget.available || appQueries >= maximumAppQueries || appDuration >= maximumAppDuration { aborted = true }
        }
        func query(_ index: Int, _ attribute: EligibilityAttribute) -> Any? {
            guard canRead() else { aborted = true; return nil }
            let start = now(), value = read(index, attribute)
            record(start); return value
        }
        var order = Array(0..<limit)
        if let focusedIndex, order.contains(focusedIndex) { order.removeAll { $0 == focusedIndex }; order.insert(focusedIndex, at: 0) }
        for index in order {
            guard canRead() else { aborted = true; break }
            candidates[index].role = query(index, .role) as? String
            if candidates[index].role == kAXWindowRole { candidates[index].subrole = query(index, .subrole) as? String }
        }
        let exact = Set(candidates.indices.filter { candidates[$0].role == kAXWindowRole && offscreen($0) })
        // Proven other-Space windows do not consume evidence from geometrically identical on-screen windows.
        for index in exact { candidates[index].role = nil }
        let standard = Set(candidates.indices.filter { WindowEligibility.isEligible(role: candidates[$0].role, subrole: candidates[$0].subrole) })
        let confirmed = standard.union(exact)
        guard !aborted, count <= limit else { return .init(indices: confirmed, incomplete: true) }
        guard candidates.contains(where: { $0.role == kAXWindowRole && $0.subrole != kAXStandardWindowSubrole }) else {
            return .init(indices: confirmed, incomplete: false)
        }
        for index in order where candidates[index].role == kAXWindowRole {
            if standard.contains(index) {
                candidates[index].isMinimized = query(index, .minimized) as? Bool ?? false
                if candidates[index].isMinimized { continue }
            }
            let position = query(index, .position) as? CGPoint
            let size = query(index, .size) as? CGSize
            if let position, let size { candidates[index].frame = CGRect(origin: position, size: size) }
            candidates[index].title = query(index, .title) as? String
            if !standard.contains(index) {
                candidates[index].isMain = query(index, .main) as? Bool ?? false
                candidates[index].isFocused = index == focusedIndex
            }
            if aborted { break }
        }
        guard canRead() else { return .init(indices: confirmed, incomplete: true) }
        let start = now(), evidence = visible()
        record(start)
        guard !aborted else { return .init(indices: confirmed, incomplete: true) }
        return .init(indices: WindowEligibility.eligibleIndices(candidates, processID: processID, visible: evidence).union(exact), incomplete: false)
    }

    private func eligibilityAttribute(_ element: AXUIElement, _ kind: EligibilityAttribute) -> Any? {
        switch kind {
        case .role: return attribute(element, kAXRoleAttribute) as String?
        case .subrole: return attribute(element, kAXSubroleAttribute) as String?
        case .title: return attribute(element, kAXTitleAttribute) as String?
        case .main: return attribute(element, kAXMainAttribute) as Bool?
        case .minimized: return attribute(element, kAXMinimizedAttribute) as Bool?
        case .position, .size:
            let name = kind == .position ? kAXPositionAttribute : kAXSizeAttribute
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let axValue = value as! AXValue
            if kind == .position {
                var point = CGPoint.zero
                guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
                return point
            }
            var size = CGSize.zero
            guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
            return size
        }
    }

    private func eligibleElements(_ elements: [AXUIElement], processID: pid_t, focused: AXUIElement?,
                                  current: () -> Bool, budget: EligibilityReadBudget,
                                  visible: () -> [VisibleWindowEvidence],
                                  offscreen: (AXUIElement) -> Bool = { _ in false }) -> (elements: [AXUIElement], incomplete: Bool) {
        let focusedIndex = focused.flatMap { focus in elements.firstIndex { CFEqual(focus, $0) } }
        let result = Self.collectEligibility(count: elements.count, processID: processID, focusedIndex: focusedIndex,
            current: current, now: { ProcessInfo.processInfo.systemUptime }, budget: budget,
            read: { self.eligibilityAttribute(elements[$0], $1) }, visible: visible, offscreen: { offscreen(elements[$0]) })
        return (elements.indices.filter { result.indices.contains($0) }.map { elements[$0] }, result.incomplete)
    }

    private func isEligible(_ element: AXUIElement, processID: pid_t, current: () -> Bool, budget: EligibilityReadBudget,
                            windowID: CGWindowID?) -> Bool {
        func query<T>(_ target: AXUIElement, _ name: String) -> T? {
            guard current(), budget.available else { return nil }
            let start = ProcessInfo.processInfo.systemUptime
            let value: T? = attribute(target, name)
            budget.record(duration: ProcessInfo.processInfo.systemUptime - start)
            return current() ? value : nil
        }
        guard let role: String = query(element, kAXRoleAttribute), role == kAXWindowRole else { return false }
        if let windowID, OtherSpaceWindows.id(of: element) != windowID { return false }
        let subrole: String? = query(element, kAXSubroleAttribute)
        if WindowEligibility.isEligible(role: role, subrole: subrole) { return current() }
        guard current(), budget.available else { return false }
        if let windowID,
           Self.windowInventory(livePIDs: [processID]).offscreenByProcess[processID]?.contains(windowID) == true {
            return current()
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.12)
        guard let elements: [AXUIElement] = query(application, kAXWindowsAttribute) else { return false }
        let focused: AXUIElement? = query(application, kAXFocusedWindowAttribute)
        guard current(), budget.available else { return false }
        let unique = Self.deduplicatedElements(elements)
        for window in unique.prefix(512) { AXUIElementSetMessagingTimeout(window, 0.12) }
        return eligibleElements(unique, processID: processID, focused: focused, current: current, budget: budget,
                                visible: Self.visibleWindowEvidence).elements.contains { CFEqual($0, element) }
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
    private func matchesGeneration(_ generation: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return accepting && stateGeneration == generation
    }
    private var isAccepting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return accepting
    }
    private func recordFocus(_ pid: pid_t, generation: UInt64, revision: UInt64) {
        guard matchesGeneration(generation), let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let focused: AXUIElement? = attribute(app, kAXFocusedWindowAttribute)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        stateLock.lock()
        guard accepting, !running.isTerminated, generation == stateGeneration, processFocusRevision[pid, default: 0] == revision else { stateLock.unlock(); return }
        focusedElements[pid] = focused
        let id = published?.first { window in window.item.processID == pid && focused.map { focus in window.element.map { CFEqual($0, focus) } ?? false } == true }?.item.id
        focusedByProcess[pid] = id
        if foreground, let id { promotePublished(id) }
        stateLock.unlock()
        if foreground, let id { queue.async { if self.matchesGeneration(generation) { self.remember(id) } } }
    }
    /// Caller holds stateLock.
    private func promotePublished(_ id: UUID) {
        guard let index = published?.firstIndex(where: { $0.item.id == id }), let window = published?.remove(at: index) else { return }
        published?.insert(window, at: 0)
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
        if notification as String == kAXUIElementDestroyedNotification {
            service.stateLock.lock()
            service.published?.removeAll { $0.element.map { CFEqual($0, element) } == true }
            service.destroyedElements.append(element)
            if service.destroyedElements.count > 256 { service.destroyedElements.removeFirst() }
            service.stateLock.unlock()
        }
        if notification as String == kAXFocusedWindowChangedNotification { service.noteFocus(processID: pid); return }
        DispatchQueue.main.async { service.refreshAfterEvent() }
    }
}
