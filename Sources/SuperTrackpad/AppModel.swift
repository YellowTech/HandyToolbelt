import AppKit
import ApplicationServices
import Combine
import UniformTypeIdentifiers
import SuperTrackpadCore

enum TrackpadWorkspace: String, CaseIterable, Identifiable {
    case mappings, gym, groups, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .mappings: return "Mappings"; case .gym: return "Gesture Gym"; case .groups: return "App Groups"; case .settings: return "Settings" }
    }
}

final class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration {
        didSet {
            cancelPendingGestures()
            stackRuntime.end()
            if !configuration.trackpadModuleEnabled { stackKeyboard.stopMonitoring() }
            recognizers.removeAll()
            haptics.cancel()
            if !configuration.trackpadModuleEnabled { cancelVisualFeedback() }
            else if !configuration.visualFeedbackEnabled { onDismissToast?() }
            if replacingSavedConfiguration { return }
            guard canSave else { lastSaveSucceeded = false; return }
            do { try storage.save(configuration); lastSaveSucceeded = true }
            catch { lastSaveSucceeded = false; errorMessage = "Could not save your mappings: \(error.localizedDescription)" }
        }
    }
    @Published var selectedID: UUID? {
        didSet {
            if selectedID != oldValue { cancelPendingGestures() }
            if selectedID != nil && selectedStackID != nil { selectedStackID = nil }
            // Evaluate visibility at the selection change. A cached, detached
            // SwiftUI root can otherwise replay onChange after it reappears.
            if selectedID != oldValue, isSelected, showGym, !isCalibrating,
               let binding = configuration.bindings.first(where: { $0.id == selectedID }),
               gymGesture != binding.gesture {
                gymGesture = binding.gesture
            }
        }
    }
    @Published var selectedStackID: UUID? { didSet { if selectedStackID != nil && selectedID != nil { selectedID = nil } } }
    @Published private(set) var activeStackName: String?
    private let stackKeyboard: StackKeyboardDriver
    private(set) lazy var stackRuntime: GestureStackRuntime = {
        let runtime = GestureStackRuntime(keyboard: stackKeyboard)
        stackKeyboard.onUnavailable = { [weak self, weak runtime] in self?.cancelPendingGestures(); runtime?.end() }
        stackKeyboard.onPhysicalModifiersChanged = { [weak self] in self?.cancelPendingGestures() }
        runtime.execute = { [weak self] action, completion in
            guard let self else { return }
            if action.kind == .automation, let id = action.automationID {
                if let run = self.onAutomation { run(id, completion) }
                else { completion(.failure(ActionExecutor.ActionError.message("The automation runner is unavailable."))) }
            } else { self.executor.execute(action, completion: completion) }
        }
        runtime.onEnd = { [weak self] in
            guard let self else { return }
            self.cancelPendingGestures()
            self.activeStackName = nil
            self.liftRequired.formUnion(self.lastFrame.keys)
            self.recognizers.removeAll()
            self.cancelVisualFeedback()
        }
        runtime.onError = { [weak self] in self?.errorMessage = $0.localizedDescription }
        return runtime
    }()
    private var liftRequired = Set<UInt64>()
    private var stackTouchedDevices = Set<UInt64>()
    @Published var selectedDevice: InputDevice = .trackpad { didSet { if selectedDevice != oldValue { cancelPendingGestures() } } }
    @Published var devices: [TouchDevice] = [] {
        didSet { if devices != oldValue { cancelPendingGestures() } }
    }
    @Published var contacts: [Contact] = []
    @Published var activeCorner: Corner = .none
    @Published var modifierFinger: Int?
    @Published var lastGesture: String = "Try a gesture"
    @Published var lastDetail: String = "Live touches appear here."
    @Published var lastEventID = UUID()
    @Published var isRecordingShortcut = false {
        didSet { if isRecordingShortcut != oldValue { cancelPendingGestures() }; if isRecordingShortcut { onDismissToast?() } }
    }
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var clicksAvailable = false
    @Published var errorMessage: String?
    @Published var inputError: String?
    @Published var settingsNeedRecovery = false
    @Published private(set) var isRunning = false
    var windowChooserVisible = false {
        didSet { if windowChooserVisible != oldValue { cancelPendingGestures() }; if windowChooserVisible { onDismissToast?() } }
    }
    var onWindowAction: ((SystemAction, @escaping (Result<String, Error>) -> Void) -> Void)? {
        didSet { executor.onWindowAction = onWindowAction }
    }
    @Published private(set) var workspace: TrackpadWorkspace = .mappings
    @Published private(set) var isSelected = true
    var showGym: Bool { workspace == .gym }
    var showGroups: Bool { workspace == .groups }
    var gymActive: Bool { showGym && isSelected && frontmostBundleID == Bundle.main.bundleIdentifier }
    @Published var selectedGroupID: UUID?
    @Published private(set) var focusedApplicationName = ""
    @Published var gymTuning = GestureTuning() {
        didSet { cancelPendingGestures(); gymDrafts[selectedDevice] = gymTuning; recognizers.removeAll() }
    }
    @Published var gymGesture = GestureSpec(kind: .tipTapLeft) { didSet { cancelPendingGestures(); recognizers.removeAll() } }
    let gymReadout = GymReadout()
    var gymSnapshot: GymSnapshot {
        get { gymReadout.snapshot }
        set { gymReadout.update(newValue) }
    }
    let touchVisualization = TouchVisualization()
    let gymHistory = GymHistory()
    var gymAttempts: [GymAttempt] {
        get { gymHistory.attempts }
        set { gymHistory.attempts = newValue }
    }
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationSamples: [TipTapSample] = []
    @Published private(set) var calibrationMessage = "Six tip-taps can teach the app your natural angle, spacing, and timing."
    @Published private(set) var gymSaveMessage = "Changes stay in the gym until you apply them."
    private let storage: ConfigurationStore
    // The host runner shares this executor so gesture scripts and automation
    // scripts obey the same single-script gate and serial native queue.
    let executor = ActionExecutor()
    var onShowText: ((GestureAction) -> Void)?
    var onToast: ((String) -> Void)?
    var onDismissToast: (() -> Void)?
    var onAutomation: ((UUID, @escaping (Result<String, Error>) -> Void) -> Void)?
    private var replacingSavedConfiguration = false
    private var feedbackGeneration = UUID()
    private var input: MultitouchInput?
    private let clickMonitor = MouseClickMonitor()
    private let pressureMonitor = PressureMonitor()
    private struct PressSnapshot {
        var contacts: NativePressContacts
        let gesture: GestureSpec
        let device: TouchDevice
        let modifiers: Set<KeyboardModifier>
        let generation: UUID
    }
    private var nativePresses = NativePressArbiter<PressSnapshot>()
    private var pressGeneration = UUID()

    private func cancelPendingGestures() {
        pressGeneration = UUID(); nativePresses.cancel(); stackRuntime.cancelPresses()
        cancelTemporalGestures()
    }

    private struct TemporalDeadline {
        let time: Double
        let token: UUID
        let work: DispatchWorkItem
    }
    private var temporalGeneration = UUID()
    private var temporalDeadlines: [UInt64: TemporalDeadline] = [:]

    /// Context changes invalidate both a waiting tap and actions already queued
    /// onto the main queue. Held chords must lift before becoming candidates again.
    private func cancelTemporalGestures() {
        temporalGeneration = UUID()
        for deadline in temporalDeadlines.values { deadline.work.cancel() }
        temporalDeadlines.removeAll()
        for id in recognizers.keys { recognizers[id]?.cancelTemporalGestures() }
        stackRuntime.cancelTemporalGestures()
    }

    private func scheduleTemporalDeadline(for deviceID: UInt64) {
        let time = recognizers[deviceID]?.nextDeadline
        if temporalDeadlines[deviceID]?.time == time { return }
        temporalDeadlines.removeValue(forKey: deviceID)?.work.cancel()
        guard let time else { return }
        let token = UUID(), generation = temporalGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.temporalGeneration == generation,
                  self.temporalDeadlines[deviceID]?.token == token else { return }
            self.finishTemporalGestures(for: deviceID, at: ProcessInfo.processInfo.systemUptime)
        }
        temporalDeadlines[deviceID] = TemporalDeadline(time: time, token: token, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, time - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    /// Explicit time keeps idle-expiry and lifecycle checks independent of hardware.
    func finishTemporalGestures(for deviceID: UInt64, at time: Double) {
        temporalDeadlines.removeValue(forKey: deviceID)?.work.cancel()
        guard !synchronizeFocusedApplication(), inputSessionAvailable, configuration.trackpadModuleEnabled,
              stackRuntime.stack == nil, let device = devices.first(where: { $0.id == deviceID }),
              var recognizer = recognizers[deviceID] else { return }
        let generation = temporalGeneration, sequence = recognizer.feedbackSequence
        let events = recognizer.advanceTime(to: time)
        recognizers[deviceID] = recognizer
        scheduleTemporalDeadline(for: deviceID)
        if gymActive && previewVisible && device.kind == selectedDevice && recognizer.feedbackSequence != sequence {
            gymSnapshot.feedback = recognizer.feedback
            touchVisualization.updateFeedback(recognizer.feedback)
            recordGymFeedback(recognizer.feedback)
        }
        for event in events {
            _ = handle(event, from: device.kind, supportsHaptics: device.supportsForce, temporalGeneration: generation)
        }
    }
    private let haptics = HapticPlayer()
    private var recognizers: [UInt64: GestureRecognizer] = [:]
    private var lastFrame: [UInt64: Double] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private let nativeInputEnabled: Bool
    private let observeSession: Bool
    private let sessionIsActive: () -> Bool
    private let accessibilityTrusted: () -> Bool
    private let focusedApplication: () -> (bundleIdentifier: String?, processIdentifier: Int32?, name: String)
    private(set) var inputMonitoringActive = false
    private var canSave = true
    private var lastSaveSucceeded = true
    private var isAwake = true
    private var sessionActive = true
    private var lastRefresh: Double = 0
    private var lastReadout: Double = 0
    private var calibration: TipTapCalibration?
    private var calibrationDeviceID: UInt64?
    private var lastGymDeviceID: UInt64?
    private var trails: [Int: [TouchPoint]] = [:]
    private var previousGymContacts: [Contact] = []
    private var gymDrafts: [InputDevice: GestureTuning] = [:]
    private var initializedGymDevices: Set<InputDevice> = []
    private var focusContext = GestureFocusContext()
    private var focusChangedAt: Double = 0
    private var frontmostBundleID: String? { focusContext.bundleIdentifier }

    // Headless checks can inject queries and a fake keyboard without opening
    // multitouch devices, event taps, pressure monitors, or system observers.
    init(storage: ConfigurationStore = .init(), nativeInputEnabled: Bool = true, observeSession: Bool = true,
         sessionIsActive: @escaping () -> Bool = AppModel.currentSessionIsActive,
         accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         stackKeyboard: StackKeyboardDriver = StackKeyboardDriver(),
         focusedApplication: @escaping () -> (bundleIdentifier: String?, processIdentifier: Int32?, name: String) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.bundleIdentifier, app?.processIdentifier, app?.localizedName ?? "")
         }) {
        self.storage = storage
        self.nativeInputEnabled = nativeInputEnabled
        self.observeSession = observeSession
        self.sessionIsActive = sessionIsActive
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedApplication = focusedApplication
        self.stackKeyboard = stackKeyboard
        do { configuration = try storage.load() }
        catch {
            canSave = false
            configuration = AppConfiguration()
            configuration.windowSwitcher.isEnabled = false
            settingsNeedRecovery = true
            errorMessage = "Could not read saved mappings. The original file is preserved. \(error.localizedDescription)"
        }
        executor.onShowText = { [weak self] action in self?.onShowText?(action) }
        selectedID = configuration.bindings.first?.id
        selectedGroupID = configuration.applicationGroups.first?.id
        synchronizeFocusedApplication()
    }

    var visibleStacks: [GestureStack] { configuration.stacks.filter { $0.device == selectedDevice } }
    var visibleBindings: [GestureBinding] { configuration.bindings.filter { $0.device == selectedDevice } }
    var deviceSummary: String {
        let connected = devices.filter { $0.kind == selectedDevice }
        if let first = connected.first { return first.name + (connected.count > 1 ? " + \(connected.count - 1)" : "") }
        return "No \(selectedDevice.title.lowercased()) connected"
    }
    var status: String {
        if !isRunning { return "Gestures stopped" }
        if inputError != nil { return "Input unavailable" }
        if let activeStackName { return "Stack active · " + activeStackName }
        if gymActive { return "Gesture gym · actions paused" }
        if !hasAccessibility { return "Accessibility needed" }
        return "Gestures enabled" + (focusedApplicationName.isEmpty ? "" : " · \(focusedApplicationName)")
    }
    var productionFocusAllowsActions: Bool {
        !gymActive && frontmostBundleID != nil && frontmostBundleID != Bundle.main.bundleIdentifier
    }
    var canRunActions: Bool {
        isRunning && configuration.trackpadModuleEnabled && !windowChooserVisible && stackRuntime.stack == nil && productionFocusAllowsActions && hasAccessibility && sessionActive && isAwake
    }
    var gymHasChanges: Bool { gymDrafts[selectedDevice].map { $0.validated != configuration.tuning(for: selectedDevice) } ?? false }
    var devicesWithGymChanges: [InputDevice] {
        InputDevice.allCases.filter { device in gymDrafts[device].map { $0.validated != configuration.tuning(for: device) } ?? false }
    }
    var hasUnappliedGymChanges: Bool { !devicesWithGymChanges.isEmpty }
    func forceClickCapability(for device: InputDevice) -> ForceClickCapability {
        ForceClickCapability(device: device, connected: devices)
    }
    var hapticsAvailable: Bool { devices.contains { $0.kind == .trackpad && $0.supportsForce } }
    private var previewVisible: Bool {
        isSelected && (workspace == .mappings || workspace == .gym) && NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible && !$0.isMiniaturized }
    }

    private func cancelVisualFeedback() {
        feedbackGeneration = UUID()
        // Shared Display owns panels independently of Trackpad.
    }
    func previewText(_ action: GestureAction) {
        guard isAwake, sessionActive else { return }
        onShowText?(action)
    }
    func previewGestureToast() {
        guard isAwake, sessionActive else { return }
        onToast?("Tip-tap right · Next browser tab")
    }
    private var canShowGestureToast: Bool {
        isRunning && isAwake && sessionActive && configuration.trackpadModuleEnabled &&
        configuration.displayModuleEnabled && configuration.visualFeedbackEnabled && !windowChooserVisible && stackRuntime.stack == nil &&
        !gymActive &&
        frontmostBundleID != Bundle.main.bundleIdentifier
    }

    func testHaptics(_ pattern: HapticPattern) {
        guard isRunning, configuration.trackpadModuleEnabled, isAwake, sessionActive, hapticsAvailable else { return }
        haptics.play(pattern)
    }

    func reviewGymTrials() {
        if let device = devicesWithGymChanges.first { selectDevice(device) }
        selectWorkspace(.gym)
    }

    func selectWorkspace(_ next: TrackpadWorkspace) {
        guard next != workspace else { return }
        if isRecordingShortcut { isRecordingShortcut = false }
        stopCalibration(); recognizers.removeAll(); haptics.cancel()
        touchVisualization.reset()
        if next == .gym {
            let firstVisit = initializedGymDevices.insert(selectedDevice).inserted
            let tuning = gymDrafts[selectedDevice] ?? configuration.tuning(for: selectedDevice)
            if gymTuning != tuning { gymTuning = tuning }
            if firstVisit { gymGesture = configuration.bindings.first(where: { $0.id == selectedID })?.gesture ?? .init(kind: .tipTapLeft) }
            var snapshot = GymSnapshot()
            if let device = devices.first(where: { $0.kind == selectedDevice }) {
                snapshot.aspectRatio = device.aspectRatio; snapshot.measuredAspect = device.hasMeasuredAspect; snapshot.deviceName = device.name
            }
            gymSnapshot = snapshot
            if !gymAttempts.isEmpty { gymAttempts = [] }
            trails = [:]; previousGymContacts = []
            if !calibrationSamples.isEmpty { calibrationSamples = [] }
            lastGymDeviceID = nil
            let message = "Six tip-taps can teach the app your natural angle, spacing, and timing."
            if calibrationMessage != message { calibrationMessage = message }
            let saveMessage = "Changes stay in the gym until you apply them."
            if gymSaveMessage != saveMessage { gymSaveMessage = saveMessage }
        }
        cancelPendingGestures()
        workspace = next
    }

    func showApplicationGroups(selecting id: UUID? = nil) {
        selectWorkspace(.groups)
        if let id { selectedGroupID = id }
    }

    func practice(_ gesture: GestureSpec) {
        selectWorkspace(.gym)
        gymGesture = gesture
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        cancelPendingGestures()
        isSelected = selected
        haptics.cancel()
        if !selected {
            if isRecordingShortcut { isRecordingShortcut = false }
            stopCalibration()
        }
        recognizers.removeAll()
        previousGymContacts = []; lastGymDeviceID = nil; trails = [:]
        touchVisualization.reset()
    }

    func addGroup() {
        var name = "New group"
        var suffix = 2
        while configuration.applicationGroups.contains(where: { $0.name == name }) {
            name = "New group \(suffix)"; suffix += 1
        }
        let group = ApplicationGroup(name: name)
        configuration.applicationGroups.append(group)
        selectedGroupID = group.id
    }

    func updateGroup(_ group: ApplicationGroup) {
        guard let index = configuration.applicationGroups.firstIndex(where: { $0.id == group.id }) else { return }
        configuration.applicationGroups[index] = group
    }

    func groupUseCount(_ id: UUID) -> Int { configuration.bindings.filter { $0.applicationGroupID == id }.count + configuration.stacks.filter { $0.applicationGroupID == id }.count }

    func removeGroup(_ id: UUID) {
        guard groupUseCount(id) == 0 else { return }
        configuration.applicationGroups.removeAll { $0.id == id }
        selectedGroupID = configuration.applicationGroups.first?.id
    }

    var runningApplications: [GroupApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
            return GroupApplication(app.localizedName ?? id, id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addApplication(_ app: GroupApplication, to groupID: UUID) {
        guard var group = configuration.applicationGroups.first(where: { $0.id == groupID }),
              !group.applications.contains(where: { $0.id == app.id }) else { return }
        group.applications.append(app)
        group.applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        updateGroup(group)
    }

    func chooseApplications(for groupID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add apps to group"
        panel.prompt = "Add Apps"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
                    self.errorMessage = "\(url.lastPathComponent) has no application identifier and could not be added."
                    continue
                }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
                self.addApplication(.init(name, identifier), to: groupID)
            }
        }
    }

    @discardableResult private func synchronizeFocusedApplication() -> Bool {
        let app = focusedApplication()
        return updateFocusedApplication(bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier, name: app.name)
    }

    @discardableResult func updateFocusedApplication(bundleIdentifier: String?, processIdentifier: Int32?, name: String = "") -> Bool {
        let changed = focusContext.update(bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier)
        if changed {
            cancelPendingGestures()
            if bundleIdentifier == Bundle.main.bundleIdentifier { stackRuntime.end() }
            haptics.cancel()
            focusChangedAt = ProcessInfo.processInfo.systemUptime
            focusedApplicationName = name
            recognizers.removeAll(); lastFrame.removeAll()
            clearContactReadout()
            touchVisualization.reset()
            if isCalibrating && frontmostBundleID != Bundle.main.bundleIdentifier { stopCalibration() }
        }
        return changed
    }

    func applyGymSettings() {
        configuration.setTuning(gymTuning, for: selectedDevice)
        gymTuning = configuration.tuning(for: selectedDevice)
        gymSaveMessage = lastSaveSucceeded ? "Applied to all \(selectedDevice.title.lowercased()) gestures and saved." : "Applied for this session. Settings could not be saved."
    }

    func startCalibration() {
        calibration = TipTapCalibration(); calibrationDeviceID = nil; calibrationSamples = []
        gymGesture = .init(kind: .tipTapLeft)
        calibrationMessage = "Rest one finger, then tip-tap LEFT three times. Keep the resting finger down."
        isCalibrating = true
        trails = [:]; previousGymContacts = []; gymAttempts = []
        touchVisualization.reset()
    }

    func stopCalibration() {
        guard isCalibrating || calibration != nil || calibrationDeviceID != nil else { return }
        if isCalibrating { calibrationMessage = "Calibration stopped. Your saved settings have not changed." }
        isCalibrating = false; calibration = nil; calibrationDeviceID = nil
    }

    private func train(_ points: [Contact], device: TouchDevice, time: Double, pressed: Bool) {
        guard isCalibrating, frontmostBundleID == Bundle.main.bundleIdentifier else { return }
        if calibrationDeviceID == nil && !points.isEmpty { calibrationDeviceID = device.id }
        guard calibrationDeviceID == device.id, var trainer = calibration else { return }
        let outcome = trainer.process(points, at: time, aspectRatio: device.aspectRatio, physicalButtonDown: pressed)
        calibration = trainer
        guard let outcome else { return }
        switch outcome {
        case let .rejected(reason): calibrationMessage = reason
        case .accepted:
            if configuration.hapticsInPractice && device.supportsForce { haptics.play(configuration.hapticPattern) }
            calibrationSamples = trainer.samples
            if trainer.isComplete {
                isCalibrating = false
                if let suggestion = trainer.suggestion(from: gymTuning) {
                    gymTuning = suggestion
                    calibrationMessage = "Six samples collected. Suggested settings are live in the gym. Try both sides, then apply when they feel right."
                    gymSaveMessage = "Calibration is a draft. Apply settings to use it outside the gym."
                } else {
                    calibrationMessage = "The left and right angles varied too much to suggest one axis. Try calibration again with a consistent hand position."
                }
            } else {
                gymGesture = .init(kind: trainer.nextDirection)
                calibrationMessage = trainer.leftCount < 3 ? "Left \(trainer.leftCount)/3. Repeat a tip-tap to the LEFT." :
                    "Left complete. Tip-tap RIGHT \(3 - trainer.rightCount) more \(3 - trainer.rightCount == 1 ? "time" : "times")."
            }
        }
    }

    enum InputSessionEvent { case sleep, wake, resign, activate, lock, unlock }

    static func currentSessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[kCGSessionOnConsoleKey as String] as? Bool ?? false)
            && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }

    var inputSessionAvailable: Bool { isRunning && isAwake && sessionActive }

    func handleInputSessionEvent(_ event: InputSessionEvent) {
        guard isRunning else { return }
        switch event {
        case .sleep: isAwake = false
        case .wake:
            isAwake = true
            sessionActive = sessionIsActive()
        case .resign, .lock: sessionActive = false
        case .activate, .unlock: sessionActive = sessionIsActive()
        }
        if inputSessionAvailable { startInputMonitoring() }
        else { suspendInputMonitoring() }
        refreshPermissions()
    }

    private func suspendInputMonitoring() {
        cancelPendingGestures()
        // Contacts held across suspension must lift before recognition resumes.
        // Idle devices can start their next gesture immediately after unlocking.
        liftRequired.formUnion(recognizers.compactMap { $0.value.contacts.isEmpty ? nil : $0.key })
        // The runtime releases owned modifiers before its required release actions.
        stackRuntime.end()
        stackKeyboard.stopMonitoring()
        inputMonitoringActive = false
        input?.stop()
        clickMonitor.stop()
        pressureMonitor.stop()
        if clicksAvailable { clicksAvailable = false }
        recognizers.removeAll()
        lastFrame.removeAll()
        clearContactReadout()
        stopCalibration()
        haptics.cancel()
        cancelVisualFeedback()
        touchVisualization.reset()
        focusChangedAt = ProcessInfo.processInfo.systemUptime
    }

    private func startInputMonitoring() {
        guard inputSessionAvailable, !inputMonitoringActive else { return }
        inputMonitoringActive = true
        guard nativeInputEnabled else { return }
        do {
            if input == nil { input = try MultitouchInput() }
            input?.onFrame = { [weak self] device, contacts, time in self?.receive(device, contacts, time) }
            input?.onDevicesChanged = { [weak self] devices in
                if let owner = self?.stackRuntime.deviceID, !devices.contains(where: { $0.id == owner }) { self?.stackRuntime.end() }
                self?.cancelPendingGestures()
                self?.haptics.cancel()
                if let id = self?.calibrationDeviceID, !devices.contains(where: { $0.id == id }) {
                    self?.stopCalibration()
                    self?.calibrationMessage = "The training device disconnected. Reconnect it and start again."
                }
                self?.devices = devices; self?.recognizers.removeAll(); self?.lastFrame.removeAll(); self?.contacts = []
                self?.touchVisualization.reset()
                self?.focusContext.forgetDevices(except: Set(devices.map(\.id)))
            }
            input?.onError = { [weak self] error in self?.cancelPendingGestures(); self?.stackRuntime.end(); self?.inputError = error }
            input?.refresh(force: true)
        } catch { inputError = error.localizedDescription }
        clickMonitor.onClick = { [weak self] button, time in self?.physicalClick(button: button, at: time) ?? false }
        clickMonitor.onRelease = { [weak self] button, time in self?.physicalRelease(button: button, at: time) }
        clickMonitor.onUnavailable = { [weak self] in self?.cancelPendingGestures() }
        pressureMonitor.onStage = { [weak self] stage, time in self?.pressureChanged(stage: stage, at: time) }
        pressureMonitor.start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isAwake = true
        sessionActive = sessionIsActive()
        synchronizeFocusedApplication()
        if inputSessionAvailable { startInputMonitoring() }
        else { suspendInputMonitoring() }
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.stackRuntime.stack != nil && ProcessInfo.processInfo.systemUptime - self.stackRuntime.lastFrame > 0.8 { self.stackRuntime.end() }
            self.refreshPermissions()
            let now = ProcessInfo.processInfo.systemUptime
            if self.inputSessionAvailable && self.nativeInputEnabled && now - self.lastRefresh > 6 {
                self.input?.refresh(); self.lastRefresh = now
            }
            if now - (self.lastFrame.values.max() ?? 0) > 0.8 {
                self.clearContactReadout()
            }
        }
        guard observeSession else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.synchronizeFocusedApplication()
        })
        let workspaceEvents: [(Notification.Name, InputSessionEvent)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.sessionDidResignActiveNotification, .resign), (NSWorkspace.sessionDidBecomeActiveNotification, .activate)
        ]
        for (name, event) in workspaceEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleInputSessionEvent(event)
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [("com.apple.screenIsLocked", InputSessionEvent.lock), ("com.apple.screenIsUnlocked", .unlock)] {
            lockObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.handleInputSessionEvent(event)
            })
        }
    }

    func stop() {
        cancelPendingGestures()
        stackRuntime.end()
        stackKeyboard.stopMonitoring()
        isRunning = false
        inputMonitoringActive = false
        cancelVisualFeedback()
        timer?.invalidate(); timer = nil
        clickMonitor.stop(); pressureMonitor.stop(); haptics.cancel(); input?.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        lockObservers.removeAll()
        recognizers = [:]; lastFrame = [:]; contacts = []; devices = []
        touchVisualization.reset()
        activeCorner = .none; modifierFinger = nil; clicksAvailable = false
        stopCalibration()
        focusContext = GestureFocusContext()
    }

    // The watchdog runs even when no fingers are down. Do not invalidate every
    // settings view just to assign the same idle state again.
    func clearContactReadout() {
        if !gymSnapshot.contacts.isEmpty || gymSnapshot.modifier != .none || gymSnapshot.modifierFinger != nil {
            var snapshot = gymSnapshot
            snapshot.contacts = []; snapshot.modifier = .none; snapshot.modifierFinger = nil
            gymSnapshot = snapshot
        }
        if !contacts.isEmpty { contacts = [] }
        if activeCorner != .none { activeCorner = .none }
        if modifierFinger != nil { modifierFinger = nil }
    }

    func refreshPermissions() {
        let trusted = accessibilityTrusted()
        if hasAccessibility != trusted {
            hasAccessibility = trusted
            if !trusted { cancelPendingGestures() }
        }
        if !hasAccessibility || !inputSessionAvailable {
            pressGeneration = UUID(); nativePresses.cancel(); stackRuntime.cancelPresses()
            stackRuntime.end(); stackKeyboard.stopMonitoring()
        }
        else if nativeInputEnabled && configuration.trackpadModuleEnabled { stackKeyboard.startMonitoring() }
        let available: Bool
        if hasAccessibility && inputSessionAvailable && nativeInputEnabled { available = clickMonitor.start() }
        else { clickMonitor.stop(); available = false }
        if clicksAvailable != available { clicksAvailable = available }
    }

    func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    /// Enabling is a transaction boundary: the published UI cache may be stale
    /// while Gestures is stopped, so query macOS without requesting permission.
    func authorizeModuleTransition(to value: AppConfiguration) throws {
        let enabling = (!configuration.trackpadModuleEnabled && value.trackpadModuleEnabled)
            || (!configuration.windowSwitcher.isEnabled && value.windowSwitcher.isEnabled)
            || (!configuration.snappingModuleEnabled && value.snappingModuleEnabled)
        guard enabling else { return }
        let trusted = accessibilityTrusted()
        if hasAccessibility != trusted { hasAccessibility = trusted }
        try ModulePermissionPolicy.validateTransition(from: configuration, to: value, hasAccessibility: trusted)
    }

    /// Persist first; publishing only follows a successful atomic write.
    func replaceConfiguration(_ value: AppConfiguration) throws {
        guard canSave else { throw ActionExecutor.ActionError.message("Recover unreadable settings before replacing configuration.") }
        try authorizeModuleTransition(to: value)
        try storage.save(value)
        replacingSavedConfiguration = true
        configuration = value
        replacingSavedConfiguration = false
        lastSaveSucceeded = true
    }

    func savedConfigurationForTransfer() throws -> AppConfiguration {
        guard canSave, !settingsNeedRecovery else { throw ActionExecutor.ActionError.message("Recover unreadable settings in Gestures before exporting or importing.") }
        guard lastSaveSucceeded else { throw ActionExecutor.ActionError.message("Your latest settings could not be saved. Resolve the save error and retry before exporting or importing.") }
        return configuration
    }

    func saveBeforeRestart() throws {
        // Never replace an unreadable settings file with the temporary fallback configuration.
        if canSave { try storage.save(configuration) }
    }

    func reconnect() {
        guard inputSessionAvailable else { return }
        inputError = nil
        if nativeInputEnabled { input?.refresh(force: true) }
        refreshPermissions()
    }

    func addStack() {
        selectWorkspace(.mappings)
        let stack = GestureStack(device: selectedDevice)
        configuration.stacks.append(stack); selectedStackID = stack.id
    }
    func updateStack(_ stack: GestureStack) {
        guard let index = configuration.stacks.firstIndex(where: { $0.id == stack.id }) else { return }
        configuration.stacks[index] = stack
    }
    func removeStack(_ id: UUID) {
        configuration.stacks.removeAll { $0.id == id }
        selectedStackID = visibleStacks.first?.id
        if selectedStackID == nil { selectedID = visibleBindings.first?.id }
    }
    func addBinding() {
        selectWorkspace(.mappings)
        // Start disabled: incomplete or duplicate mappings never become active while editing.
        let binding = GestureBinding(device: selectedDevice, gesture: .init(kind: .tap, fingers: 3), action: .init(kind: .shortcut), isEnabled: false)
        configuration.bindings.append(binding)
        selectedID = binding.id
    }
    func removeBinding(_ id: UUID) {
        configuration.bindings.removeAll { $0.id == id }
        selectedID = visibleBindings.first?.id
    }
    func selectDevice(_ device: InputDevice) {
        guard device != selectedDevice else { return }
        haptics.cancel()
        stopCalibration()
        selectedDevice = device; selectedID = visibleBindings.first?.id
        selectedStackID = selectedID == nil ? visibleStacks.first?.id : nil
        contacts = []; activeCorner = .none; modifierFinger = nil
        touchVisualization.reset()
        gymTuning = gymDrafts[device] ?? configuration.tuning(for: device)
        if showGym {
            if initializedGymDevices.insert(device).inserted {
                gymGesture = configuration.bindings.first(where: { $0.id == selectedID })?.gesture ?? .init(kind: .tipTapLeft)
            }
            gymSnapshot = GymSnapshot()
            gymAttempts = []; calibrationSamples = []; trails = [:]; previousGymContacts = []
            lastGymDeviceID = nil
            calibrationMessage = "Six tip-taps can teach the app your natural angle, spacing, and timing."
            gymSaveMessage = "Changes stay in the gym until you apply them."
        }
    }
    func update(_ binding: GestureBinding) {
        guard let index = configuration.bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        configuration.bindings[index] = binding
    }
    func recoverSettings() {
        do {
            let recovered = AppConfiguration()
            try storage.recover(with: recovered)
            // Publish only after persistence commits; didSet must not attempt a
            // second save whose error could otherwise be hidden by this method.
            replacingSavedConfiguration = true
            configuration = recovered
            replacingSavedConfiguration = false
            canSave = true
            lastSaveSucceeded = true
            selectedID = configuration.bindings.first?.id
            selectedGroupID = configuration.applicationGroups.first?.id
            settingsNeedRecovery = false; errorMessage = nil
        } catch {
            lastSaveSucceeded = false
            errorMessage = "Could not recover your settings: \(error.localizedDescription)"
        }
    }

    func recognitionTuning(for device: InputDevice) -> GestureTuning {
        gymActive && device == selectedDevice ? gymTuning.validated : configuration.tuning(for: device)
    }
    func recognitionCorners(for device: InputDevice) -> Set<Corner> {
        let previewing = frontmostBundleID == Bundle.main.bundleIdentifier
        var corners = Set(configuration.bindings.filter {
            $0.device == device && $0.keyboardModifiers.matches(stackKeyboard.physicalModifiers) && (($0.isEnabled && configuration.applies($0, to: frontmostBundleID)) || (previewing && $0.id == selectedID))
        }.map { $0.gesture.corner }.filter { $0 != .none })
        if productionFocusAllowsActions {
            corners.formUnion(configuration.stacks.filter { $0.device == device && $0.isEnabled && $0.keyboardModifiers.matches(stackKeyboard.physicalModifiers) && configuration.matchStack(device: device, corner: $0.corner, frontmostBundleIdentifier: frontmostBundleID, keyboardModifiers: stackKeyboard.physicalModifiers)?.id == $0.id }.map(\.corner))
        }
        if gymActive && device == selectedDevice { corners = gymGesture.corner == .none ? [] : [gymGesture.corner] }
        return corners
    }

    func recognitionTemporalSpecs(for device: InputDevice) -> Set<GestureSpec> {
        if gymActive {
            return device == selectedDevice && (gymGesture.kind == .longTouch || gymGesture.kind == .doubleTap) ? [gymGesture] : []
        }
        if frontmostBundleID == Bundle.main.bundleIdentifier {
            guard isSelected, workspace == .mappings, device == selectedDevice,
                  let selected = configuration.bindings.first(where: { $0.id == selectedID }),
                  selected.device == device, (selected.gesture.kind == .longTouch || selected.gesture.kind == .doubleTap) else { return [] }
            return [selected.gesture]
        }
        guard canRunActions, !isRecordingShortcut else { return [] }
        // Reserve ambiguous scopes too: dispatch resolves the match, without
        // accidentally falling through to an unrelated single-tap action.
        return Set(configuration.bindings.filter {
            $0.isEnabled && $0.device == device && ($0.gesture.kind == .longTouch || $0.gesture.kind == .doubleTap) &&
            $0.keyboardModifiers.matches(stackKeyboard.physicalModifiers) && configuration.applies($0, to: frontmostBundleID)
        }.map(\.gesture))
    }

    // Kept internal so headless lifecycle checks can replay raw frames without
    // constructing the native input driver or dispatching a configured action.
    func receive(_ device: TouchDevice, _ points: [Contact], _ time: Double) {
        nativePresses.validate { $0.contacts.accepts(deviceID: device.id, contacts: points, at: time) }

        if stackRuntime.stack != nil {
            if points.isEmpty { stackTouchedDevices.remove(device.id) } else { stackTouchedDevices.insert(device.id); liftRequired.insert(device.id) }
            if !isRunning || !sessionActive || !isAwake || !configuration.trackpadModuleEnabled { stackRuntime.end(); return }
            stackRuntime.frame(deviceID: device.id, contacts: points, time: time, cornerSize: configuration.tuning(for: device.kind).cornerSize, pressed: nativeInputEnabled && CGEventSource.buttonState(.combinedSessionState, button: .left))
            return
        }
        if liftRequired.contains(device.id) {
            // A stale queued lift, invalid timestamp, or suspended callback must
            // not clear the barrier for contacts still held after resuming.
            if points.isEmpty, inputSessionAvailable, time.isFinite, time >= focusChangedAt {
                liftRequired.remove(device.id)
                recognizers[device.id] = nil
                _ = focusContext.acceptsFrame(deviceID: device.id, hasContacts: false)
            }
            return
        }
        guard isRunning, sessionActive, isAwake else { return }
        guard time >= focusChangedAt else {
            if points.isEmpty { _ = focusContext.acceptsFrame(deviceID: device.id, hasContacts: false) }
            return
        }
        guard focusContext.acceptsFrame(deviceID: device.id, hasContacts: !points.isEmpty) else { return }
        var recognizer = recognizers[device.id] ?? GestureRecognizer()
        recognizer.tuning = recognitionTuning(for: device.kind)
        recognizer.surfaceAspectRatio = device.aspectRatio
        let previousSequence = recognizer.feedbackSequence
        let corners = recognitionCorners(for: device.kind)
        let pressed = nativeInputEnabled && (0...2).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
        let events = recognizer.process(points, at: time, enabledCorners: corners, physicalButtonDown: pressed,
            eligibleTemporalSpecs: recognitionTemporalSpecs(for: device.kind))
        recognizers[device.id] = recognizer
        scheduleTemporalDeadline(for: device.id)
        nativePresses.validate { press in
            press.contacts.deviceID != device.id || points.isEmpty ||
                (recognizer.modifier == press.contacts.corner && recognizer.modifierFinger == press.contacts.cornerFinger)
        }
        lastFrame[device.id] = time
        if canRunActions, let finger = recognizer.modifierFinger,
           let stack = configuration.matchStack(device: device.kind, corner: recognizer.modifier, frontmostBundleIdentifier: frontmostBundleID, keyboardModifiers: stackKeyboard.physicalModifiers) {
            cancelVisualFeedback(); activeStackName = stack.name
            stackTouchedDevices = [device.id]; liftRequired.insert(device.id)
            cancelPendingGestures()
            stackRuntime.begin(stack, deviceID: device.id, fingerID: finger, time: time, tuning: configuration.tuning(for: device.kind), aspect: device.aspectRatio)
            return
        }
        let windowVisible = previewVisible
        if gymActive && windowVisible && device.kind == selectedDevice {
            train(points, device: device, time: time, pressed: pressed)
            if !points.isEmpty || lastGymDeviceID == device.id {
                if lastGymDeviceID != device.id || (previousGymContacts.isEmpty && !points.isEmpty) { trails = [:] }
                lastGymDeviceID = device.id
                previousGymContacts = points
                for point in points {
                    var path = trails[point.id] ?? []
                    if path.last != point.position { path.append(point.position) }
                    trails[point.id] = Array(path.suffix(60))
                }
                if trails.count > 10 { trails = trails.filter { id, _ in points.contains { $0.id == id } } }
                if recognizer.feedbackSequence != previousSequence { recordGymFeedback(recognizer.feedback) }
                let snapshot = GymSnapshot(contacts: points, trails: trails, feedback: recognizer.feedback,
                    modifier: recognizer.modifier, modifierFinger: recognizer.modifierFinger,
                    aspectRatio: device.aspectRatio, measuredAspect: device.hasMeasuredAspect, deviceName: device.name)
                touchVisualization.submit(snapshot, deviceID: device.id, at: time)
                // Text needn't redraw the entire form at the contact sampling rate.
                if time - lastReadout >= 1.0 / 12 || recognizer.feedbackSequence != previousSequence ||
                    gymSnapshot.contacts.map(\.id) != points.map(\.id) || points.isEmpty {
                    if gymSnapshot != snapshot { gymSnapshot = snapshot }
                    lastReadout = time
                }
            }
        }
        if windowVisible && device.kind == selectedDevice {
            if !showGym {
                touchVisualization.submit(GymSnapshot(contacts: points, modifier: recognizer.modifier,
                    modifierFinger: recognizer.modifierFinger), deviceID: device.id, at: time)
            }
            // The compact readout only needs finger membership and corner changes.
            if contacts.map(\.id) != points.map(\.id) { contacts = points }
            if activeCorner != recognizer.modifier { activeCorner = recognizer.modifier }
            if modifierFinger != recognizer.modifierFinger { modifierFinger = recognizer.modifierFinger }
        }
        let generation = temporalGeneration
        for event in events { _ = handle(event, from: device.kind, supportsHaptics: device.supportsForce, temporalGeneration: generation) }
    }

    // Real native events only. Raw contact pressure is reserved for visualization.
    func pressureChanged(stage: Int, at time: Double) {
        guard isRunning, isAwake, sessionActive, configuration.trackpadModuleEnabled else { cancelPendingGestures(); return }
        guard !synchronizeFocusedApplication() else { return }
        if stackRuntime.stack != nil {
            if stackTouchedDevices.count == 1 { stackRuntime.pressure(stage: stage, at: time) }
            else { stackRuntime.cancelPresses() }
        } else if let press = nativePresses.stage(stage, at: time), valid(press, at: time) {
            var force = press.gesture; force.kind = .forceClick
            reportPhysical(force, device: press.device, nativeGeneration: press.generation)
        }
        guard previewVisible else { return }
        let candidates = devices.filter { !(recognizers[$0.id]?.contacts.isEmpty ?? true) && time - (lastFrame[$0.id] ?? 0) < 0.15 }
        if candidates.count == 1, let device = candidates.first, device.kind == selectedDevice, device.supportsForce {
            touchVisualization.updatePress(stage: stage)
        }
    }

    private func valid(_ press: PressSnapshot, at time: Double) -> Bool {
        press.generation == pressGeneration && press.modifiers == stackKeyboard.physicalModifiers &&
        isRunning && isAwake && sessionActive && hasAccessibility && configuration.trackpadModuleEnabled &&
        time - press.contacts.lastFrame < 0.15 && devices.contains(where: { $0.id == press.device.id && $0.supportsForce && $0.kind == .trackpad })
    }

    func physicalRelease(button: Int64, at time: Double) {
        guard button == 0 else { return }
        touchVisualization.updatePress(stage: 0)
        nativePresses.release(at: time); stackRuntime.release(at: time)
        DispatchQueue.main.asyncAfter(deadline: .now() + NativePressArbiter<PressSnapshot>.releaseGrace) { [weak self] in
            self?.finishNativePresses(at: time + NativePressArbiter<PressSnapshot>.releaseGrace)
        }
    }

    func finishNativePresses(at time: Double) {
        guard !synchronizeFocusedApplication() else { return }
        stackRuntime.finishPresses(at: time)
        for press in nativePresses.finish(at: time) where valid(press, at: time) {
            if press.gesture.allowedFingerCounts().contains(press.gesture.fingers) { reportPhysical(press.gesture, device: press.device, nativeGeneration: press.generation) }
        }
    }

    @discardableResult func physicalClick(button: Int64 = 0, at time: Double? = nil) -> Bool {
        let now = time ?? ProcessInfo.processInfo.systemUptime
        // Even a mouse-down with no remaining contacts cancels a waiting tap.
        // This preserves an emitted long touch's suppression of a later click.
        cancelTemporalGestures()
        if button != 0 && nativePresses.hasPending { return false }
        guard !synchronizeFocusedApplication() else { return false }
        if stackRuntime.stack != nil {
            guard stackTouchedDevices.count == 1, stackTouchedDevices.contains(stackRuntime.deviceID ?? 0),
                  let device = devices.first(where: { $0.id == stackRuntime.deviceID }) else { stackRuntime.cancelPresses(); return false }
            return stackRuntime.click(at: now, primary: button == 0, supportsForce: device.kind == .trackpad && device.supportsForce)
        }
        let candidates = recognizers.keys.filter { !(recognizers[$0]?.contacts.isEmpty ?? true) && now - (lastFrame[$0] ?? 0) < 0.15 }
        if candidates.count == 1, let id = candidates.first,
           devices.first(where: { $0.id == id })?.kind == selectedDevice, previewVisible { touchVisualization.updatePress(stage: 1) }
        var found: (GestureSpec, TouchDevice, UInt64)?
        for id in candidates {
            let device = devices.first(where: { $0.id == id })
            let forceHardware = button == 0 && device?.kind == .trackpad && device?.supportsForce == true
            let event = recognizers[id]?.beginPhysicalPress(at: now, allowSingleFinger: forceHardware)
            if candidates.count == 1, let event, let device { found = (event, device, id) }
        }
        guard let (gesture, device, id) = found else { if button == 0 { nativePresses.cancel() }; return false }
        var force = gesture; force.kind = .forceClick
        let previewTarget = gymActive ? gymGesture : configuration.bindings.first(where: { $0.id == selectedID })?.gesture
        let forcePreview = previewVisible && frontmostBundleID == Bundle.main.bundleIdentifier && device.kind == selectedDevice && previewTarget == force
        // Any applicable force candidate reserves the press, including ambiguous scopes.
        let forceMapped = configuration.bindings.contains { $0.isEnabled && $0.device == device.kind && $0.gesture == force &&
            $0.keyboardModifiers.matches(stackKeyboard.physicalModifiers) && configuration.applies($0, to: frontmostBundleID) }
        if button == 0 && device.kind == .trackpad && device.supportsForce && (forcePreview || forceMapped) {
            guard isRunning, isAwake, sessionActive, hasAccessibility, configuration.trackpadModuleEnabled,
                  let recognizer = recognizers[id] else { return false }
            nativePresses.begin(PressSnapshot(contacts: NativePressContacts(deviceID: id, contacts: recognizer.contacts,
                corner: gesture.corner, cornerFinger: recognizer.modifierFinger, cornerSize: recognizer.tuning.cornerSize,
                time: lastFrame[id] ?? now, movementTolerance: recognizer.tuning.tapTravel), gesture: gesture, device: device, modifiers: stackKeyboard.physicalModifiers, generation: pressGeneration), at: now)
            return false // macOS needs the native down/up to produce pressure stages.
        }
        guard gesture.allowedFingerCounts().contains(gesture.fingers) else { return false }
        return reportPhysical(gesture, device: device)
    }

    @discardableResult private func reportPhysical(_ gesture: GestureSpec, device: TouchDevice, nativeGeneration: UUID? = nil) -> Bool {
        if gymActive && device.kind == selectedDevice {
            var feedback = DetectionFeedback(); feedback.phase = .recognized; feedback.message = gesture.title; feedback.gesture = gesture
            gymSnapshot.feedback = feedback; touchVisualization.updateFeedback(feedback); recordGymFeedback(feedback)
        }
        return handle(gesture, from: device.kind, supportsHaptics: device.supportsForce, nativeGeneration: nativeGeneration)
    }

    private func recordGymFeedback(_ feedback: DetectionFeedback) {
        guard feedback.phase == .recognized || feedback.phase == .rejected else { return }
        let recognized = feedback.phase == .recognized
        let attempt = GymAttempt(message: feedback.message, matched: recognized && feedback.gesture == gymGesture, recognized: recognized)
        gymAttempts = [attempt] + gymAttempts.prefix(7)
    }

    @discardableResult private func handle(_ gesture: GestureSpec, from device: InputDevice, supportsHaptics: Bool, nativeGeneration: UUID? = nil, temporalGeneration: UUID? = nil) -> Bool {
        guard !synchronizeFocusedApplication(), temporalGeneration.map({ self.temporalGeneration == $0 }) ?? true else { return false }
        let binding = configuration.match(device: device, gesture: gesture, frontmostBundleIdentifier: frontmostBundleID, keyboardModifiers: stackKeyboard.physicalModifiers)
        if device == selectedDevice {
            lastGesture = gesture.title
            lastDetail = gesture.corner == .none ? (binding?.action.title ?? "No matching action") : "\(gesture.corner.title) · \(binding?.action.title ?? "No matching action")"
            lastEventID = UUID()
        }
        if isRunning && configuration.trackpadModuleEnabled && supportsHaptics && configuration.hapticsInPractice && previewVisible && !isCalibrating && device == selectedDevice &&
            (frontmostBundleID == Bundle.main.bundleIdentifier) {
            let selected = configuration.bindings.first { $0.id == selectedID }
            let target = gymActive ? gymGesture : selected?.gesture
            if target == gesture {
                haptics.play((selected?.gesture == gesture ? selected?.hapticPattern : nil) ?? configuration.hapticPattern)
            }
        }
        guard canRunActions, let binding else {
            if canShowGestureToast && binding?.showsToast != false {
                let generation = feedbackGeneration
                let focusGeneration = focusContext.generation
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.synchronizeFocusedApplication()
                    guard nativeGeneration.map({ self.pressGeneration == $0 }) ?? true,
                          temporalGeneration.map({ self.temporalGeneration == $0 }) ?? true, self.feedbackGeneration == generation, self.focusContext.generation == focusGeneration,
                          self.canShowGestureToast, binding?.showsToast != false,
                          self.configuration.match(device: device, gesture: gesture, frontmostBundleIdentifier: self.frontmostBundleID, keyboardModifiers: self.stackKeyboard.physicalModifiers) == binding else { return }
                    self.onToast?(gesture.title)
                }
            }
            return false
        }
        let feedbackGeneration = self.feedbackGeneration
        let focusGeneration = focusContext.generation
        // Return from the event tap before generating input or running AppleScript.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.synchronizeFocusedApplication()
            guard nativeGeneration.map({ self.pressGeneration == $0 }) ?? true,
                          temporalGeneration.map({ self.temporalGeneration == $0 }) ?? true, self.feedbackGeneration == feedbackGeneration, self.canRunActions, self.focusContext.generation == focusGeneration,
                  self.configuration.match(device: device, gesture: gesture, frontmostBundleIdentifier: self.frontmostBundleID, keyboardModifiers: self.stackKeyboard.physicalModifiers) == binding else { return }
            if supportsHaptics { self.haptics.play(binding.hapticPattern ?? self.configuration.hapticPattern) }
            if self.canShowGestureToast && binding.showsToast && binding.action.kind != .showText {
                self.onToast?(gesture.title + " · " + binding.action.title)
            }
            let complete: (Result<String, Error>) -> Void = { [weak self] result in
                switch result {
                case let .success(message): self?.lastDetail = message
                case let .failure(error): self?.errorMessage = error.localizedDescription
                }
            }
            if binding.action.kind == .automation, let id = binding.action.automationID {
                self.onAutomation?(id, complete)
            } else { self.executor.execute(binding.action, completion: complete) }
        }
        return true
    }
}
