import AppKit
import Combine
import HandyToolbeltCore
import OSLog
import HandyToolbeltControl

enum ProductivitySection: String, CaseIterable, Identifiable {
    case trackpad, windows, snapping, display, coffee, power
    case settings = "general" // Keep restart arguments from earlier builds compatible.
    var id: String { rawValue }
    var title: String { switch self { case .trackpad: return "Gestures"; case .windows: return "Switcher"; case .snapping: return "Snapping"; case .display: return "Overlays"; case .coffee: return "Coffee"; case .power: return "Power"; case .settings: return "Settings" } }
    var symbol: String { switch self { case .trackpad: return "hand.draw"; case .windows: return "macwindow.on.rectangle"; case .snapping: return "rectangle.split.2x2"; case .display: return "text.bubble"; case .coffee: return "cup.and.saucer"; case .power: return "battery.75percent"; case .settings: return "gearshape" } }
}

/// One host owns persistence and the menu item. Modules own and stop their own resources.
final class ProductivityModel: ObservableObject {
    let trackpad: AppModel
    let windows: WindowSwitcherModel
    let snapping = WindowSnappingModel()
    let display: DisplayModel
    let power: PowerModel
    let coffee: CoffeeModel
    let loginItem: LoginItemModel
    let automationRunner: AutomationRunner
    let cliControl: CLIControlModel
    lazy var commands = ControlCommandService(display: display, runner: automationRunner, coffee: coffee, power: power, loginItem: loginItem,
        getConfiguration: { [unowned self] in self.trackpad.configuration },
        saveConfiguration: { [unowned self] value in try self.trackpad.replaceConfiguration(value); self.apply(value) },
        runtimeStatus: { [unowned self] in [
            "accessibility": .bool(self.trackpad.hasAccessibility),
            "trackpadRunning": .bool(self.trackpad.isRunning),
            "inputError": self.trackpad.inputError.map(JSONValue.string) ?? .null,
            "controlAvailable": .bool(self.cliControl.available),
            "switcher": .object([
                "showing": .bool(self.windows.isShowing),
                "loading": .bool(self.windows.isLoading),
                "keyboardAvailable": .bool(self.windows.keyboardAvailable),
                "activationDiagnostics": .array(self.windows.activationDiagnostics.map(JSONValue.string))
            ]),
            "snapping": .object([
                "enabled": .bool(self.snapping.enabled),
                "eligible": .bool(self.snapping.eligible),
                "monitoring": .bool(self.snapping.monitorAvailable),
                "status": .string(self.snapping.status),
                "diagnostics": (try? JSONValue(encoding: self.snapping.diagnostics)) ?? .null
            ])
        ] })
    lazy var settingsTransfer = SettingsTransferModel(
        current: { [unowned self] in try self.trackpad.savedConfigurationForTransfer() },
        gate: { [unowned self] in try self.validateSettingsImportState() },
        authorize: { [unowned self] in try self.trackpad.authorizeModuleTransition(to: $0) },
        apply: { [unowned self] in _ = try self.commands.apply($0, expectedRevision: $1) })
    func validateSettingsImportState() throws {
        let guidance: String?
        if automationRunner.active != nil { guidance = "Wait for the running automation to finish, or cancel it in Automations & CLI, before importing." }
        else if trackpad.activeStackName != nil { guidance = "Release the active gesture stack before importing." }
        else if trackpad.isCalibrating { guidance = "Finish or cancel calibration in Gestures → Gesture Gym before importing." }
        else if trackpad.hasUnappliedGymChanges { guidance = "Apply or revert your trial settings in Gestures → Gesture Gym before importing." }
        else { guidance = nil }
        if let guidance { throw SettingsTransferIO.TransferError.message(guidance) }
    }
    enum SettingsTarget: String { case accessibility, screenRecording, overlays }
    @Published private(set) var settingsTarget: SettingsTarget?
    @Published private(set) var settingsNavigationID = UUID()
    func revealSettings(_ target: SettingsTarget) {
        settingsTarget = target; settingsNavigationID = UUID(); section = .settings
    }
    func consumeSettingsNavigation(_ id: UUID) {
        guard settingsNavigationID == id else { return }
        settingsTarget = nil
    }
    func revealGestureSettings() { trackpad.selectWorkspace(.settings); section = .trackpad }
    func setModule(_ module: ProductivitySection, enabled: Bool) {
        var value = trackpad.configuration
        switch module {
        case .trackpad: value.trackpadModuleEnabled = enabled
        case .windows: value.windowSwitcher.isEnabled = enabled
        case .snapping: value.snappingModuleEnabled = enabled
        case .display: value.displayModuleEnabled = enabled
        case .power: value.powerModuleEnabled = enabled
        case .coffee: value.coffeeModuleEnabled = enabled
        case .settings: return
        }
        do { try trackpad.authorizeModuleTransition(to: value); trackpad.configuration = value }
        catch { revealSettings(.accessibility) }
    }
    @Published var section: ProductivitySection = .trackpad {
        didSet { trackpad.setSelected(section == .trackpad); if section != .display { display.cancelProgressPreview() }; if section != .settings { windows.previewSetup.dismiss() } }
    }
    @Published private(set) var isRestarting = false
    @Published var errorMessage: String?
    private let relaunch = AppRelaunch()
    private var activationObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    init(trackpad: AppModel = AppModel(), windows: WindowSwitcherModel = WindowSwitcherModel(), display: DisplayModel = DisplayModel(), coffee: CoffeeModel = CoffeeModel(), power: PowerModel = PowerModel(), loginItem: LoginItemModel = LoginItemModel(), controlServerEnabled: Bool = true, controlPreferences: CLIControlPreferences = LocalCLIControlPreferences(), controlServerFactory: @escaping CLIControlModel.ServerFactory = { ControlServer(handler: $0) }) {
        self.power = power
        self.loginItem = loginItem
        self.coffee = coffee; self.trackpad = trackpad; self.windows = windows; self.display = display; self.cliControl = CLIControlModel(preferences: controlPreferences, enabled: controlServerEnabled, serverFactory: controlServerFactory)
        self.automationRunner = AutomationRunner(execute: trackpad.executor.execute)
        if trackpad.settingsNeedRecovery { section = .trackpad }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--section"), index + 1 < arguments.count,
           let restored = ProductivitySection(rawValue: arguments[index + 1]), !trackpad.settingsNeedRecovery { section = restored }
        trackpad.setSelected(section == .trackpad)
        trackpad.onWindowAction = { [weak self] action, completion in self?.windows.perform(action, completion: completion) }
        trackpad.onShowText = { [weak display] action in display?.text(action.displayText, duration: action.displayDuration) }
        trackpad.onToast = { [weak display] text in display?.toast(text) }
        trackpad.onDismissToast = { [weak display] in display?.dismissToast() }
        trackpad.onAutomation = { [weak self] id, completion in
            guard let self else { return }
            do { let value = try self.commands.run(id.uuidString); completion(.success("Started " + value.title)) }
            catch { completion(.failure(error)) }
        }
        automationRunner.isAllowed = { [weak self] in guard let self else { return false }; return self.display.available }
        automationRunner.onProgress = { [weak display] progress, begin in
            if begin { display?.begin(progress, lifetime: .automation) } else { display?.update(progress) }
        }
        display.onSessionUnavailable = { [weak automationRunner] in automationRunner?.stop() }
        windows.onChooserVisibility = { [weak self] visible in
            guard let self else { return }
            WindowChooserRouting.visibility(visible, recording: self.trackpad.isRecordingShortcut,
                trackpad: { self.trackpad.windowChooserVisible = $0 }, snapping: self.snapping.setSuspended)
        }
        trackpad.$configuration.receive(on: RunLoop.main).sink { [weak self] config in self?.apply(config) }.store(in: &subscriptions)
        trackpad.$isRecordingShortcut.sink { [weak self] recording in self?.windows.setRecordingShortcut(recording); self?.snapping.setSuspended(recording || (self?.windows.isShowing ?? false)) }.store(in: &subscriptions)
    }
    deinit { power.configure(enabled: false, running: false); coffee.configure(enabled: false, running: false) }
    func start() {
        guard !started else { return }
        started = true; apply(trackpad.configuration)
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissions()
        }
        refreshPermissions()
        cliControl.start { [weak self] request, reply in
            guard let self else { reply(.failure(id: request.id, code: "unavailable", message: "App is stopping.")); return }
            reply(self.commands.handle(request))
        }
    }
    func stop() {
        settingsTransfer.cancelIfActive()
        started = false; power.configure(enabled: trackpad.configuration.powerModuleEnabled, running: false); coffee.configure(enabled: trackpad.configuration.coffeeModuleEnabled, running: false); cliControl.stop(); automationRunner.stop(); display.dismiss(); trackpad.stop(); windows.stop(); snapping.stop()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
    func refreshPermissions() {
        loginItem.refresh()
        trackpad.refreshPermissions(); windows.refreshAvailability(); snapping.refreshAvailability()

    }
    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func startAfterRelaunch(presentsWindow: Bool = true) {
        isRestarting = true
        relaunch.afterPreviousInstanceExits { [weak self] in
            guard let self else { return }
            self.isRestarting = false; self.start()
            Logger(subsystem: "local.HandyToolbelt", category: "Relaunch").notice("Starting modules with \(NSApp.windows.count) windows")
            if presentsWindow {
                NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    func restart() {
        guard !isRestarting else { return }
        guard !trackpad.isCalibrating, !trackpad.hasUnappliedGymChanges else {
            let devices = trackpad.devicesWithGymChanges.map(\.title).joined(separator: " and ")
            errorMessage = trackpad.isCalibrating ? "Finish or cancel training in Gestures → Gesture Gym before restarting."
                : "Apply or revert your \(devices) trial settings before restarting. Choose Review Gym Trials in Settings to find them."
            return
        }
        do { try trackpad.saveBeforeRestart() }
        catch { errorMessage = "Could not save settings before restarting: \(error.localizedDescription)"; return }
        isRestarting = true; stop()
        relaunch.launchReplacement(section: section.rawValue) { [weak self] error in
            guard let self else { return }
            if let error {
                self.isRestarting = false; self.start()
                self.errorMessage = "Could not restart: \(error.localizedDescription)"
            } else { NSApp.terminate(nil) }
        }
    }
    private func apply(_ config: AppConfiguration) {
        power.configure(enabled: config.powerModuleEnabled, running: started)
        display.configure(enabled: config.displayModuleEnabled)
        coffee.configure(enabled: config.coffeeModuleEnabled, running: started)
        snapping.configure(enabled: config.snappingModuleEnabled, running: started)
        guard started else { return }
        if config.trackpadModuleEnabled { trackpad.start() } else { trackpad.stop() }
        windows.configure(config.windowSwitcher)
    }
    private static let windowStackExampleID = UUID(uuidString: "DC611861-7D14-41A5-8B99-676B715F826A")!
    func addWindowStackExample() {
        let id = Self.windowStackExampleID
        if !hasWindowStackExample {
            let modifiers = KeyboardModifier.modifiers(from: trackpad.configuration.windowSwitcher.shortcut.modifiers)
            let next = GestureAction(kind: .shortcut, shortcut: .init(keyCode: 48, modifiers: 0, keyLabel: "⇥"))
            let previous = GestureAction(kind: .shortcut, shortcut: .init(keyCode: 48, modifiers: KeyboardModifier.shift.flag, keyLabel: "⇥"))
            let stack = GestureStack(id: id, name: "Window switching", device: .trackpad, corner: .topLeft,
                keyboardModifiers: .none, isEnabled: false,
                startActions: [.init(kind: .holdModifiers, modifiers: modifiers), .init(action: next)],
                bindings: [.init(gesture: .init(kind: .tipTapLeft), actions: [previous]),
                           .init(gesture: .init(kind: .tipTapRight), actions: [next])])
            trackpad.configuration.stacks.append(stack)
        }
        trackpad.selectDevice(.trackpad)
        trackpad.selectWorkspace(.mappings)
        trackpad.selectedStackID = id
        section = .trackpad
    }
    var hasWindowStackExample: Bool {
        trackpad.configuration.stacks.contains { $0.id == Self.windowStackExampleID }
    }
}

/// Gate only a newly requested enable; revoked access must not rewrite saved intent.
enum ModulePermissionPolicy {
    static func validateTransition(from old: AppConfiguration, to new: AppConfiguration, hasAccessibility: Bool) throws {
        if !hasAccessibility && ((!old.trackpadModuleEnabled && new.trackpadModuleEnabled) || (!old.windowSwitcher.isEnabled && new.windowSwitcher.isEnabled) || (!old.snappingModuleEnabled && new.snappingModuleEnabled)) {
            throw ActionExecutor.ActionError.message("Accessibility access is required to enable Gestures, Switcher, or Snapping. Open Global Settings to review access.")
        }
    }
}


/// Shared host routing used for chooser begin, cancellation and lifecycle cleanup.
enum WindowChooserRouting {
    static func visibility(_ visible: Bool, recording: Bool, trackpad: (Bool) -> Void, snapping: (Bool) -> Void) {
        trackpad(visible)
        snapping(visible || recording)
    }
}
