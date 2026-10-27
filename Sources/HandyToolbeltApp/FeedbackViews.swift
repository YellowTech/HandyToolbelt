import AppKit
import SwiftUI
import Combine
import HandyToolbeltCore

extension PressKind {
    var color: Color {
        switch self { case .touch: return Theme.accent; case .click: return .green; case .forceClick: return .purple }
    }
    var symbol: String {
        switch self { case .touch: return "hand.point.up.left"; case .click: return "circle.inset.filled"; case .forceClick: return "circle.dotted.circle.fill" }
    }
}

/// Position-only display frames do not invalidate this readout.
struct PressFeedbackIndicator: View {
    @ObservedObject private var readout: TouchPressReadout
    init(visualization: TouchVisualization, compact: Bool = false) {
        readout = visualization.pressReadout
        self.compact = compact
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false
    private var press: PressDisplay { readout.state.press }
    private var isTouching: Bool { readout.state.isTouching }
    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            ZStack {
                if press.pulseProgress < 1 {
                    Circle().stroke(press.kind.color.opacity((1 - press.pulseProgress) * 0.8), lineWidth: 2)
                        .frame(width: diameter + (reduceMotion ? 0 : 20 * press.pulseProgress),
                               height: diameter + (reduceMotion ? 0 : 20 * press.pulseProgress))
                }
                Image(systemName: press.kind.symbol).font(.system(size: compact ? 14 : 23))
                    .foregroundStyle(press.kind == .touch && !isTouching ? Theme.secondary : press.kind.color)
            }.frame(width: compact ? 26 : 48, height: compact ? 26 : 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(press.kind == .touch ? (isTouching ? "Touching" : "No touch") : press.kind.title)
                    .font(compact ? .caption : .callout).fontWeight(press.kind == .touch ? .regular : .semibold)

            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Press feedback")
        .accessibilityValue(press.kind == .touch ? (isTouching ? "Touching" : "No press") : press.kind.title)
    }
    private var diameter: Double { compact ? 17 : 30 }
}

struct HapticSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Haptic feedback").font(.headline); HelpHint("Requires a Force Touch trackpad. Native patterns provide feedback for matched gestures and accepted calibration samples. Mappings can override this default.") }
            HapticPatternPicker(model: model, selection: Binding(
                get: { model.configuration.hapticPattern },
                set: { if let pattern = $0 { model.configuration.hapticPattern = pattern } }
            ))
            Toggle("Feedback while practicing", isOn: $model.configuration.hapticsInPractice)
                .font(.callout)
            if !model.hapticsAvailable {
                Text(model.configuration.trackpadModuleEnabled ? "Connect a Force Touch trackpad to test." : "Enable Gestures to test haptic feedback.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Only the picker binding setter schedules selection previews, so restoring a
/// cached view or applying external configuration never starts playback.
/// Navigation publishers also cancel previews in detached hosting views.
struct HapticPatternPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selection: HapticPattern?
    var allowsDefault = false
    var eligible = true
    var pickerWidth: CGFloat = 230
    private var pattern: HapticPattern { selection ?? model.configuration.hapticPattern }
    @State private var pending: Task<Void, Never>?

    private var canTest: Bool {
        eligible && pattern != .off && model.hapticsAvailable &&
        model.configuration.trackpadModuleEnabled && model.inputSessionAvailable && model.isSelected
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker(allowsDefault ? "Mapping haptic" : "Default haptic", selection: Binding(
                get: { selection },
                set: { selected in
                    // Write first: configuration publishers cancel older previews
                    // synchronously, then this explicit user choice starts its own.
                    selection = selected
                    schedule(selected ?? model.configuration.hapticPattern)
                }
            )) {
                if allowsDefault {
                    Text("Default (\(model.configuration.hapticPattern.title))").tag(nil as HapticPattern?)
                }
                ForEach(HapticPattern.allCases) { pattern in
                    Text(pattern.title).tag(Optional(pattern))
                }
            }.labelsHidden().frame(width: pickerWidth)
            Button { schedule(pattern) } label: {
                Text(pending != nil ? "Waiting…" : "Test").frame(width: 70)
            }
            .disabled(!canTest || pending != nil)
            .help("Preview plays after 0.4 seconds. Rest a finger lightly on the Force Touch trackpad to feel the selected pattern.")
        }
        .onDisappear(perform: cancel)
        .onChange(of: eligible) { _, _ in cancel() }
        // onChange may be deferred by detached, cached NSHostingViews. These
        // subscriptions invalidate the task at the navigation or settings event.
        .onReceive(model.$workspace.dropFirst()) { _ in cancel() }
        .onReceive(model.$isSelected.dropFirst()) { _ in cancel() }
        .onReceive(model.$selectedID.dropFirst()) { _ in cancel() }
        .onReceive(model.$selectedDevice.dropFirst()) { _ in cancel() }
        .onReceive(model.$configuration.dropFirst()) { _ in cancel() }
        .onReceive(model.$devices.dropFirst()) { _ in cancel() }
        .onReceive(model.$isRunning.dropFirst()) { _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancel() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in cancel() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in cancel() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in cancel() }
    }

    private func schedule(_ previewPattern: HapticPattern) {
        cancel()
        guard canTest, previewPattern != .off, NSApp.isActive else { return }
        let workspace = model.workspace
        let device = model.selectedDevice
        let mappingID = model.selectedID
        let defaultPattern = model.configuration.hapticPattern
        let mappingPattern = model.configuration.bindings.first { $0.id == mappingID }?.hapticPattern
        let started = Date()
        pending = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
            } catch { return }
            pending = nil
            // Read live model state here as detached hosts can defer view updates.
            // The deadline also prevents a suspended app from playing on resume.
            guard canTest, NSApp.isActive, Date().timeIntervalSince(started) < 1.4,
                  model.workspace == workspace, model.selectedDevice == device,
                  model.selectedID == mappingID,
                  model.configuration.hapticPattern == defaultPattern,
                  model.configuration.bindings.first(where: { $0.id == mappingID })?.hapticPattern == mappingPattern
            else { return }
            model.testHaptics(previewPattern)
        }
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Gives the preview surface an explicit two-stage pressure behavior. This affects
/// only presses over this view; ordinary app controls retain their native behavior.
struct PressureCaptureSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CaptureView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class CaptureView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
        override func pressureChange(with event: NSEvent) {}
    }
}
