// OS boundaries only: the monitor, chooser selection, stack keyboard driver and
// activation coordinator below are the same types used by the shipping app.
import AppKit
import SuperTrackpadCore

private final class NoCapture: WindowPreviewCapturing {
    func hasPermission() -> Bool { false }
    func requestPermission() { fatalError("Unexpected permission request") }
    func loadWindows(completion: @escaping (Result<[WindowPreviewCandidate], Error>) -> Void) { fatalError("Unexpected capture") }
    func capture(id: UInt32, size: CGSize, completion: @escaping (Result<CGImage, Error>) -> Void) { fatalError("Unexpected capture") }
}
private final class Catalogue: WindowSwitchCatalog {
    var onWindowsChanged: (() -> Void)?
    var activationDiagnostics: [String] = []
    var pending: [(WindowCatalog.Snapshot) -> Void] = []
    var scheduled: [() -> Void] = []
    var generation = 0
    var frontmost: Int32? = 10
    var available = true
    var focused: UUID?
    var windows: [WindowItem] = []
    var requested: [UUID] = []
    var effects: [String] = []
    var completions = 0
    func start() {}
    func stop() { cancelPendingActivations() }
    func noteFocus(processID: pid_t) {}
    func cancelPendingActivations() { generation += 1 }
    func refresh(includePreviewMetadata: Bool, completion: @escaping (WindowCatalog.Snapshot) -> Void) { pending.append(completion) }
    func deliver(_ index: Int = 0) { pending.remove(at: index)(.init(windows: windows, focusedID: focused, unavailableApps: 0)) }
    func drain() { var limit = 0; while !scheduled.isEmpty { limit += 1; precondition(limit < 100); scheduled.removeFirst()() } }
    func activate(_ id: UUID, expectedProcessID: pid_t?, completion: @escaping (Result<String, Error>) -> Void) {
        cancelPendingActivations(); let token = generation
        requested.append(id)
        let target = windows.first { $0.id == id }?.processID ?? 10
        WindowActivationCoordinator(origin: expectedProcessID, target: target, local: false, minimized: false, name: "Test", success: "Switched", boundary: .init(
            schedule: { _, _, work in self.scheduled.append(work) }, current: { token == self.generation },
            frontmost: { self.frontmost }, now: { 0 }, available: { self.available && self.windows.contains { $0.id == id } },
            restore: { true }, unhide: { self.effects.append("unhide") }, activateApp: { self.effects.append("activate"); self.frontmost = target; return true },
            foreground: { self.effects.append("foreground") }, makeMain: { self.effects.append("main") }, raise: { self.effects.append("raise"); self.focused = id; return true },
            activateLocal: { fatalError("Unexpected local activation") }, focused: { self.focused == id }, remember: { self.effects.append("remember") }, trace: { self.activationDiagnostics.append($0) }
        )) { result in self.completions += 1; completion(result) }.start()
    }
}
private final class SnapListener: WindowSnappingMonitoring {
    var diagnostics = WindowSnapDiagnosticsSnapshot()
    var onInteraction: (() -> Bool)?
    var onUnavailable: (() -> Void)?
    var listening = false
    func start() -> Bool { listening = true; return true }
    func stop() { listening = false }
    func cancel() {}
    func updateScreens() {}
    func applicationActivated(_ processID: pid_t) {}
}
@main struct WindowSwitcherFlowChecks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ text: String) { count += 1; if !value() { fatalError(text) } }
    static func event(_ monitor: WindowKeyboardMonitor, key: CGKeyCode, down: Bool = true, flags: CGEventFlags = [], modifier: Bool = false, marker: Int64 = StackKeyboardDriver.eventMarker) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.flags = flags; event.setIntegerValueField(.eventSourceUserData, value: marker)
        return monitor.handle(type: modifier ? .flagsChanged : (down ? .keyDown : .keyUp), event: event)
    }
    static func main() throws {
        precondition(Thread.isMainThread)
        let catalog = Catalogue(), monitor = WindowKeyboardMonitor(), capture = NoCapture()
        let first = WindowItem(processID: 10, appName: "Editor", bundleIdentifier: "test.editor", title: "First")
        let second = WindowItem(processID: 10, appName: "Editor", bundleIdentifier: "test.editor", title: "Second")
        let third = WindowItem(processID: 20, appName: "Other", bundleIdentifier: "test.other", title: "Third")
        catalog.windows = [first, second, third]; catalog.focused = first.id
        let model = WindowSwitcherModel(catalog: catalog, keyboard: monitor,
            environment: .init(accessibility: { true }, sessionActive: { true }, frontmostPID: { catalog.frontmost }, startKeyboard: { _ in true }, nativeServices: false),
            previews: WindowPreviewService(capture: capture), previewSetup: WindowPreviewSetupModel(capture: capture, observeSystem: false))
        let snapListener = SnapListener(), workspace = NotificationCenter()
        let snapping = WindowSnappingModel(monitor: snapListener, trusted: { true }, eligibility: { true }, sessionIsActive: { true },
            workspaceCenter: workspace, applicationCenter: NotificationCenter(), distributedCenter: NotificationCenter())
        snapping.configure(enabled: true, running: true)
        check(snapping.monitorAvailable && snapListener.listening, "Snapping begins eligible and monitoring")
        var suspended = false, chooserVisible = false, visibility: [Bool] = []
        model.onChooserVisibility = { visible in
            visibility.append(visible)
            WindowChooserRouting.visibility(visible, recording: false, trackpad: { chooserVisible = $0 }, snapping: { suspended = $0; snapping.setSuspended($0) })
        }
        var settings = WindowSwitcherSettings(); settings.isEnabled = true; settings.showsPreviews = false
        model.configure(settings); catalog.deliver() // initial warm enumeration
        var optionUps = 0
        let driver = StackKeyboardDriver(physicalModifiers: []) { key, down, flags, modifier in
            if modifier && key == 58 && !down { optionUps += 1 }
            _ = event(monitor, key: key, down: down, flags: flags, modifier: modifier)
        }
        let runtime = GestureStackRuntime(keyboard: driver)
        let tab = GestureAction(kind: .shortcut, shortcut: .init(keyCode: 48, modifiers: 0, keyLabel: "Tab"))
        let stack = GestureStack(name: "Switch", device: .trackpad, corner: .topLeft, startActions: [.init(kind: .holdModifiers, modifiers: [.option]), .init(action: tab)])
        runtime.begin(stack, deviceID: 1, fingerID: 1, time: 0, tuning: .init(), aspect: 1)
        check(model.isShowing && model.isLoading && suspended && chooserVisible && !snapping.monitorAvailable && !snapListener.listening, "Stack opens real chooser and suspends snapping")
        runtime.end(); driver.releaseAll()
        check(model.isLoading && catalog.requested.isEmpty, "Early Option release waits for async catalogue")
        catalog.deliver(); check(!model.isShowing && !suspended && !chooserVisible && snapping.monitorAvailable && snapListener.listening, "Loaded release confirms and resumes snapping")
        check(catalog.requested == [second.id], "Chooser activates selected same-app second window")
        catalog.drain(); check(catalog.focused == second.id && catalog.effects.contains("raise"), "Production coordinator raises and verifies selected window")
        check(catalog.completions == 1, "Repeated release confirms exactly once")
        check(!event(monitor, key: 48, down: false), "Stack key-up clears consumed key ownership")
        check(!event(monitor, key: 48, flags: .maskAlternate, marker: ActionExecutor.eventMarker), "Ordinary action marker cannot reopen chooser")

        // While held, repeated Tab and Shift-Tab use the monitor's live path.
        catalog.focused = first.id
        try driver.hold([.option]); try driver.press(.init(keyCode: 48, modifiers: 0, keyLabel: "Tab"))
        try driver.press(.init(keyCode: 48, modifiers: 0, keyLabel: "Tab"))
        catalog.deliver(); check(model.selectedID == third.id, "Tab while loading accumulates navigation")
        try driver.press(.init(keyCode: 48, modifiers: KeyboardModifier.shift.flag, keyLabel: "Tab"))
        check(model.selectedID == second.id, "Held Shift-Tab navigates backward through production monitor")
        driver.releaseAll(); catalog.drain()
        check(catalog.requested.last == second.id && !suspended, "Release confirms navigated window and resumes snapping")

        // Old enumeration cannot overwrite a cancelled/reopened chooser.
        check(model.show(), "Open first request"); model.cancel(); check(model.show(reverse: true), "Reopen after cancel")
        catalog.deliver(); check(model.isLoading, "Stale enumeration ignored")
        catalog.deliver(); check(!model.isLoading, "Current enumeration accepted")
        model.cancel()

        // Closed targets fail through the production activation coordinator.
        _ = model.show(); catalog.deliver(); model.confirm(); catalog.available = false; catalog.drain()
        check(model.errorMessage?.contains("no longer available") == true, "Disappearing target surfaces activation failure")
        catalog.available = true

        // Cancel supersedes in-flight activation; its callback must not poison a new chooser.
        _ = model.show(); catalog.deliver(); model.confirm(); let effectsBefore = catalog.effects.count
        model.cancel(); check(model.show(), "Cancel clears in-flight switching gate")
        catalog.drain(); check(model.isShowing && model.errorMessage?.contains("cancelled") != true, "Stale activation callback leaves reopened chooser intact")
        check(catalog.effects.count == effectsBefore, "Superseded coordinator performs no native effects")
        catalog.deliver(); model.cancel()

        // A stale action enumeration cannot clear the newer activation's gate.
        var cancelledAction = false
        model.perform(.nextWindow) { if case .failure = $0 { cancelledAction = true } }
        model.cancel(); _ = model.show(); catalog.deliver()
        check(cancelledAction && model.isLoading, "Cancelled action callback leaves newer chooser loading")
        catalog.deliver(); model.confirm()
        check(!model.show(), "Current activation retains its in-flight gate")
        catalog.drain()
        check(model.show(), "Activation completion releases gate")
        catalog.deliver(); model.cancel()

        // The actual AppModel configuration and stop paths release stack-owned Option.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Switcher-flow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let trackpad = AppModel(storage: ConfigurationStore(url: temporary.appendingPathComponent("settings.json")),
            nativeInputEnabled: false, observeSession: false, sessionIsActive: { true }, accessibilityTrusted: { true },
            stackKeyboard: driver, focusedApplication: { ("test.editor", 10, "Editor") })
        let beforeDisableUps = optionUps, beforeDisableRequests = catalog.requested.count
        trackpad.stackRuntime.begin(stack, deviceID: 1, fingerID: 1, time: 0, tuning: .init(), aspect: 1)
        check(model.isLoading && suspended, "AppModel-owned stack opens chooser with held Option")
        trackpad.configuration.trackpadModuleEnabled = false
        check(optionUps == beforeDisableUps + 1 && trackpad.stackRuntime.stack == nil, "Disabling Gestures releases owned Option exactly once")
        catalog.deliver(); catalog.drain()
        check(catalog.requested.count == beforeDisableRequests + 1 && !suspended, "Gestures disable release confirms chooser exactly once")
        let beforeStopUps = optionUps, beforeStopRequests = catalog.requested.count, beforeStopEffects = catalog.effects.count
        trackpad.stackRuntime.begin(stack, deviceID: 1, fingerID: 1, time: 0, tuning: .init(), aspect: 1)
        trackpad.stop(); model.stop() // Same module stop order as ProductivityModel.stop.
        trackpad.stop()
        check(optionUps == beforeStopUps + 1, "Repeated production stop releases owned Option exactly once")
        catalog.deliver(); catalog.drain()
        check(catalog.requested.count == beforeStopRequests && catalog.effects.count == beforeStopEffects && !suspended,
              "Host stop invalidates early release before pending catalogue can activate")
        model.configure(settings); catalog.deliver()

        _ = event(monitor, key: 48, flags: .maskAlternate)
        check(suspended, "Keyboard chooser suspends snapping")
        settings.isEnabled = false; model.configure(settings)
        check(!model.isShowing && !suspended && snapping.monitorAvailable && !monitor.chooserOpen && !monitor.commitOnRelease, "Disable restores visibility, suspension and monitor state")
        settings.isEnabled = true; model.configure(settings); catalog.pending.removeAll()
        _ = event(monitor, key: 48, flags: .maskAlternate)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        model.suspendSession(sleeping: true)
        check(!model.isShowing && !suspended && !model.keyboardAvailable && !snapping.monitorAvailable && !snapListener.listening, "Sleep restores suspension and stops keyboard")
        check(!event(monitor, key: 48, down: false), "Sleep clears held key ownership")
        catalog.deliver(); check(!model.isShowing, "Late sleep enumeration cannot reopen chooser")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(snapping.monitorAvailable && snapListener.listening, "Wake resumes snapping after chooser sleep cleanup")
        check(visibility.contains(true) && visibility.last == false, "Production host routing finishes resumed")
        print("Passed \(count) window switcher flow checks")
    }
}
