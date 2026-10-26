import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SuperTrackpadCore

struct ModifierKeysEditor: View {
    @Binding var modifiers: Set<KeyboardModifier>
    var body: some View {
        HStack(spacing: 4) {
            ForEach(KeyboardModifier.allCases) { modifier in
                Toggle(modifier.symbol, isOn: Binding(get: { modifiers.contains(modifier) }, set: {
                    if $0 { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
                }))
                .toggleStyle(ModifierKeyToggleStyle())
                .accessibilityLabel(modifier.title).help(modifier.title)
            }
        }
    }
}

private struct ModifierKeyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 15, weight: configuration.isOn ? .semibold : .regular))
                .foregroundStyle(configuration.isOn ? Theme.accent : Theme.text)
                .frame(width: 32, height: 28)
                .background(configuration.isOn ? Theme.selection : Theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(configuration.isOn ? Theme.accent : Theme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct KeyboardModifiersEditor: View {
    @Binding var requirement: KeyboardModifierRequirement
    private var choice: Binding<Int> {
        Binding(get: { requirement.mode == .any ? 0 : requirement.modifiers.isEmpty ? 1 : 2 }, set: {
            requirement = $0 == 0 ? .any : $0 == 1 ? .none : .init(mode: .exact, modifiers: [.option])
        })
    }
    var body: some View {
        HStack {
            Text("Physical keys").frame(width: 125, alignment: .leading)
            Picker("Physical keyboard modifiers", selection: choice) {
                Text("Any").tag(0); Text("None").tag(1); Text("Custom").tag(2)
            }.labelsHidden().frame(width: 180)
            if requirement.mode == .exact && !requirement.modifiers.isEmpty {
                ModifierKeysEditor(modifiers: $requirement.modifiers)
            }
            HelpHint("Matches the keys you physically hold. Keys held by stack actions do not change this condition.")
            Spacer(minLength: 0)
        }
    }
}

struct GestureActionEditor: View {
    @ObservedObject var model: AppModel
    @Binding var action: GestureAction
    var showsTypePicker = true
    @State private var applicationError: String?
    @State private var isRecording = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTypePicker {
                Picker("Action type", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.frame(maxWidth: 310)
            }
            switch action.kind {
            case .system:
                Picker("Do this", selection: $action.system) { ForEach(SystemAction.allCases) { Text($0.title).tag($0) } }
            case .shortcut:
                ShortcutRecorder(shortcut: $action.shortcut, isRecording: $isRecording).frame(height: 38)
            case .showText:
                TextField("Text to show", text: $action.text, axis: .vertical).lineLimit(2...4)
                    .onChange(of: action.text) { _, value in
                        if value.count > GestureAction.maximumTextLength { action.text = String(value.prefix(GestureAction.maximumTextLength)) }
                    }
                HStack {
                    Picker("Duration", selection: $action.textDuration) {
                        Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0)
                        if ![0.5, 1, 2].contains(action.textDuration) { Text(String(format: "%.1f s", action.displayDuration)).tag(action.textDuration) }
                    }.frame(maxWidth: 220)
                    Button("Preview") { model.previewText(action) }.disabled(!action.isValid)
                }
            case .automation:
                Picker("Automation", selection: $action.automationID) {
                    Text("Choose automation").tag(UUID?.none)
                    ForEach(model.configuration.automations) { Text($0.name).tag(Optional($0.id)) }
                }
                if model.configuration.automations.isEmpty { Text("Create an automation in Settings.").foregroundStyle(Theme.secondary) }
            case .appleScript:
                TextEditor(text: $action.script).font(.system(.body, design: .monospaced))
                    .padding(6).frame(minHeight: 100, maxHeight: 150).scrollContentBackground(.hidden)
                    .background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator)).accessibilityLabel("AppleScript source")
                HelpHint("macOS may request Automation access to apps your script controls.")
            case .openApplication:
                HStack {
                    Text(applicationName).lineLimit(1).truncationMode(.middle)
                    Button("Choose App…", action: chooseApplication)
                }
                if let applicationError { Text(applicationError).foregroundStyle(.orange).font(.caption) }
            }
        }
        .onChange(of: isRecording) { _, value in model.isRecordingShortcut = value }
        .onDisappear { if isRecording { model.isRecordingShortcut = false } }
    }
    private var applicationName: String {
        guard !action.applicationBundleIdentifier.isEmpty else { return "No app selected" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.applicationBundleIdentifier) else { return action.applicationBundleIdentifier }
        return FileManager.default.displayName(atPath: url.path)
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "Choose App"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { applicationError = "This app has no bundle identifier."; return }
        applicationError = nil; action.applicationBundleIdentifier = identifier
    }
}

struct ActionSequenceEditor: View {
    @ObservedObject var model: AppModel
    @Binding var actions: [GestureAction]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(actions.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Action \(index + 1)").font(.subheadline).foregroundStyle(Theme.secondary)
                        Spacer()
                        SequenceControls(index: index, count: actions.count, move: { actions.swapAt(index, $0) }, remove: { actions.remove(at: index) })
                    }
                    GestureActionEditor(model: model, action: $actions[index])
                }
            }
            Button("Add Action", systemImage: "plus") { actions.append(GestureAction()) }
        }
    }
}

struct SequenceControls: View {
    var index: Int
    var count: Int
    var move: (Int) -> Void
    var remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button { move(index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("Move action up")
            Button { move(index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index + 1 >= count).accessibilityLabel("Move action down")
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.accessibilityLabel("Remove action")
        }.buttonStyle(.borderless)
    }
}
