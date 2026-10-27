import SwiftUI
import HandyToolbeltCore

struct GestureStackEditor: View {
    @ObservedObject var model: AppModel
    @Binding var stack: GestureStack
    @State private var activationAttempted = false
    @State private var confirmingDeletion = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("Stack name", text: Binding(get: { stack.name }, set: { stack.name = String($0.prefix(ConfigurationLimits.maximumNameLength)) })).textFieldStyle(.plain).font(.system(size: 23, weight: .semibold))
                    Toggle("Active", isOn: Binding(get: { stack.isEnabled }, set: activate))
                        .toggleStyle(.switch).controlSize(.small).fixedSize()
                    Button(role: .destructive) { confirmingDeletion = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete stack").accessibilityLabel("Delete stack")
                }
                Button("Add Gesture", systemImage: "plus") { model.addStackChild(stack.id) }.fixedSize()
                    .disabled(stack.bindings.count >= ConfigurationLimits.maximumStackBindings)
                if stack.isEnabled || activationAttempted {
                    ForEach(validationMessages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Text("Hold corner").frame(width: 125, alignment: .leading)
                    Picker("Hold corner", selection: $stack.corner) {
                        ForEach(Corner.allCases.filter { $0 != .none }) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 230)
                }
                HStack {
                    Text("Works in").frame(width: 125, alignment: .leading)
                    Picker("Works in", selection: $stack.applicationGroupID) {
                        Text("Everywhere").tag(UUID?.none)
                        ForEach(model.configuration.applicationGroups) { Text($0.displayName).tag(Optional($0.id)) }
                        if let id = stack.applicationGroupID, !model.configuration.applicationGroups.contains(where: { $0.id == id }) {
                            Text("Missing app group").tag(Optional(id))
                        }
                    }.labelsHidden().frame(width: 230)
                    Button("Edit Groups…") { model.showApplicationGroups(selecting: stack.applicationGroupID) }
                }
                if let id = stack.applicationGroupID, model.configuration.applicationGroups.first(where: { $0.id == id })?.applications.isEmpty != false {
                    Text("Choose an app group containing apps to activate this stack.").font(.caption).foregroundStyle(.orange)
                }
                KeyboardModifiersEditor(requirement: $stack.keyboardModifiers)
                Divider()
                HStack { Text("When held").font(.headline); HelpHint("Actions run in order when the corner activates. Held keys are released automatically whenever the stack ends.") }
                ForEach(stack.startActions.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Start action \(index + 1)", selection: Binding<String>(get: {
                                stack.startActions[index].kind == .holdModifiers ? "holdKeys" : stack.startActions[index].action.kind.rawValue
                            }, set: { value in
                                if let kind = ActionKind(rawValue: value) {
                                    stack.startActions[index].action.kind = kind
                                    stack.startActions[index].kind = .action
                                } else { stack.startActions[index].kind = .holdModifiers }
                            })) {
                                Text("Hold keys").tag("holdKeys")
                                ForEach(ActionKind.allCases) { Text($0.title).tag($0.rawValue) }
                            }.frame(width: 270)
                            Spacer()
                            SequenceControls(index: index, count: stack.startActions.count,
                                move: { stack.startActions.swapAt(index, $0) }, remove: { stack.startActions.remove(at: index) })
                        }
                        if stack.startActions[index].kind == .holdModifiers { ModifierKeysEditor(modifiers: $stack.startActions[index].modifiers) }
                        else { GestureActionEditor(model: model, action: $stack.startActions[index].action, showsTypePicker: false) }
                    }
                }
                Menu("Add Start Action", systemImage: "plus") {
                    Button("Hold Keys") { stack.startActions.append(.init(kind: .holdModifiers)) }
                    Button("Action") { stack.startActions.append(.init(action: .init())) }
                }.fixedSize()
                Divider()
                Text("When released").font(.headline)
                Label("Release all held keys", systemImage: "keyboard").foregroundStyle(Theme.secondary)
                ActionSequenceEditor(model: model, actions: $stack.releaseActions)

            }.padding(24)
        }
        .confirmationDialog("Delete this gesture stack?", isPresented: $confirmingDeletion) {
            Button("Delete Stack", role: .destructive) { model.removeStack(stack.id) }
        }
        .onDisappear { if model.isRecordingShortcut { model.isRecordingShortcut = false } }
    }
    private var validationMessages: [String] {
        var proposed = stack; proposed.isEnabled = true
        return Array(Set(model.configuration.stackValidationMessages(for: proposed) + model.configuration.conflictMessages(for: proposed))).sorted()
    }
    private func activate(_ enabled: Bool) {
        if enabled && !validationMessages.isEmpty { activationAttempted = true }
        else { activationAttempted = false; stack.isEnabled = enabled }
    }
}

struct StackChildEditor: View {
    @ObservedObject var model: AppModel
    var stack: GestureStack
    @Binding var child: GestureStackBinding
    var remove: () -> Void
    @State private var activationAttempted = false
    @State private var confirmingDeletion = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(child.displayName).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Toggle("Active", isOn: Binding(get: { child.isEnabled }, set: { enabled in
                        if enabled && !activationMessages.isEmpty { activationAttempted = true }
                        else { activationAttempted = false; child.isEnabled = enabled }
                    })).toggleStyle(.switch).controlSize(.small).fixedSize()
                    Button(role: .destructive) { confirmingDeletion = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove gesture")
                }
                HStack {
                    Text("Name").frame(width: 125, alignment: .leading)
                    TextField(child.gesture.title, text: Binding(get: { child.name }, set: { child.name = String($0.prefix(ConfigurationLimits.maximumNameLength)) }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Mapping name")
                }
                Label("While holding \(stack.name)", systemImage: "folder")
                    .font(.callout).foregroundStyle(Theme.secondary)
                Text("\(stack.corner.title) · \(model.configuration.scopeTitle(for: stack))").font(.caption).foregroundStyle(Theme.secondary)
                Divider()
                HStack { Text("Gesture").font(.headline); HelpHint("Use your other fingers while holding the folder’s corner. The corner finger is additional. Normal mappings pause while the folder is held.") }
                HStack {
                    Text("Movement").frame(width: 125, alignment: .leading)
                    Picker("Movement", selection: Binding(get: { child.gesture.kind }, set: {
                        child.gesture.kind = $0; child.gesture = child.gesture.normalized(isStackChild: true)
                    })) { ForEach(GestureKind.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 230)
                    Spacer(minLength: 0)
                }
                HStack {
                    Text(child.gesture.kind.isAnchored && !([GestureKind.tipTapMiddle, .doubleTipTapMiddle].contains(child.gesture.kind)) ? "Resting fingers" : "Fingers")
                        .frame(width: 125, alignment: .leading)
                    GestureFingerPicker(gesture: $child.gesture, isStackChild: true).labelsHidden().frame(width: 230)
                    Spacer(minLength: 0)
                }
                if child.gesture.kind == .forceClick {
                    Text(model.forceClickCapability(for: stack.device).message()).font(.caption).foregroundStyle(Theme.secondary)
                }
                KeyboardModifiersEditor(requirement: $child.keyboardModifiers)
                Divider()
                Text("Actions").font(.headline)
                ActionSequenceEditor(model: model, actions: $child.actions)
                if child.isEnabled || activationAttempted {
                    ForEach(activationMessages, id: \.self) { message in
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }.padding(24)
        }
        .confirmationDialog("Delete this gesture?", isPresented: $confirmingDeletion) {
            Button("Delete Gesture", role: .destructive, action: remove)
        }
        .onDisappear { if model.isRecordingShortcut { model.isRecordingShortcut = false } }
    }
    private var activationMessages: [String] {
        var proposed = stack; proposed.isEnabled = true
        if let index = proposed.bindings.firstIndex(where: { $0.id == child.id }) { proposed.bindings[index].isEnabled = true }
        return Array(Set(model.configuration.stackValidationMessages(for: proposed) + model.configuration.conflictMessages(for: proposed))).sorted()
    }

}
