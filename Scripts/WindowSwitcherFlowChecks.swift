// OS boundaries only: the monitor, chooser selection, and
// activation coordinator below are the same types used by the shipping app.
import AppKit
import CoreGraphics
import HandyToolbeltCore

private final class NoCapture: WindowPreviewCapturing {
    func hasPermission() -> Bool { false }
    func requestPermission() { fatalError("Unexpected permission request") }
    func loadWindows(completion: @escaping (Result<[WindowPreviewCandidate], Error>) -> Void) { fatalError("Unexpected capture") }
    func capture(id: UInt32, size: CGSize, completion: @escaping (Result<CGImage, Error>) -> Void) { fatalError("Unexpected capture") }
}
private final class DelayedCapture: WindowPreviewCapturing {
    var loads: [(Result<[WindowPreviewCandidate], Error>) -> Void] = []
    var captures: [(Result<CGImage, Error>) -> Void] = []
    func hasPermission() -> Bool { true }
    func requestPermission() { fatalError("Unexpected permission request") }
    func loadWindows(completion: @escaping (Result<[WindowPreviewCandidate], Error>) -> Void) { loads.append(completion) }
    func capture(id: UInt32, size: CGSize, completion: @escaping (Result<CGImage, Error>) -> Void) { captures.append(completion) }
}
private final class Catalogue: WindowSwitchCatalog {
    var onWindowsChanged: (() -> Void)?
    var activationDiagnostics: [String] = []
    var warm = false
    func cachedSnapshot() -> WindowCatalog.Snapshot? { warm ? .init(windows: windows, focusedID: focused, unavailableApps: 0) : nil }
    var pending: [(WindowCatalog.Snapshot) -> Void] = []
    var metadata: [([WindowItem]) -> Void] = []
    var metadataFlags: [Bool] = []
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
    func refresh(includePreviewMetadata: Bool, completion: @escaping (WindowCatalog.Snapshot) -> Void) { metadataFlags.append(includePreviewMetadata); pending.append(completion) }
    func cancelPreviewMetadata() {}
    func previewMetadata(for ids: [UUID], completion: @escaping ([WindowItem]) -> Void) { metadata.append(completion) }
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
    static func event(_ monitor: WindowKeyboardMonitor, key: CGKeyCode, down: Bool = true, flags: CGEventFlags = [], modifier: Bool = false, marker: Int64 = 0) -> Bool {
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
            previews: WindowPreviewService(capture: capture, defaults: UserDefaults(suiteName: "WindowSwitcherChecks.\(UUID().uuidString)")!), previewSetup: WindowPreviewSetupModel(capture: capture, observeSystem: false))
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
        func tab(flags: CGEventFlags = .maskAlternate) {
            _ = event(monitor, key: 48, flags: flags)
            _ = event(monitor, key: 48, down: false, flags: flags)
        }
        func releaseOption() {
            _ = event(monitor, key: 58, down: false, modifier: true)
        }

        tab()
        check(model.isShowing && model.isLoading && suspended && chooserVisible && !snapping.monitorAvailable && !snapListener.listening, "Option-Tab opens the chooser and suspends snapping")
        releaseOption()
        check(model.isLoading && catalog.requested.isEmpty, "Early Option release waits for async catalogue")
        catalog.deliver(); check(!model.isShowing && !suspended && !chooserVisible && snapping.monitorAvailable && snapListener.listening, "Loaded release confirms and resumes snapping")
        check(catalog.requested == [second.id], "Chooser activates selected same-app second window")
        catalog.drain(); check(catalog.focused == second.id && catalog.effects.contains("raise"), "Production coordinator raises and verifies selected window")
        check(catalog.completions == 1, "Repeated release confirms exactly once")
        check(!event(monitor, key: 48, down: false), "Tab key-up clears consumed key ownership")
        check(!event(monitor, key: 48, flags: .maskAlternate, marker: ActionExecutor.eventMarker), "Ordinary action marker cannot reopen chooser")

        // While held, repeated Tab and Shift-Tab use the monitor's live path.
        catalog.focused = first.id
        tab()
        tab()
        catalog.deliver(); check(model.selectedID == third.id, "Tab while loading accumulates navigation")
        tab(flags: [.maskAlternate, .maskShift])
        check(model.selectedID == second.id, "Held Shift-Tab navigates backward through production monitor")
        releaseOption(); catalog.drain()
        check(catalog.requested.last == second.id && !suspended, "Release confirms navigated window and resumes snapping")

        // Old enumeration cannot overwrite a cancelled/reopened chooser.
        check(model.show(), "Open first request"); model.cancel(); check(model.show(reverse: true), "Reopen after cancel")
        catalog.deliver(); check(model.isLoading, "Stale enumeration ignored")
        catalog.deliver(); check(!model.isLoading, "Current enumeration accepted")
        model.cancel()

        // Closed targets fail through the production activation coordinator.
        let beforeFailureCompletions = catalog.completions
        _ = model.show(); catalog.deliver(); model.confirm(); catalog.available = false; catalog.drain()
        check(!model.isShowing && !suspended && catalog.completions == beforeFailureCompletions + 1,
              "Disappearing target completes once and quietly closes chooser")
        check(model.show(), "Disappearing target failure releases switching gate")
        catalog.deliver(); model.cancel()
        catalog.available = true

        // A focus change aborts activation without blocking another invocation.
        _ = model.show(); catalog.deliver(); model.confirm()
        catalog.frontmost = 99; catalog.drain()
        check(!model.isShowing && !suspended, "Focus-change failure leaves chooser dismissed")
        catalog.frontmost = 10
        check(model.show(), "Focus-change failure permits immediate retry")
        catalog.deliver(); model.cancel()

        // Cancel supersedes in-flight activation; its callback must not poison a new chooser.
        _ = model.show(); catalog.deliver(); model.confirm(); let effectsBefore = catalog.effects.count
        model.cancel(); check(model.show(), "Cancel clears in-flight switching gate")
        catalog.drain(); check(model.isShowing, "Stale activation callback leaves reopened chooser intact")
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

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Switcher-flow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hidMonitor = GestureKeyboardMonitor()
        let trackpad = AppModel(storage: ConfigurationStore(url: temporary.appendingPathComponent("settings.json")),
            nativeInputEnabled: false, observeSession: false, sessionIsActive: { true }, accessibilityTrusted: { true },
            keyboardMonitor: hidMonitor,
            focusedApplication: { ("test.editor", 10, "Editor") })
        // Exercise both keyboard stages with Gestures disabled and no native taps.
        struct Export: Decodable { let context: [String: String]; let events: [DebugEvent] }
        let recorder = DebugEventRecorder.shared
        func export() throws -> Export { try JSONDecoder().decode(Export.self, from: recorder.snapshot()) }
        func commandTab() -> Bool {
            hidMonitor.routeKeyboardEvent(type: .keyDown, key: 48, flags: .maskCommand, marker: 0)
            let consumed = event(monitor, key: 48, flags: .maskCommand)
            _ = event(monitor, key: 48, down: false, flags: .maskCommand)
            return consumed
        }
        var diagnosticSettings = settings
        diagnosticSettings.shortcut = .commandTab
        trackpad.configuration.trackpadModuleEnabled = false
        trackpad.configuration.windowSwitcher = diagnosticSettings
        trackpad.switcherDebugContext = { [weak model] in model?.debugContext ?? [:] }
        model.configure(diagnosticSettings)
        recorder.setEnabled(false)
        check(commandTab(), "Diagnostics disabled preserves Command-Tab consumption")
        let disabled = try export()
        check(disabled.events.isEmpty, "Diagnostics disabled does not record the shortcut")
        model.cancel(); catalog.deliver()
        recorder.setEnabled(true)
        hidMonitor.routeKeyboardEvent(type: .keyDown, key: 0, flags: .maskCommand, marker: 0)
        hidMonitor.routeKeyboardEvent(type: .keyDown, key: 48, flags: .maskAlternate, marker: 0)
        hidMonitor.routeKeyboardEvent(type: .keyDown, key: 48, flags: .maskCommand, marker: ActionExecutor.eventMarker)
        check(!event(monitor, key: 48, flags: .maskCommand, marker: ActionExecutor.eventMarker),
              "Marked Command-Tab bypasses session routing and diagnostics")
        check(commandTab() && model.isShowing, "Configured shortcut is consumed while recording diagnostics")
        catalog.deliver(); model.confirm()
        check(!commandTab() && !model.isShowing, "Pending activation passes the matched shortcut through")
        let pending = try export()
        check(pending.context["switcher_shortcut"] == "commandTab" && pending.context["switcher_activation_pending"] == "true" &&
              pending.context["switcher_keyboard_available"] == "true" && pending.context["switcher_session_tap_enabled"] == "false",
              "Export shows the semantic setting, model readiness and actual tap status")
        catalog.drain()
        model.setRecordingShortcut(true)
        check(!commandTab(), "Recording a shortcut passes it through")
        model.setRecordingShortcut(false)
        let captured = try export().events.filter { $0.category == .switcher }
        check(captured.filter { $0.event == "hid_shortcut" }.map(\.fields) == [[:], [:], [:]],
              "HID diagnostics identify only the configured unmarked chord without key metadata")
        check(captured.filter { $0.event == "session_shortcut" }.map(\.fields) == [
            ["operation": "begin", "outcome": "consumed", "reason": "accepted"],
            ["operation": "begin", "outcome": "passed", "reason": "declined"],
            ["outcome": "passed", "reason": "shortcut_recording"]
        ], "Session diagnostics distinguish consumed, declined and suspended shortcuts")
        check(captured.contains { $0.event == "shortcut_declined" && $0.fields == ["reason": "activation_pending"] } &&
              captured.contains { $0.event == "chooser_opened" } &&
              captured.contains { $0.event == "activation_finished" && $0.fields == ["outcome": "succeeded"] },
              "Chooser and activation diagnostics explain why the second shortcut passed through")
        recorder.setEnabled(false)
        let cleared = try export()
        check(cleared.events.isEmpty, "Disabling diagnostics clears previously recorded events")
        model.configure(settings)
        catalog.frontmost = 10
        // Real dispatch classifies all switcher failures without losing the error result.
        let actionExecutor = ActionExecutor(accessibilityTrusted: { true })
        let windowAction = GestureAction(kind: .system, system: .nextWindow)
        var dispatchFailure: Error?
        actionExecutor.execute(windowAction) { if case let .failure(error) = $0 { dispatchFailure = error } }
        check(dispatchFailure is WindowSwitcherFailure, "Missing Windows module remains a classified failure")
        let deniedExecutor = ActionExecutor(accessibilityTrusted: { false })
        deniedExecutor.execute(windowAction) { if case let .failure(error) = $0 { dispatchFailure = error } }
        check(dispatchFailure is WindowSwitcherFailure && dispatchFailure?.localizedDescription.contains("Accessibility") == true,
              "Denied window action remains a classified permission failure")
        actionExecutor.onWindowAction = { _, completion in
            completion(.failure(ActionExecutor.ActionError.message("Focus changed")))
        }
        actionExecutor.execute(windowAction) { if case let .failure(error) = $0 { dispatchFailure = error } }
        check(dispatchFailure is WindowSwitcherFailure && dispatchFailure?.localizedDescription == "Focus changed",
              "Window activation failure preserves its error for automation callers")
        trackpad.handleActionFailure(dispatchFailure!)
        check(trackpad.errorMessage == nil, "Ordinary gesture dispatch suppresses window failure modal")
        trackpad.handleActionFailure(ActionExecutor.ActionError.message("Unrelated failure"))
        check(trackpad.errorMessage == "Unrelated failure", "Unrelated action errors retain existing presentation")
        let beforeStopRequests = catalog.requested.count, beforeStopEffects = catalog.effects.count
        tab(); releaseOption()
        trackpad.stop(); model.stop() // Same module stop order as ProductivityModel.stop.
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
        // Preview geometry and native capture are independently delayed OS boundaries.
        let previewCatalog = Catalogue(), delayed = DelayedCapture()
        let previewService = WindowPreviewService(capture: delayed, defaults: UserDefaults(suiteName: "WindowSwitcherChecks.\(UUID().uuidString)")!)
        let previewModel = WindowSwitcherModel(catalog: previewCatalog,
            environment: .init(accessibility: { true }, sessionActive: { true }, frontmostPID: { previewCatalog.frontmost }, startKeyboard: { _ in true }, nativeServices: false),
            previews: previewService, previewSetup: WindowPreviewSetupModel(capture: delayed, observeSystem: false))
        previewCatalog.windows = [first, second]; previewCatalog.focused = first.id
        var previewSettings = WindowSwitcherSettings(); previewSettings.isEnabled = true; previewSettings.showsPreviews = true
        previewModel.configure(previewSettings); previewCatalog.deliver()
        previewCatalog.focused = first.id
        _ = previewModel.show(); previewCatalog.deliver()
        previewModel.updateVisiblePreviews([second.id])
        check(delayed.loads.isEmpty && previewCatalog.metadata.isEmpty && !previewService.hasAcknowledgedNotice,
              "Existing preview preference keeps chooser usable without capture before setup")
        previewModel.cancel()
        previewService.noteSuccessfulAccessCheck()
        _ = previewModel.show(); previewCatalog.deliver()
        previewModel.updateVisiblePreviews([second.id])
        check(!previewModel.isLoading && previewModel.selectedID == second.id && !previewCatalog.metadata.isEmpty,
              "Rows and selection are ready before delayed preview geometry")
        check(previewCatalog.metadataFlags.allSatisfy { !$0 }, "Preview-enabled chooser requests fast base catalogues")
        previewModel.confirm(); previewCatalog.drain()
        check(previewCatalog.requested == [second.id] && !previewModel.isShowing, "Commit does not wait for metadata or images")
        let oldMetadata = previewCatalog.metadata.removeFirst()
        previewCatalog.focused = first.id
        _ = previewModel.show(); previewCatalog.deliver()
        let currentSelection = previewModel.selectedID
        oldMetadata([first, second])
        check(previewModel.isShowing && previewModel.selectedID == currentSelection && previewService.images.isEmpty,
              "Late metadata cannot alter reopened chooser or selection")
        previewModel.updateVisiblePreviews([second.id])
        previewModel.cancel()
        previewCatalog.metadata.removeFirst()([first, second])
        check(!previewModel.isShowing && previewService.images.isEmpty, "Late geometry cannot resurrect dismissed chooser")
        // Content requests are real in-flight work; releasing one after dismissal must not restart capture.
        delayed.loads.removeFirst()(.success([]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(delayed.captures.isEmpty && previewService.images.isEmpty, "Late native content cannot create images after dismiss")
        previewCatalog.focused = first.id
        _ = previewModel.show(); previewCatalog.deliver()
        previewModel.updateVisiblePreviews([second.id])
        let frame = CGRect(x: 10, y: 20, width: 600, height: 400)
        var enrichedSecond = second; enrichedSecond.frame = frame
        previewCatalog.metadata.removeFirst()([enrichedSecond])
        delayed.loads.removeFirst()(.success([.init(id: 42, processID: second.processID, title: second.title, frame: frame)]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(delayed.captures.count == 1 && previewModel.selectedID == second.id, "Delayed geometry starts capture without changing keyboard selection")
        let metadataCount = previewCatalog.metadata.count, loadCount = delayed.loads.count
        previewCatalog.windows = [second, first]
        previewCatalog.onWindowsChanged?(); previewCatalog.deliver()
        check(delayed.captures.count == 1 && delayed.loads.count == loadCount && previewCatalog.metadata.count == metadataCount,
              "Order-only refresh preserves delayed native capture and metadata generation")
        let retainedImage = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        delayed.captures.removeFirst()(.success(retainedImage))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(previewService.images[second.id] != nil && previewModel.selectedID == second.id, "Order-only refresh accepts pending image without selection jump")
        previewCatalog.windows = [first, enrichedSecond]
        previewCatalog.onWindowsChanged?(); previewCatalog.deliver()
        check(previewService.images.isEmpty, "Real window metadata change invalidates old preview generation")
        previewModel.updateVisiblePreviews([second.id])
        if !delayed.loads.isEmpty {
            delayed.loads.removeFirst()(.success([.init(id: 42, processID: second.processID, title: second.title, frame: frame)]))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        previewModel.confirm(); previewCatalog.drain()
        previewCatalog.focused = first.id
        _ = previewModel.show(); previewCatalog.deliver()
        let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        delayed.captures.removeFirst()(.success(image))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(previewModel.isShowing && previewModel.selectedID == second.id && previewService.images.isEmpty,
              "Late captured image from confirmed chooser cannot enter reopened chooser")
        previewModel.stop()
        let staleCapture = DelayedCapture()
        // Keep each delayed backend attached to the service exercised below.
        let metadataService = WindowPreviewService(capture: staleCapture, defaults: UserDefaults(suiteName: "WindowSwitcherChecks.\(UUID().uuidString)")!)
        metadataService.noteSuccessfulAccessCheck()
        var renamed = second; renamed.captureTitle = "Renamed"; renamed.title = "Renamed"
        metadataService.begin(items: [renamed]); metadataService.setVisible([renamed.id])
        metadataService.updateMetadata([enrichedSecond])
        staleCapture.loads.removeFirst()(.success([.init(id: 42, processID: second.processID, title: second.captureTitle, frame: frame)]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(staleCapture.captures.isEmpty, "Delayed metadata with stale title cannot overwrite live title or start capture")
        metadataService.end()
        var hidden = second; hidden.isHidden = true
        metadataService.begin(items: [hidden]); metadataService.setVisible([hidden.id])
        metadataService.updateMetadata([enrichedSecond])
        check(staleCapture.loads.isEmpty && staleCapture.captures.isEmpty,
              "Delayed metadata cannot unhide a live hidden window or start native preview work")
        metadataService.end()
        let knownHandles = [(pid: pid_t(10), handle: "known"), (pid: pid_t(20), handle: "terminated"), (pid: pid_t(10), handle: "destroyed")]
        let retained = WindowCatalog.retainedDuringEnumerationFailure(knownHandles, unavailablePIDs: [10, 20, 30], livePIDs: [10, 30],
            processID: { $0.pid }, destroyed: { $0.handle == "destroyed" })
        check(retained.map(\.handle) == ["known"], "Production failure policy retains known live handles, drops destroyed and terminated handles, and invents no cold handles")
        check(WindowCatalog.retainedDuringEnumerationFailure(knownHandles, unavailablePIDs: [], livePIDs: [10], processID: { $0.pid }, destroyed: { _ in false }).isEmpty,
              "Successful empty enumeration clears previously retained handles")
        let metadataRow: [String: Any] = [kCGWindowOwnerPID as String: 20,
            kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: frame.dictionaryRepresentation]
        check(WindowCatalog.visibleWindowEvidence(rows: [metadataRow]).count == 1,
              "Production metadata adapter accepts an opaque layer-zero window")
        for layer in [3, 8] {
            var floating = metadataRow; floating[kCGWindowLayer as String] = layer
            check(WindowCatalog.visibleWindowEvidence(rows: [floating]).count == 1,
                  "Visible floating and modal layers remain eligible evidence")
        }
        for (key, value) in [(kCGWindowLayer as String, -1 as Any), (kCGWindowAlpha as String, 0.0 as Any),
                             (kCGWindowBounds as String, CGRect.zero.dictionaryRepresentation as Any)] {
            var invalid = metadataRow; invalid[key] = value
            check(WindowCatalog.visibleWindowEvidence(rows: [invalid]).isEmpty,
                  "Production metadata adapter excludes negative layers transparent and invalid windows")
        }
        func serverWindow(_ id: UInt32, pid: pid_t = 20, onScreen: Bool = false, layer: Int = 0) -> [String: Any] {
            var row = metadataRow
            row[kCGWindowNumber as String] = id
            row[kCGWindowOwnerPID as String] = pid
            row[kCGWindowIsOnscreen as String] = onScreen
            row[kCGWindowLayer as String] = layer
            return row
        }
        let inventory = OtherSpaceWindows.Inventory(rows: [
            serverWindow(101), serverWindow(102), serverWindow(103, onScreen: true), serverWindow(103),
            serverWindow(104, pid: 21), serverWindow(105, layer: 8)
        ], livePIDs: [20], assignedWindows: [101, 103, 104, 105])
        check(inventory.offscreenByProcess[20] == [101] && inventory.offscreenByProcess[21] == nil,
              "Only assigned off-screen windows for live apps are recoverable, excluding inactive tabs and auxiliary layers")
        var search = OtherSpaceWindows.Search()
        var inspected: [UInt64] = []
        func readCandidate(_ id: UInt64) -> (UInt32, String)? {
            inspected.append(id)
            switch id {
            case 1: return (101, "descendant")
            case 3: return (102, "unassigned")
            case 5: return (101, "window")
            default: return nil
            }
        }
        let firstSlice = search.find(missing: [101], limit: 10, mayRead: { inspected.count < 3 },
                                     candidate: readCandidate, isWindow: { $0 == "window" })
        check(firstSlice.isEmpty && search.nextID == 3, "Recovery stops at the deadline and rejects descendants with matching native IDs")
        let nextSlice = search.find(missing: [101], limit: 10, mayRead: { true },
                                    candidate: readCandidate, isWindow: { $0 == "window" })
        check(nextSlice == [101: "window"] && inspected == [0, 1, 2, 3, 4, 5],
              "Recovery resumes its bounded sweep, skips unrelated windows and stops at the exact AX root")
        // Exercise the exact production native-read boundary without remote UI reads or real delays.
        var readEvents: [(Int, WindowCatalog.EligibilityAttribute)] = []
        var fakeTime: TimeInterval = 0
        var collectionCurrent = true
        var cancelAfter: Int?
        var readDuration: TimeInterval = 0
        var minimizedStandard = false
        var standardIndices: Set<Int> = [0, 1]
        var visibleReads = 0
        func collect(count: Int, focused: Int? = nil, budget: WindowCatalog.EligibilityReadBudget = .init(), appQueries: Int = 512,
                     appDuration: TimeInterval = 0.3, offscreen: Set<Int> = []) -> WindowCatalog.EligibilityCollection {
            WindowCatalog.collectEligibility(count: count, processID: 20, focusedIndex: focused,
                current: { collectionCurrent }, now: { fakeTime }, budget: budget,
                maximumAppQueries: appQueries, maximumAppDuration: appDuration,
                read: { index, kind in
                    readEvents.append((index, kind)); fakeTime += readDuration
                    if readEvents.count == cancelAfter { collectionCurrent = false }
                    switch kind {
                    case .role: return "AXWindow"
                    case .subrole: return standardIndices.contains(index) ? "AXStandardWindow" : "CustomWindow"
                    case .position: return frame.origin
                    case .size: return frame.size
                    case .title: return nil
                    case .main: return false
                    case .minimized: return minimizedStandard
                    }
                }, visible: { visibleReads += 1; return [.init(processID: 20, frame: frame)] },
                offscreen: offscreen.contains)
        }
        let standardOnly = collect(count: 2)
        check(standardOnly.indices == [0, 1] && !standardOnly.incomplete && readEvents.count == 4 && visibleReads == 0,
              "Standard-only classification performs only role/subrole reads and no visible enrichment")
        readEvents = []; cancelAfter = 2
        let cancelledCollection = collect(count: 2)
        check(cancelledCollection.indices == [0] && cancelledCollection.incomplete && readEvents.count == 2,
              "Cancellation stops between native reads and preserves an already classified standard")
        collectionCurrent = true; cancelAfter = nil; readEvents = []
        let queryLimited = collect(count: 2, appQueries: 2)
        check(queryLimited.indices == [0] && queryLimited.incomplete && readEvents.count == 2,
              "Per-app query cap prevents further native classification reads")
        readEvents = []; readDuration = 0.16
        let slowCollection = collect(count: 2)
        check(slowCollection.indices == [0] && slowCollection.incomplete && readEvents.count == 2,
              "Injected monotonic clock bounds slow classification without real delays")
        readEvents = []; readDuration = 0.2
        let sharedBudget = WindowCatalog.EligibilityReadBudget(maximumQueries: 100, maximumDuration: 0.5)
        let firstApp = collect(count: 1, budget: sharedBudget, appDuration: 10)
        let secondApp = collect(count: 1, budget: sharedBudget, appDuration: 10)
        check(firstApp.indices == [0] && !firstApp.incomplete && secondApp.incomplete && readEvents.count == 3,
              "Cumulative budget spans applications and stops after at most one in-flight read overshoot")
        readEvents = []; readDuration = 0; standardIndices = [0]
        let exactOtherSpace = collect(count: 2, offscreen: [0])
        check(exactOtherSpace.indices == [0, 1],
              "An exact off-Space match does not claim the visible evidence of another window with the same geometry")
        readEvents = []; visibleReads = 0
        let partialEnrichment = collect(count: 2, appQueries: 6)
        check(partialEnrichment.indices == [0] && partialEnrichment.incomplete && readEvents.count == 6 && visibleReads == 0,
              "Abandoned enrichment keeps standards and rejects fallback rather than using partial reservations")
        readEvents = []; minimizedStandard = true
        let minimizedCollection = collect(count: 2)
        check(minimizedCollection.indices == [0, 1] && !minimizedCollection.incomplete,
              "Production boundary keeps minimized standard plus the distinct real visible custom window")
        check(!readEvents.contains { $0.0 == 0 && ($0.1 == .position || $0.1 == .size || $0.1 == .title) },
              "Definitely minimized standards need no visible geometry/title queries")
        readEvents = []; standardIndices = []; minimizedStandard = false
        let focusedDiscovery = collect(count: 2, focused: 1)
        let focusedRevalidation = collect(count: 2, focused: 1)
        check(focusedDiscovery.indices == [1] && focusedRevalidation.indices == [1],
              "Focused-only oversubscription disambiguation is identical for discovery and activation")
        var cappedReads = 0
        let capped = WindowCatalog.collectEligibility(count: 10_000, processID: 20, focusedIndex: nil,
            current: { true }, now: { 0 }, budget: .init(maximumQueries: 10_000), maximumAppQueries: 10_000,
            read: { _, _ in cappedReads += 1; return "AXButton" }, visible: { fatalError("Unexpected oversized enrichment") })
        check(capped.incomplete && cappedReads == 512, "Candidate cap applies before any unbounded native collection")
        var nonwindowReads = 0
        let nonwindow = WindowCatalog.collectEligibility(count: 1, processID: 20, focusedIndex: nil,
            current: { true }, now: { 0 }, budget: .init(), read: { _, kind in
                nonwindowReads += 1; check(kind == .role, "Nonwindow nodes never request subrole or enrichment"); return "AXMenu"
            }, visible: { fatalError("Unexpected nonwindow enrichment") })
        check(nonwindow.indices.isEmpty && nonwindowReads == 1, "Nonwindow role exits after one native read")
        var finalAppOrder = WindowCatalog.EligibilityScanOrder(count: 3, startOffset: 0)
        check(finalAppOrder.indices == [0, 1, 2], "Initial bounded scan follows the normal app order")
        finalAppOrder.exhausted(at: 2) // The final app partially classifies before its shared budget expires.
        let resumedOrder = WindowCatalog.EligibilityScanOrder(count: 3, startOffset: finalAppOrder.nextStartOffset)
        check(resumedOrder.indices == [2, 0, 1], "Final-app budget exhaustion gives that incomplete app first turn next scan")
        let rotatedRows = resumedOrder.indices.map { (pid: pid_t($0 + 10), handle: "classified-\($0)") }
        let catalogueRows = WindowCatalog.catalogueOrder(rotatedRows, appOrder: [10: 0, 11: 1, 12: 2], processID: { $0.pid })
        check(catalogueRows.map(\.handle) == ["classified-0", "classified-1", "classified-2"],
              "Fairness rotation preserves all classified standards and stable alphabetical output order")
        // Production discovery and activation use the same public-metadata association policy.
        let standardCandidate = WindowEligibilityCandidate(role: "AXWindow", subrole: "AXStandardWindow", frame: frame)
        let visibleCandidate = WindowEligibilityCandidate(role: "AXWindow", subrole: "CustomWindow", frame: frame)
        let visibleEvidence = [VisibleWindowEvidence(processID: 20, frame: frame)]
        check(WindowEligibility.eligibleIndices([visibleCandidate], processID: 20, visible: visibleEvidence) == [0],
              "Visible custom window qualifies without main or writable AX evidence")
        check(WindowEligibility.eligibleIndices([visibleCandidate], processID: 20, visible: []).isEmpty,
              "Activation revalidation rejects a nonstandard window after visible evidence disappears")
        check(WindowEligibility.eligibleIndices([visibleCandidate, standardCandidate], processID: 20, visible: visibleEvidence) == [1],
              "Standard window reserves visible evidence before phantom nodes can borrow it")
        check(WindowEligibility.eligibleIndices([visibleCandidate, visibleCandidate], processID: 20, visible: visibleEvidence).isEmpty,
              "Ambiguous duplicate AX nodes cannot produce duplicate switcher entries")
        check(WindowEligibility.eligibleIndices([visibleCandidate, visibleCandidate], processID: 20, visible: visibleEvidence + visibleEvidence) == [0, 1],
              "Two real overlapping visible windows retain two switcher entries")
        check(WindowEligibility.eligibleIndices([standardCandidate, visibleCandidate], processID: 20, visible: visibleEvidence + visibleEvidence) == [0, 1],
              "One standard reservation leaves a second visible window available to a custom AX window")
        check(WindowEligibility.eligibleIndices([standardCandidate], processID: 20, visible: []) == [0],
              "Ordinary minimized hidden and other-Space windows retain eligibility")
        // Exercise the real catalogue queues without AX reads or user-visible effects.
        let heldScan = DispatchQueue(label: "checks.held-scan"), releaseScan = DispatchSemaphore(value: 0)
        heldScan.async { releaseScan.wait() }
        let nativeCatalog = WindowCatalog(scanQueue: heldScan)
        nativeCatalog.start()
        nativeCatalog.refresh { _ in }
        var independentActivation = false
        nativeCatalog.activate(UUID(), expectedProcessID: nil) { result in
            if case .failure = result { independentActivation = true }
        }
        let deadline = Date().addingTimeInterval(1)
        while !independentActivation && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check(independentActivation, "Real catalogue activation lookup runs while scan queue is blocked")
        nativeCatalog.stop(); releaseScan.signal()
        catalog.pending = []; catalog.frontmost = 10; catalog.focused = first.id
        catalog.windows = [first, second, third]; catalog.warm = true
        let warmModel = WindowSwitcherModel(catalog: catalog,
            environment: .init(accessibility: { true }, sessionActive: { true }, frontmostPID: { catalog.frontmost }, startKeyboard: { _ in true }, nativeServices: false),
            previews: WindowPreviewService(capture: capture, defaults: UserDefaults(suiteName: "WindowSwitcherChecks.\(UUID().uuidString)")!), previewSetup: WindowPreviewSetupModel(capture: capture, observeSystem: false))
        warmModel.configure(settings); catalog.deliver()
        _ = warmModel.show(releaseToConfirm: true)
        check(!warmModel.isLoading && warmModel.selectedID == second.id && catalog.pending.count == 1,
              "Warm chooser selects immediately while background scan remains pending")
        warmModel.confirm(); catalog.drain()
        check(catalog.requested.last == second.id && !warmModel.isShowing,
              "Warm quick release activates before delayed scan completion")
        catalog.deliver() // stale background result cannot reopen chooser
        check(!warmModel.isShowing, "Delayed refresh cannot resurrect a confirmed warm chooser")
        catalog.focused = first.id; catalog.frontmost = 10
        _ = warmModel.show(); warmModel.step(1)
        check(warmModel.selectedID == third.id, "Warm navigation advances before refresh")
        let fourth = WindowItem(processID: 20, appName: "Other", bundleIdentifier: "test.other", title: "Fourth")
        catalog.windows = [fourth, third, first]; catalog.deliver()
        check(warmModel.items.map(\.id) == [first.id, third.id, fourth.id] && warmModel.selectedID == third.id,
              "Late scan removes closed windows and appends discoveries without moving selection")
        warmModel.cancel(); catalog.focused = third.id
        _ = warmModel.show()
        check(warmModel.selectedID == first.id, "Warm reopening uses changed current focus")
        warmModel.suspendSession(sleeping: true)
        catalog.deliver()
        check(!warmModel.isShowing && !warmModel.isLoading, "Lifecycle cancellation rejects delayed warm results")
        warmModel.stop()
        print("Passed \(count) window switcher flow checks")
    }
}
