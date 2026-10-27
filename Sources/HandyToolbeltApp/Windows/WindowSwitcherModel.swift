import AppKit
import ApplicationServices
import Combine
import HandyToolbeltCore

final class WindowSwitcherModel: ObservableObject {
    @Published private(set) var settings = WindowSwitcherSettings()
    @Published private(set) var hasAccessibility = false
    @Published private(set) var keyboardAvailable = false
    private var recordingShortcut = false
    @Published private(set) var isRunning = false
    @Published private(set) var isLoading = false
    @Published private(set) var isShowing = false
    @Published private(set) var items: [WindowItem] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var message = ""
    @Published var errorMessage: String?
    var onChooserVisibility: ((Bool) -> Void)?
    let previews: WindowPreviewService
    let previewSetup: WindowPreviewSetupModel
    private var setupSubscription: AnyCancellable?
    private var previewSubscription: AnyCancellable?
    private(set) var gridColumns = 1
    private var previewCatalogItems: [WindowItem] = []
    private var metadataVisibleIDs = Set<UUID>()
    private var visiblePreviewIDs = Set<UUID>()
    private let catalog: WindowSwitchCatalog
    private let environment: WindowSwitcherEnvironment
    var activationDiagnostics: [String] { catalog.activationDiagnostics }
    private let keyboard: WindowKeyboardMonitor
    private var panel: WindowSwitcherPanel?
    private var selection = WindowSelection()
    private var cycle = WindowGestureCycle()
    private var observers: [NSObjectProtocol] = []
    private var sessionActive = true
    private var awake = true
    private var distributedObservers: [NSObjectProtocol] = []
    private var serviceStarted = false
    private var requestID = UUID()
    private var originPID: pid_t?
    private var commitWhenLoaded = false
    private var pendingSteps = 0
    private var initialDirection = 1
    private var switching = false
    private var refreshingOpenChooser = false

    init(catalog: WindowSwitchCatalog = WindowCatalog(), keyboard: WindowKeyboardMonitor = WindowKeyboardMonitor(),
         environment: WindowSwitcherEnvironment = .live,
         previews: WindowPreviewService = WindowPreviewService(), previewSetup: WindowPreviewSetupModel = WindowPreviewSetupModel()) {
        self.previews = previews; self.previewSetup = previewSetup
        self.catalog = catalog; self.keyboard = keyboard; self.environment = environment
        hasAccessibility = environment.accessibility()
        previewSubscription = previews.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        setupSubscription = previewSetup.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        previewSetup.onSuccessfulCheck = { [weak self] in self?.previews.noteSuccessfulAccessCheck() }
    }
    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        keyboard.stop(); catalog.stop(); previews.end()
    }
    func refreshPreviewPermission() { if environment.nativeServices { previews.refreshPermission() } }
    func openPreviewSetup() {
        guard environment.sessionActive() else { return }
        cancel(); previewSetup.present()
    }
    func openPreviewSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func updateChooserWidth(_ width: Double) {
        gridColumns = WindowChooserGeometry.columns(width: width, previews: settings.showsPreviews, previewScale: settings.previewScale)
    }
    func updateVisiblePreviews(_ ids: Set<UUID>) {
        visiblePreviewIDs = ids
        guard isShowing, settings.showsPreviews else { return }
        let ordered = items.filter { ids.contains($0.id) }.map(\.id)
        previews.setVisible(ordered.sorted { $0 == selectedID && $1 != selectedID })
        guard previews.hasPermission else { return }
        let bounded = Set(ordered.prefix(WindowPreviewPolicy.cacheLimit))
        guard !bounded.isEmpty, metadataVisibleIDs != bounded else { return }
        metadataVisibleIDs = bounded
        let request = requestID
        catalog.previewMetadata(for: Array(bounded)) { [weak self] enriched in
            guard let self, self.isShowing, self.requestID == request, self.metadataVisibleIDs == bounded else { return }
            self.previews.updateMetadata(enriched)
        }
    }

    var status: String {
        if !settings.isEnabled { return "Switcher module disabled" }
        if !hasAccessibility { return "Accessibility needed" }
        if !keyboardAvailable { return "Keyboard monitoring unavailable" }
        return "Ready · \(settings.shortcut.title)"
    }

    func configure(_ settings: WindowSwitcherSettings) {
        let changed = self.settings != settings
        self.settings = settings
        keyboard.shortcut = settings.shortcut
        if changed { cancel(); cycle = WindowGestureCycle() }
        if settings.isEnabled { start() } else if isRunning { stop() }
    }

    func setRecordingShortcut(_ recording: Bool) {
        recordingShortcut = recording
        keyboard.suspended = recording
        if recording { cancel() }
    }

    private func start() {
        if !isRunning {
            isRunning = true
            sessionActive = environment.sessionActive()
            keyboard.onCommand = { [weak self] command in self?.handle(command) ?? false }
            if environment.nativeServices {
                let center = NSWorkspace.shared.notificationCenter
                observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                    guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    if self.isShowing && app.processIdentifier != self.originPID { self.cancel() }
                    self.refreshAvailability()
                    self.catalog.noteFocus(processID: app.processIdentifier)
                })
                for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.catalog.applicationsChanged() })
                }
                for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        guard let self else { return }
                        self.suspendSession(sleeping: name == NSWorkspace.willSleepNotification)
                    })
                }
                for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        guard let self else { return }
                        if name == NSWorkspace.didWakeNotification { self.awake = true }
                        self.sessionActive = self.environment.sessionActive(); self.refreshAvailability()
                    })
                }
                let distributed = DistributedNotificationCenter.default()
                for rawName in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
                    distributedObservers.append(distributed.addObserver(forName: Notification.Name(rawName), object: nil, queue: .main) { [weak self] note in
                        guard let self else { return }
                        self.sessionActive = note.name.rawValue == "com.apple.screenIsLocked" ? false : self.environment.sessionActive()
                        if !self.sessionActive {
                            self.suspendSession(sleeping: false)
                        } else { self.refreshAvailability() }
                    })
                }
            }
            catalog.onWindowsChanged = { [weak self] in
                guard let self, self.isShowing, !self.isLoading else { return }
                self.refreshOpenChooser(cached: self.catalog.cachedSnapshot())
            }
        }
        refreshAvailability()
    }

    func stop() {
        previewSetup.dismiss()
        isRunning = false
        cancel()
        keyboardAvailable = false; switching = false
        keyboard.stop(); catalog.stop(); serviceStarted = false
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []; items = []; cycle = WindowGestureCycle()
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        distributedObservers = []
        panel?.contentView = nil; panel = nil
    }

    /// Shared by sleep/session observers and deterministic lifecycle checks.
    func suspendSession(sleeping: Bool) {
        if sleeping { awake = false } else { sessionActive = false }
        cancel(); keyboard.stop(); keyboardAvailable = false
        catalog.stop(); serviceStarted = false
    }

    func refreshAvailability() {
        hasAccessibility = environment.accessibility()
        refreshPreviewPermission()
        guard isRunning, awake, sessionActive else { return }
        if hasAccessibility {
            keyboardAvailable = environment.startKeyboard(keyboard)
            if !serviceStarted {
                serviceStarted = true; catalog.start()
                catalog.refresh { [weak self] snapshot in
                    guard let self, self.isRunning, !self.isShowing else { return }
                    self.items = snapshot.windows
                }
            }
        } else {
            cancel(); keyboard.stop(); keyboardAvailable = false
            if serviceStarted { catalog.stop(); serviceStarted = false }
        }
    }

    @discardableResult func show(reverse: Bool = false, releaseToConfirm: Bool = false) -> Bool {
        guard isRunning, awake, sessionActive, hasAccessibility, !switching else { return false }
        previewSetup.dismiss()
        if isShowing { step(reverse ? -1 : 1); return true }
        refreshPreviewPermission()
        originPID = environment.frontmostPID()
        isShowing = true; isLoading = true; items = []; selectedID = nil; message = "Finding windows…"
        initialDirection = reverse ? -1 : 1; pendingSteps = initialDirection; commitWhenLoaded = false
        keyboard.chooserOpen = true; keyboard.commitOnRelease = releaseToConfirm
        onChooserVisibility?(true)
        if environment.nativeServices {
            if panel == nil { panel = WindowSwitcherPanel(model: self) }
            panel?.show()
        }
        let request = UUID(); requestID = request
        let opening: (WindowCatalog.Snapshot) -> Void = { [weak self] snapshot in
            guard let self, self.isShowing, self.requestID == request else { return }
            guard self.environment.frontmostPID() == self.originPID else { self.cancel(); return }
            self.previewCatalogItems = snapshot.windows
            self.items = WindowOrdering.candidates(snapshot.windows, settings: self.settings, currentProcessID: self.originPID)
            if self.settings.showsPreviews { self.previews.begin(items: snapshot.windows) }
            self.selection.begin(ids: self.items.map(\.id), focusedID: snapshot.focusedID, direction: self.initialDirection)
            self.selection.step(self.pendingSteps - self.initialDirection)
            self.selectedID = self.selection.selectedID; self.isLoading = false
            self.message = self.items.isEmpty ? "No eligible windows were found. Open a window, then try again." :
                (snapshot.unavailableApps > 0 ? "Some apps did not expose windows through Accessibility." : "")
            // Handles a quick press/release while the first AX enumeration is still running.
            if self.commitWhenLoaded { self.confirm() }
        }
        if let cached = catalog.cachedSnapshot() {
            opening(cached)
            if isShowing { refreshOpenChooser() }
        } else { catalog.refresh(includePreviewMetadata: false, completion: opening) }
        return true
    }

    func step(_ direction: Int) {
        if isLoading { pendingSteps += direction; return }
        selection.step(direction); selectedID = selection.selectedID
    }
    func choose(_ id: UUID) { selection.select(id); selectedID = selection.selectedID; confirm() }
    func confirm() {
        guard isShowing else { return }
        if isLoading { commitWhenLoaded = true; return }
        guard let id = selection.selectedID else { cancel(); return }
        let origin = originPID
        cancel(); switching = true
        let request = requestID
        catalog.activate(id, expectedProcessID: origin) { [weak self] result in
            guard let self, self.requestID == request else { return }
            self.switching = false
            if case let .failure(error) = result { self.errorMessage = error.localizedDescription }
        }
    }
    func cancel() {
        catalog.cancelPendingActivations()
        catalog.cancelPreviewMetadata(); metadataVisibleIDs = []
        previews.end(); previewCatalogItems = []; visiblePreviewIDs = []
        switching = false
        requestID = UUID(); commitWhenLoaded = false; pendingSteps = 0
        refreshingOpenChooser = false
        isShowing = false; isLoading = false
        keyboard.chooserOpen = false; keyboard.commitOnRelease = false
        panel?.orderOut(nil); onChooserVisibility?(false)
    }

    func perform(_ action: SystemAction, completion: @escaping (Result<String, Error>) -> Void) {
        guard isRunning, awake, sessionActive, hasAccessibility else {
            completion(.failure(ActionExecutor.ActionError.message("Enable the Switcher module and allow Accessibility to switch windows."))); return
        }
        if action == .showWindowSwitcher {
            completion(show() ? .success("Window chooser opened") : .failure(ActionExecutor.ActionError.message("A window switch is already in progress.")))
            return
        }
        guard !switching else { completion(.failure(ActionExecutor.ActionError.message("A window switch is already in progress."))); return }
        cancel(); switching = true
        let request = UUID(); requestID = request
        let origin = environment.frontmostPID()
        catalog.refresh { [weak self] snapshot in
            guard let self else { return }
            guard self.isRunning, self.requestID == request, self.environment.frontmostPID() == origin else {
                if self.requestID == request { self.switching = false }; completion(.failure(ActionExecutor.ActionError.message("Window switch cancelled."))); return
            }
            let items = WindowOrdering.candidates(snapshot.windows, settings: self.settings, currentProcessID: origin)
            guard let id = self.cycle.next(ids: items.map(\.id), focusedID: snapshot.focusedID,
                                           direction: action == .previousWindow ? -1 : 1, at: ProcessInfo.processInfo.systemUptime) else {
                self.switching = false; completion(.failure(ActionExecutor.ActionError.message("No eligible windows were found."))); return
            }
            self.catalog.activate(id, expectedProcessID: origin) { result in
                if self.requestID == request { self.switching = false }; completion(result)
            }
        }
    }

    private func handle(_ command: WindowKeyboardMonitor.Command) -> Bool {
        guard isRunning, awake, sessionActive, hasAccessibility else { return false }
        switch command {
        case let .begin(reverse): return show(reverse: reverse, releaseToConfirm: true)
        case let .step(direction): step(direction)
        case let .vertical(direction): step(settings.layout.verticalStep(direction, columns: gridColumns))
        case .confirm: confirm()
        case .cancel: cancel()
        }
        return true
    }

    private func refreshOpenChooser(cached: WindowCatalog.Snapshot? = nil) {
        guard !refreshingOpenChooser else { return }
        refreshingOpenChooser = true
        let request = requestID
        let apply: (WindowCatalog.Snapshot) -> Void = { [weak self] snapshot in
            guard let self, self.isShowing, self.requestID == request else { return }
            self.refreshingOpenChooser = false
            let updated = WindowOrdering.candidates(snapshot.windows, settings: self.settings, currentProcessID: self.originPID)
            let previewsChanged = Dictionary(uniqueKeysWithValues: self.previewCatalogItems.map { ($0.id, $0) }) !=
                Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0) })
            self.selection.merge(updated.map(\.id))
            self.items = self.selection.ids.compactMap { id in updated.first { $0.id == id } }
            self.selectedID = self.selection.selectedID
            if self.settings.showsPreviews, previewsChanged {
                self.previewCatalogItems = snapshot.windows
                self.catalog.cancelPreviewMetadata(); self.metadataVisibleIDs = []
                self.previews.begin(items: snapshot.windows)
                self.updateVisiblePreviews(self.visiblePreviewIDs)
            }
            self.message = self.items.isEmpty ? "No eligible windows were found. Open a window, then try again." : ""
        }
        if let cached { apply(cached) }
        else { catalog.refresh(includePreviewMetadata: false, completion: apply) }
    }
}
