import SwiftUI
import HandyToolbeltCore

struct ProductivityView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @ObservedObject var windows: WindowSwitcherModel

    var body: some View {
        ModuleHostingSurface(selection: host.section) { section in
            AnyView(ObservedModuleContent(host: host, trackpad: trackpad, windows: windows, section: section))
        }
        .mainWindowContentSize()
        .graphiteTheme()
        .background(GraphiteWindowChrome())
        .toolbarBackground(Theme.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .hideDefaultToolbarTitle()
        .toolbar {
            ProductivityToolbar(host: host, trackpad: trackpad)
        }
        .disabled(host.isRestarting)
        .alert("HandyToolbelt", isPresented: Binding(get: {
            host.errorMessage != nil || windows.errorMessage != nil || trackpad.errorMessage != nil
        }, set: { if !$0 { clearErrors() } })) {
            if trackpad.settingsNeedRecovery { Button("Back Up & Reset Settings", action: trackpad.recoverSettings) }
            Button("OK", role: .cancel, action: clearErrors)
        } message: { Text(host.errorMessage ?? windows.errorMessage ?? trackpad.errorMessage ?? "") }
    }

    private func clearErrors() { host.errorMessage = nil; windows.errorMessage = nil; trackpad.errorMessage = nil }
}

/// Native hosts retain this observing root, never a snapshot of the selected
/// module. Configuration and restart state stay current across detach/reattach.
private struct ObservedModuleContent: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @ObservedObject var windows: WindowSwitcherModel
    let section: ProductivitySection

    var body: some View {
        Group {
            if section != .settings && section != .snapping && !moduleEnabled(section) {
                stoppedModule()
            } else {
                switch section {
                case .trackpad: ContentView(host: host, model: trackpad)
                case .display: DisplaySettingsView(host: host, trackpad: trackpad)
                case .windows: WindowSettingsView(host: host, trackpad: trackpad, model: windows)
                case .snapping: SnappingSettingsView(host: host, model: host.snapping)
                case .coffee: CoffeeSettingsView(model: host.coffee)
                case .power: PowerSettingsView(model: host.power)
                case .settings: settings
                }
            }
        }
        .graphiteTheme()
        .disabled(host.isRestarting)
    }

    private func moduleEnabled(_ section: ProductivitySection) -> Bool {
        switch section {
        case .trackpad: return trackpad.configuration.trackpadModuleEnabled
        case .windows: return trackpad.configuration.windowSwitcher.isEnabled
        case .snapping: return trackpad.configuration.snappingModuleEnabled
        case .display: return trackpad.configuration.displayModuleEnabled
        case .coffee: return trackpad.configuration.coffeeModuleEnabled
        case .power: return trackpad.configuration.powerModuleEnabled
        case .settings: return true
        }
    }

    private func stoppedModule() -> some View {
        ContentUnavailableView {
            Label("\(section.title) is turned off", systemImage: section.symbol)
        } actions: {
            Button("Open Settings") { host.section = .settings }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settings: some View {
        GlobalSettingsView(host: host, trackpad: trackpad, windows: windows, snapping: host.snapping)
    }


}

private struct WindowSettingsView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @ObservedObject var model: WindowSwitcherModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Switcher").font(.system(size: 27, weight: .semibold))
                    Text("Switch between individual windows across your apps.").font(.callout).foregroundStyle(Theme.secondary)
                }
                if !model.hasAccessibility {
                    HStack {
                        Label("Accessibility access is needed to switch windows.", systemImage: "hand.raised")
                        Spacer()
                        Button("Review Access") { host.revealSettings(.accessibility) }
                    }.font(.callout)
                } else if !model.keyboardAvailable && model.isRunning {
                    HStack {
                        Text("Keyboard monitoring is unavailable. Check access in Settings, then retry.").font(.callout)
                        Button("Retry", action: model.refreshAvailability)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label("Keyboard shortcut", systemImage: "keyboard").font(.headline)
                    Picker("Switch windows", selection: $trackpad.configuration.windowSwitcher.shortcut) {
                        ForEach(WindowShortcut.allCases) { shortcut in Text(shortcut.title).tag(shortcut) }
                    }.frame(maxWidth: 420)
                    Text("Hold the modifier + Tab to choose. Shift moves back. Release to switch; Esc cancels.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                    if trackpad.configuration.windowSwitcher.shortcut == .commandTab {
                        Text("This replaces macOS Command–Tab while Switcher is enabled.").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Label("Chooser", systemImage: "macwindow.on.rectangle").font(.headline)
                    Picker("Layout", selection: $trackpad.configuration.windowSwitcher.layout) {
                        ForEach(WindowLayout.allCases) { layout in Text(layout.title).tag(layout) }
                    }.pickerStyle(.segmented).frame(width: 240)
                    HStack {
                        Toggle("Window previews", isOn: $trackpad.configuration.windowSwitcher.showsPreviews)
                            .help("Minimized, hidden, and unavailable windows show their app icon.")
                        Spacer()
                        RequirementPill(title: "Screen & System Audio Recording", fulfilled: model.previews.hasPermission) { host.revealSettings(.screenRecording) }
                    }
                    if trackpad.configuration.windowSwitcher.showsPreviews {
                        HStack(spacing: 12) {
                            Text("Preview size").frame(width: 90, alignment: .leading)
                            Slider(value: $trackpad.configuration.windowSwitcher.previewScale, in: 0.75...1.5, step: 0.05)
                                .accessibilityLabel("Preview size")
                            Text(trackpad.configuration.windowSwitcher.previewScale, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                        }.frame(maxWidth: 420)
                    }
                    WindowChooserExampleView(layout: trackpad.configuration.windowSwitcher.layout,
                                             showsPreviews: trackpad.configuration.windowSwitcher.showsPreviews,
                                             previewScale: trackpad.configuration.windowSwitcher.previewScale)
                }

            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { model.refreshPreviewPermission() }

    }
}

private struct SnappingSettingsView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var model: WindowSnappingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Snapping").font(.system(size: 27, weight: .semibold))
                    HelpHint("HandyToolbelt snapping is available on macOS 14, or when displays share Spaces. On macOS 15 or later, enabling separate Spaces makes native window tiling available and stops HandyToolbelt drag monitoring. Your preference is kept.")
                }
                Text("Arrange windows by dragging them to screen edges.").font(.callout).foregroundStyle(Theme.secondary)
            }
            if !model.eligible {
                VStack(alignment: .leading, spacing: 8) {
                    Label("HandyToolbelt snapping is automatically disabled", systemImage: "info.circle").font(.headline)
                    Text("Displays have separate Spaces, so macOS window tiling is available. Your Snapping preference is kept.").foregroundStyle(Theme.secondary)
                }
            } else if !model.enabled {
                Text("Snapping is turned off.").foregroundStyle(Theme.secondary)
                Button("Open Settings") { host.section = .settings }
            } else {
                Text("Drag to a side for half the screen, a corner for a quarter, or the top to fill. Release to snap; Esc cancels.")
                    .foregroundStyle(Theme.secondary)
                HStack {
                    Text(model.status).foregroundStyle(Theme.secondary)
                    if !model.hasAccessibility { Button("Review Access") { host.revealSettings(.accessibility) } }
                    else if !model.monitorAvailable { Button("Retry", action: model.refreshAvailability) }
                }
            }
            Spacer()
        }.padding(28).frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear(perform: model.refreshAvailability)
    }
}

struct CoffeeSettingsView: View {
    @ObservedObject var model: CoffeeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Coffee").font(.system(size: 27, weight: .semibold))
                    HelpHint("Coffee uses the native macOS power API; no command is launched.\n\nPrevent idle sleep: equivalent to caffeinate -i.\nKeep display awake: equivalent to caffeinate -d.\n\nManual sleep and lid closure still work.")
                }
                Text("Keep your Mac or display awake while you work.").font(.callout).foregroundStyle(Theme.secondary)
            }
            CoffeeControls(model: model)
            Text("Selections last until you quit HandyToolbelt.").font(.callout).foregroundStyle(Theme.secondary)
            Spacer()
        }.padding(28).frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CoffeeControls: View {
    @ObservedObject var model: CoffeeModel
    var body: some View {
        Toggle("Prevent idle sleep", isOn: Binding(get: { model.preventIdleSleep }, set: { model.set(preventIdleSleep: $0) }))
            .disabled(!model.controlsAvailable)
        Toggle("Keep display awake", isOn: Binding(get: { model.keepDisplayAwake }, set: { model.set(keepDisplayAwake: $0) }))
            .disabled(!model.controlsAvailable)
        if let error = model.errorMessage {
            Text(error).font(.callout).foregroundStyle(Theme.secondary)
            Button("Retry Coffee", action: model.retry)
        }
    }
}

private struct GlobalSettingsView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @ObservedObject var windows: WindowSwitcherModel
    @ObservedObject var snapping: WindowSnappingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var highlighted: ProductivityModel.SettingsTarget?
    @State private var highlightTask: Task<Void, Never>?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Global Settings").font(.system(size: 27, weight: .semibold))
                        Text("Manage enabled tools, macOS permissions, and app preferences.").font(.callout).foregroundStyle(Theme.secondary)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Tools").font(.headline)
                        accessTool("Gestures", module: .trackpad, enabled: trackpad.configuration.trackpadModuleEnabled)
                        Divider()
                        accessTool("Switcher", module: .windows, enabled: trackpad.configuration.windowSwitcher.isEnabled)
                        Divider()
                        accessTool("Snapping", module: .snapping, enabled: trackpad.configuration.snappingModuleEnabled)
                        Divider()
                        plainTool(.display, enabled: $trackpad.configuration.displayModuleEnabled).id(ProductivityModel.SettingsTarget.overlays).modifier(PermissionHighlight(active: highlighted == .overlays))
                        Divider()
                        plainTool(.power, enabled: $trackpad.configuration.powerModuleEnabled)
                        Divider()
                        plainTool(.coffee, enabled: $trackpad.configuration.coffeeModuleEnabled)
                    }
                    Divider()
                    LoginItemSettingsView(model: host.loginItem)
                    Divider()
                    SettingsTransferView(model: host.settingsTransfer, trackpad: trackpad)
                    Divider()
                    Label("macOS Permissions", systemImage: "lock.shield").font(.headline)
                    AccessibilityAccessView(host: host, trackpad: trackpad).id(ProductivityModel.SettingsTarget.accessibility).modifier(PermissionHighlight(active: highlighted == .accessibility))
                    Divider()
                    ScreenRecordingAccessView(host: host, model: windows).id(ProductivityModel.SettingsTarget.screenRecording).modifier(PermissionHighlight(active: highlighted == .screenRecording))
                    Divider()
                    AutomationSettingsView(host: host, trackpad: trackpad, runner: host.automationRunner)
                    if trackpad.hasUnappliedGymChanges {
                        HStack {
                            Text("Trial settings: \(trackpad.devicesWithGymChanges.map(\.title).joined(separator: ", "))").font(.callout).foregroundStyle(Theme.secondary)
                            Button("Review Gym Trials") { trackpad.reviewGymTrials(); host.section = .trackpad }
                        }
                    }
                }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
            .onAppear { isVisible = true; host.refreshPermissions(); reveal(proxy) }
            .onChange(of: host.settingsNavigationID) { _, _ in reveal(proxy) }
            .onDisappear { isVisible = false; highlightTask?.cancel(); highlighted = nil; windows.previewSetup.dismiss() }
        }
        .sheet(isPresented: Binding(get: { windows.previewSetup.isPresented }, set: { if !$0 { windows.previewSetup.dismiss() } })) {
            WindowPreviewSetupView(model: windows.previewSetup, openSettings: windows.openPreviewSettings) { windows.previewSetup.dismiss(); host.restart() }
        }
    }
    private func reveal(_ proxy: ScrollViewProxy) {
        highlightTask?.cancel()
        guard isVisible, host.section == .settings, let target = host.settingsTarget else { return }
        let requestID = host.settingsNavigationID
        highlightTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isVisible, host.section == .settings else { return }
            if reduceMotion { proxy.scrollTo(target, anchor: .center) }
            else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) } }
            highlighted = target
            host.consumeSettingsNavigation(requestID)
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            highlighted = nil
        }
    }
    private func accessTool(_ title: String, module: ProductivitySection, enabled: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: module.symbol).fontWeight(.medium)
                if module == .snapping && !snapping.eligible {
                    Text("Inactive while displays have separate Spaces").font(.caption).foregroundStyle(Theme.secondary)
                }
                if enabled && !trackpad.hasAccessibility { Text("Access required to run").font(.caption).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            RequirementPill(title: "Accessibility", fulfilled: trackpad.hasAccessibility) { host.revealSettings(.accessibility) }
            Toggle(title, isOn: Binding(get: { enabled }, set: { host.setModule(module, enabled: $0) })).labelsHidden().toggleStyle(.switch).fixedSize()
                .disabled(module == .snapping && !snapping.eligible && !enabled)
        }
    }
    private func plainTool(_ module: ProductivitySection, enabled: Binding<Bool>) -> some View {
        HStack { Label(module.title, systemImage: module.symbol).fontWeight(.medium); Spacer(); Toggle(module.title, isOn: enabled).labelsHidden().toggleStyle(.switch).fixedSize() }
    }
}

private struct PermissionHighlight: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.padding(8).background(active ? Theme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6)).padding(-8)
    }
}
