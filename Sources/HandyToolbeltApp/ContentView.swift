import SwiftUI
import HandyToolbeltCore

struct ContentView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var model: AppModel
    @State private var workspaceControlSelection = GestureControlSelection()
    @State private var deviceControlSelection = GestureControlSelection()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Picker("Gestures workspace", selection: Binding(get: { model.workspace }, set: { workspaceControlSelection.schedule($0, host: host, model: model) })) {
                    ForEach(TrackpadWorkspace.allCases) { workspace in Text(workspace.title).tag(workspace) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 500)
                Spacer(minLength: 0)
                if model.workspace == .mappings || model.workspace == .gym {
                    Picker("Device", selection: Binding(get: { model.selectedDevice }, set: { deviceControlSelection.scheduleDevice($0, host: host, model: model) })) {
                        ForEach(InputDevice.allCases) { device in Text(device.title).tag(device) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 210).disabled(model.isCalibrating)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12).background(Theme.chrome)
            Divider()
            if !model.hasAccessibility {
                HStack {
                    Label("Practice works now. Accessibility is needed for actions and clicks.", systemImage: "hand.raised")
                    Spacer()
                    Button("Review Access") { host.revealSettings(.accessibility) }
                }.font(.callout).padding(14)
                Divider()
            } else if !model.clicksAvailable {
                notice("Click detection is unavailable. Check Accessibility and Input Monitoring, then retry.", action: model.reconnect)
            }
            if let error = model.inputError { notice(error, action: model.reconnect) }
            WorkspaceHostingSurface(selection: model.workspace) { workspace in
                AnyView(ObservedWorkspaceContent(host: host, model: model, workspace: workspace))
            }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: model.canRunActions ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(model.canRunActions ? Theme.accent : .secondary)
                Text(model.status)
                Spacer()
                if model.hasUnappliedGymChanges && !model.showGym {
                    Button("Gym has trial settings", action: model.reviewGymTrials).buttonStyle(.link)
                }
            }.font(.caption).padding(.horizontal, 18).padding(.vertical, 9)
        }
        .frame(minWidth: 850, minHeight: 650)
        .onDisappear { workspaceControlSelection.cancel(); deviceControlSelection.cancel() }
    }

    fileprivate var mappingsWorkspace: some View {
        HStack(spacing: 0) {
                sidebar.frame(width: 280)
                Divider()
                VStack(spacing: 0) {
                    if let id = model.selectedID,
                       let binding = model.configuration.bindings.first(where: { $0.id == id }) {
                        BindingEditor(model: model, binding: Binding(get: {
                            model.configuration.bindings.first(where: { $0.id == id }) ?? binding
                        }, set: model.update))
                        .id(id)
                    } else if let id = model.selectedStackID,
                              let stack = model.configuration.stacks.first(where: { $0.id == id }) {
                        if let childID = model.selectedStackChildID,
                           let child = stack.bindings.first(where: { $0.id == childID }) {
                            StackChildEditor(model: model, stack: stack, child: Binding(get: {
                                model.configuration.stacks.first(where: { $0.id == id })?.bindings.first(where: { $0.id == childID }) ?? child
                            }, set: { updated in
                                guard var current = model.configuration.stacks.first(where: { $0.id == id }),
                                      let index = current.bindings.firstIndex(where: { $0.id == childID }) else { return }
                                current.bindings[index] = updated; model.updateStack(current)
                            }), remove: { model.removeStackChild(childID, from: id) }).id(childID)
                        } else {
                            GestureStackEditor(model: model, stack: Binding(get: {
                                model.configuration.stacks.first(where: { $0.id == id }) ?? stack
                            }, set: model.updateStack)).id(id)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Select a gesture", systemImage: "hand.tap")
                        } description: {
                            Text("Add a gesture and choose what it does.")
                        } actions: { Button("Add Gesture", action: model.addBinding) }
                        .frame(maxHeight: .infinity)
                    }
                    Divider()
                    TouchTester(model: model)
                }.frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private var sidebar: some View {
        // Capture values in the nested ForEach closures so stable scope IDs do
        // not hide mapping edits or selection changes from SwiftUI's List diff.
        let bindings = model.visibleBindings
        let stacks = model.visibleStacks
        let configuration = model.configuration
        let selectedID = model.selectedID
        let selectedStackID = model.selectedStackID
        let selectedChildID = model.selectedStackChildID
        let expandedStackIDs = model.expandedStackIDs
        let selection = model.sidebarSelection
        return VStack(alignment: .leading, spacing: 0) {
            Text("Saved mappings").font(.headline).padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
            HStack(spacing: 6) {
                Circle().fill(model.devices.contains(where: { $0.kind == model.selectedDevice }) ? Theme.accent : .secondary).frame(width: 6, height: 6)
                Text(model.deviceSummary).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
            }.padding(.horizontal, 17).padding(.bottom, 14)
            List(selection: Binding<MappingSidebarSelection?>(get: { selection }, set: { model.sidebarSelection = $0 })) {
                ForEach(model.mappingScopeIDs, id: \.self) { scopeID in
                    ForEach(bindings.filter { $0.applicationGroupID == scopeID }) { binding in
                        HStack(alignment: .center, spacing: 12) {
                            GestureGlyph(gesture: binding.gesture).frame(width: 40, height: 28)
                                .foregroundStyle(binding.isEnabled ? Theme.text : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(binding.displayName).fontWeight(.medium).lineLimit(2)
                                Text(binding.action.title).font(.caption).foregroundStyle(Theme.secondary)
                                HStack(spacing: 5) {
                                    if let id = binding.applicationGroupID, let group = configuration.applicationGroups.first(where: { $0.id == id }) { ApplicationGroupIcons(group: group) }
                                    Text(configuration.scopeTitle(for: binding)).font(.caption2).foregroundStyle(Theme.secondary)
                                }
                                if binding.gesture.corner != .none {
                                    Text(binding.gesture.corner.title).font(.caption2).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if configuration.hasConflict(binding) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Conflicting mappings. Actions are blocked where their app scopes overlap.")
                            } else if !binding.isEnabled {
                                Image(systemName: "pause.circle").foregroundStyle(Theme.secondary).help("Mapping disabled")
                            }
                        }.padding(.vertical, 6).tag(MappingSidebarSelection.binding(binding.id))
                        .graphiteSelection(selectedID == binding.id)
                        .contextMenu { Button("Delete Gesture", role: .destructive) { model.removeBinding(binding.id) } }
                    }
                    ForEach(stacks.filter { $0.applicationGroupID == scopeID }) { stack in
                        HStack(spacing: 12) {
                            Button { model.setStackExpanded(!expandedStackIDs.contains(stack.id), id: stack.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: expandedStackIDs.contains(stack.id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                                    Image(systemName: expandedStackIDs.contains(stack.id) ? "folder.fill" : "folder").frame(width: 22)
                                }
                                .frame(width: 46, height: 44)
                                .contentShape(Rectangle())
                            }.buttonStyle(.borderless)
                                .accessibilityLabel(expandedStackIDs.contains(stack.id) ? "Collapse \(stack.name)" : "Expand \(stack.name)")
                                .accessibilityValue(expandedStackIDs.contains(stack.id) ? "Expanded" : "Collapsed")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stack.name).fontWeight(.medium).lineLimit(2)
                                HStack(spacing: 5) {
                                    if let id = stack.applicationGroupID, let group = configuration.applicationGroups.first(where: { $0.id == id }) { ApplicationGroupIcons(group: group) }
                                    Text("\(stack.corner.title) · \(configuration.scopeTitle(for: stack))").font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if stack.isEnabled && (!configuration.stackValidationMessages(for: stack).isEmpty || !configuration.conflictMessages(for: stack).isEmpty) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                            else if !stack.isEnabled { Image(systemName: "pause.circle").foregroundStyle(Theme.secondary) }
                        }.padding(.vertical, 6).tag(MappingSidebarSelection.stack(stack.id)).graphiteSelection(selectedStackID == stack.id && selectedChildID == nil)
                        .contextMenu {
                            Button("Add Gesture") { model.addStackChild(stack.id) }
                                .disabled(stack.bindings.count >= ConfigurationLimits.maximumStackBindings)
                            Button("Delete Stack", role: .destructive) { model.removeStack(stack.id) }
                        }
                        if expandedStackIDs.contains(stack.id) {
                            ForEach(stack.bindings) { child in
                                HStack(spacing: 10) {
                                    GestureGlyph(gesture: child.gesture).frame(width: 32, height: 26)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(child.displayName).fontWeight(.medium).lineLimit(2)
                                        Text(child.actions.map(\.title).joined(separator: " → ")).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if !child.isEnabled { Image(systemName: "pause.circle").foregroundStyle(Theme.secondary) }
                                }.padding(.leading, 26).padding(.vertical, 6).tag(MappingSidebarSelection.child(stack: stack.id, child: child.id))
                                .graphiteSelection(selectedStackID == stack.id && selectedChildID == child.id)
                                .contextMenu { Button("Delete Gesture", role: .destructive) { model.removeStackChild(child.id, from: stack.id) } }
                            }
                            Button("Add Gesture", systemImage: "plus") { model.addStackChild(stack.id) }
                                .buttonStyle(.borderless).padding(.leading, 26).padding(.vertical, 4)
                                .selectionDisabled()
                                .disabled(stack.bindings.count >= ConfigurationLimits.maximumStackBindings)
                        }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(GraphiteListSelection())
            HStack {
                Menu { Button("Add Gesture", action: model.addBinding); Button("Add Gesture Stack", action: model.addStack) } label: { Label("Add", systemImage: "plus") }
                Spacer()
            }.padding(14)
        }.background(Theme.chrome)
    }

    private func notice(_ message: String, action: @escaping () -> Void) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle"); Text(message).font(.callout); Spacer(); Button("Retry", action: action) }
            .padding(12).background(Color.orange.opacity(0.09))
    }
}

struct BindingEditor: View {
    @ObservedObject var model: AppModel
    @Binding var binding: GestureBinding
    @State private var confirmingDeletion = false
    @State private var activationError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(binding.displayName).font(.system(size: 23, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail).help(binding.displayName)

                    }
                    Spacer()
                    Toggle("Active", isOn: Binding(get: { binding.isEnabled }, set: { enabled in
                        var proposed = binding; proposed.isEnabled = enabled
                        var configuration = model.configuration
                        if let index = configuration.bindings.firstIndex(where: { $0.id == proposed.id }) { configuration.bindings[index] = proposed }
                        let errors = configuration.validation().errors
                        if enabled && !errors.isEmpty { activationError = errors.first }
                        else { activationError = nil; binding.isEnabled = enabled }
                    })).toggleStyle(.switch).controlSize(.small).fixedSize()
                    Button(role: .destructive) { confirmingDeletion = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete gesture").accessibilityLabel("Delete gesture")
                    Button("Practice in Gym") { model.practice(binding.gesture) }.controlSize(.small).fixedSize()
                }
                HStack {
                    Text("Name").frame(width: 125, alignment: .leading)
                    TextField(binding.gesture.title, text: Binding(get: { binding.name }, set: {
                        binding.name = String($0.prefix(ConfigurationLimits.maximumNameLength))
                    }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Mapping name")
                    HelpHint("Optional label for the saved mapping and gesture toast. Leave blank to use the gesture name.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Works in").frame(width: 125, alignment: .leading)
                        Picker("Works in", selection: $binding.applicationGroupID) {
                            Text("Everywhere").tag(nil as UUID?)
                            ForEach(model.configuration.applicationGroups) { group in
                                Text(group.displayName).tag(Optional(group.id))
                            }
                            if let id = binding.applicationGroupID,
                               !model.configuration.applicationGroups.contains(where: { $0.id == id }) {
                                Text("Missing app group").tag(Optional(id))
                            }
                        }.labelsHidden().frame(width: 230).help(scopeHelp)
                        Button("Edit Groups…") { model.showApplicationGroups(selecting: binding.applicationGroupID) }.fixedSize()
                        Spacer(minLength: 0)
                    }
                    if let id = binding.applicationGroupID, model.configuration.applicationGroups.first(where: { $0.id == id })?.applications.isEmpty != false {
                        Text(scopeHelp).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Gesture").font(.headline); HelpHint(gestureHelp) }
                    HStack {
                        Text("Movement").frame(width: 125, alignment: .leading)
                        Picker("Movement", selection: Binding(get: { binding.gesture.kind }, set: {
                            binding.gesture.kind = $0
                            binding.gesture = binding.gesture.normalized()
                        })) {
                            ForEach(GestureKind.allCases) { kind in Text(kind.title).tag(kind) }
                        }.labelsHidden().frame(width: 230)
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Text(binding.gesture.kind.isAnchored && !([GestureKind.tipTapMiddle, .doubleTipTapMiddle].contains(binding.gesture.kind)) ? "Resting fingers" : "Fingers")
                            .frame(width: 125, alignment: .leading)
                        GestureFingerPicker(gesture: $binding.gesture).labelsHidden().frame(width: 230)
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Text("Corner modifier").frame(width: 125, alignment: .leading)
                        Picker("Corner modifier", selection: Binding(get: { binding.gesture.corner }, set: {
                            binding.gesture.corner = $0
                            binding.gesture = binding.gesture.normalized()
                        })) {
                            ForEach(Corner.allCases) { corner in Text(corner.title).tag(corner) }
                        }.labelsHidden().frame(width: 230)
                        Spacer(minLength: 0)
                    }
                    if binding.gesture.corner != .none {
                        Text("Hold \(binding.gesture.corner.title.lowercased()); use the other fingers for the gesture.")
                            .font(.callout).foregroundStyle(Theme.secondary)
                    }
                }
                if binding.gesture.kind == .forceClick {
                    Text(model.forceClickCapability(for: binding.device).message()).font(.caption).foregroundStyle(Theme.secondary)
                }
                KeyboardModifiersEditor(requirement: $binding.keyboardModifiers)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Action").font(.headline)
                    GestureActionEditor(model: model, action: $binding.action)
                }
                ForEach(model.configuration.conflictMessages(for: binding), id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if let activationError { Text(activationError).font(.callout).foregroundStyle(.orange) }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Per-gesture overrides").font(.headline)
                    HStack {
                        Text("Haptic feedback").frame(width: 125, alignment: .leading)
                        HapticPatternPicker(model: model, selection: $binding.hapticPattern,
                                            allowsDefault: true, eligible: binding.device == .trackpad)
                        Spacer(minLength: 0)
                    }
                    if binding.device == .magicMouse { Text("Magic Mouse has no haptics.").font(.caption).foregroundStyle(Theme.secondary) }
                    Toggle("Show gesture toast", isOn: $binding.showsToast)
                        .disabled(binding.action.kind == .showText || !model.configuration.visualFeedbackEnabled || !model.configuration.displayModuleEnabled)
                        .opacity(binding.action.kind == .showText || !model.configuration.visualFeedbackEnabled || !model.configuration.displayModuleEnabled ? 0.5 : 1)
                    if binding.action.kind == .showText {
                        Text("Show Text displays its own message instead of a gesture toast.").font(.caption).foregroundStyle(Theme.secondary)
                    } else if !model.configuration.visualFeedbackEnabled && !model.configuration.displayModuleEnabled {
                        Text("Enable gesture toasts in Gestures → Settings and Overlays in Global Settings.").font(.caption).foregroundStyle(Theme.secondary)
                    } else if !model.configuration.visualFeedbackEnabled {
                        Text("Enable gesture toasts in Gestures → Settings.").font(.caption).foregroundStyle(Theme.secondary)
                    } else if !model.configuration.displayModuleEnabled {
                        Text("Enable Overlays in Global Settings.").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                if binding.gesture.kind.isSwipe {
                    HelpHint("Turn off the matching swipe in System Settings → Trackpad. macOS gestures are not blocked by this app.")
                }

            }.padding(24)
        }
        .confirmationDialog("Delete this gesture mapping?", isPresented: $confirmingDeletion) {
            Button("Delete Gesture", role: .destructive) { model.removeBinding(binding.id) }
        }
        .onDisappear { if model.isRecordingShortcut { model.isRecordingShortcut = false } }
    }

    private var scopeHelp: String {
        guard let id = binding.applicationGroupID else { return "Used unless the focused app has a matching group gesture." }
        guard let group = model.configuration.applicationGroups.first(where: { $0.id == id }) else {
            return "This group is missing. Choose another scope to enable this mapping."
        }
        if group.applications.isEmpty { return "This group is empty. Add apps to activate this mapping." }
        return "Only while an app in \(group.displayName) is focused. Overrides the same Everywhere gesture."
    }

    private var conflictHelp: String {
        let apps = model.configuration.conflictingApplications(for: binding)
        return apps.isEmpty ? "Another Everywhere mapping uses this gesture. Disable one or change its gesture or scope." :
            "This gesture has overlapping group mappings in \(apps.joined(separator: ", ")). No action runs in those apps until the overlap is resolved."
    }

    private var gestureHelp: String {
        binding.gesture.teachingInstruction
    }
}

struct TouchTester: View {
    @ObservedObject var model: AppModel
    @State private var howTo = true
    private var example: GestureSpec? {
        if let stack = model.configuration.stacks.first(where: { $0.id == model.selectedStackID }) {
            var gesture = (stack.bindings.first(where: { $0.id == model.selectedStackChildID }) ?? stack.bindings.first)?.gesture ?? GestureSpec(kind: .tap, fingers: 1)
            gesture.corner = stack.corner
            return gesture
        }
        return model.configuration.bindings.first(where: { $0.id == model.selectedID })?.gesture
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gesture preview").font(.headline)
                Spacer()
                Picker("Preview mode", selection: $howTo) { Text("How to").tag(true); Text("Live").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 155)
            }
            if howTo, let example {
                GestureHowTo(gesture: example, handAngle: model.configuration.tuning(for: model.selectedDevice).handAngleDegrees)
                    .frame(minHeight: 98)
            } else {
            HStack(spacing: 22) {
                TouchSurface(visualization: model.touchVisualization,
                             cornerSize: model.configuration.tuning(for: model.selectedDevice).cornerSize)
                    .frame(width: 170, height: 98)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.lastGesture).font(.title3).fontWeight(.medium)
                        .contentTransition(.numericText())
                    Text(model.lastDetail).font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.activeCorner != .none {
                        Label(model.activeCorner.title, systemImage: "pin.fill").font(.caption).foregroundStyle(Theme.accent)
                    } else {
                        Text("\(model.contacts.count) \(model.contacts.count == 1 ? "finger" : "fingers") touching").font(.caption).foregroundStyle(Theme.secondary)
                    }
                    PressFeedbackIndicator(visualization: model.touchVisualization, compact: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Theme.chrome)
    }
}

struct TouchSurface: View {
    @ObservedObject var visualization: TouchVisualization
    private var contacts: [Contact] { visualization.frame.contacts }
    private var corner: Corner { visualization.frame.modifier }
    private var modifierFinger: Int? { visualization.frame.modifierFinger }
    var cornerSize: Double = 0.22
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let outline = Path(roundedRect: bounds, cornerRadius: 12)
            context.fill(outline, with: .color(Theme.field))
            context.stroke(outline, with: .color(Theme.separator), lineWidth: 1)
            if corner != .none {
                let rect = CGRect(x: size.width * (corner == .topLeft || corner == .bottomLeft ? 0 : 1 - cornerSize),
                                  y: size.height * (corner == .topLeft || corner == .topRight ? 0 : 1 - cornerSize),
                                  width: size.width * cornerSize, height: size.height * cornerSize)
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Theme.accent.opacity(0.15)))
            }
            if contacts.isEmpty {
                context.draw(Text(Image(systemName: "hand.draw")).font(.system(size: 24, weight: .light)).foregroundColor(Theme.secondary.opacity(0.6)), at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            for contact in contacts {
                let point = CGPoint(x: contact.position.x * size.width, y: (1 - contact.position.y) * size.height)
                let diameter = 26 + 40 * contact.pressureSize
                let ring = Path(ellipseIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter))
                context.fill(ring, with: .color(visualization.press.kind.color.opacity(0.22)))
                context.stroke(ring, with: .color(visualization.press.kind.color.opacity(0.65)), lineWidth: 1)
                let inner = 12 + 12 * contact.pressureSize
                context.fill(Path(ellipseIn: CGRect(x: point.x - inner / 2, y: point.y - inner / 2, width: inner, height: inner)),
                             with: .color(visualization.press.kind.color))
                if modifierFinger == contact.id {
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - 11.5, y: point.y - 11.5, width: 23, height: 23)), with: .color(Theme.accent), lineWidth: 2)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(PressureCaptureSurface())
            .background(TouchDisplayClock(visualization: visualization))
            .help("Firmer touches grow faster. Green means click; purple means force click. Keep the pointer over this surface for force-click feedback.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Touch surface, \(contacts.count) fingers. \(corner == .none ? "No corner held" : corner.title)")
    }
}

private struct ObservedWorkspaceContent: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var model: AppModel
    let workspace: TrackpadWorkspace
    var body: some View {
        Group {
            switch workspace {
            case .gym: GestureGymView(model: model)
            case .groups: ApplicationGroupsView(model: model)
            case .settings: GestureSettingsView(host: host, model: model, display: host.display)
            case .mappings: ContentView(host: host, model: model).mappingsWorkspace
            }
        }.graphiteTheme().disabled(host.isRestarting)
    }
}

struct GestureSettingsView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var model: AppModel
    @ObservedObject var display: DisplayModel
    @State private var previewError: String?

    private var previewUnavailableReason: String? {
        if !display.enabled { return "Enable Overlays in Global Settings to preview a toast." }
        if !display.canDisplay { return "Toast previews are unavailable while the session is inactive." }
        if display.progress.latest != nil { return "Wait for the current progress display to finish before previewing a toast." }
        return nil
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Gesture Settings").font(.system(size: 27, weight: .semibold))
                HStack {
                    Toggle("Gesture toasts", isOn: $model.configuration.visualFeedbackEnabled)
                    HelpHint("Automatically show a brief toast when a gesture is recognized or a mapped action is accepted. Requires Overlays and the mapping’s Show gesture toast setting. Show Text actions display their own message.")
                    Spacer()
                    RequirementPill(title: "Overlays", fulfilled: model.configuration.displayModuleEnabled) { host.revealSettings(.overlays) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Preview Toast") {
                        previewError = host.display.toast("Tip-tap left · Previous browser tab") ? nil : (previewUnavailableReason ?? "The toast could not be displayed. Try again.")
                    }
                    .disabled(previewUnavailableReason != nil)
                    if let message = previewUnavailableReason ?? previewError {
                        Text(message).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Divider()
                HapticSettingsView(model: model)
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

/// Native segmented Picker bindings may run inside SwiftUI's update transaction.
/// Keep their model mutation outside it, coalescing only control-originated choices.
final class GestureControlSelection {
    private var revision: UInt64 = 0
    func cancel() { revision &+= 1 }
    func schedule(_ next: TrackpadWorkspace, host: ProductivityModel, model: AppModel) {
        let previous = model.workspace
        enqueue(host: host, model: model, isCurrent: { $0.workspace == previous }) { $0.selectWorkspace(next) }
    }
    func scheduleDevice(_ next: InputDevice, host: ProductivityModel, model: AppModel) {
        let previous = model.selectedDevice
        enqueue(host: host, model: model, isCurrent: {
            $0.selectedDevice == previous && !$0.isCalibrating && ($0.workspace == .mappings || $0.workspace == .gym)
        }) { $0.selectDevice(next) }
    }
    private func enqueue(host: ProductivityModel, model: AppModel,
                         isCurrent: @escaping (AppModel) -> Bool, apply: @escaping (AppModel) -> Void) {
        cancel()
        let request = revision
        DispatchQueue.main.async { [weak self, weak host, weak model] in
            guard let self, self.revision == request, let host, let model,
                  host.section == .trackpad, model.isSelected,
                  model.configuration.trackpadModuleEnabled, isCurrent(model) else { return }
            apply(model)
        }
    }
}
