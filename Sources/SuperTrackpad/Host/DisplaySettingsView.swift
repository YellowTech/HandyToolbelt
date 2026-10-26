import SwiftUI
import SuperTrackpadCore
import SuperToolsControl

struct DisplaySettingsView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @State private var text = "Ready"
    @State private var duration = GestureAction.defaultTextDuration
    @State private var previewError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overlays").font(.system(size: 27, weight: .semibold))
                    Text("Show messages and automation progress over other apps.").font(.callout).foregroundStyle(Theme.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Centered text").font(.headline)
                    Text("Show Text actions display a short message in the center of the screen.").font(.callout).foregroundStyle(Theme.secondary)
                    TextField("Text to show", text: $text, axis: .vertical).lineLimit(2...4)
                        .onChange(of: text) { _, value in text = String(value.prefix(GestureAction.maximumTextLength)) }
                    HStack {
                        Picker("Duration", selection: $duration) {
                            Text(String(format: "%.1f s", GestureAction.defaultTextDuration)).tag(GestureAction.defaultTextDuration)
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                        }.frame(width: 220)
                        Button("Preview Text") { host.display.text(text, duration: duration) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Gesture toasts").font(.headline)
                    Text("Optional toasts show recognized gestures and their mapped actions at the top of the screen. Enable them in Gestures → Settings.").font(.callout).foregroundStyle(Theme.secondary)
                    HStack {
                        Button("Preview Toast") { host.display.toast("Tip-tap left · Previous browser tab") }
                        Button("Gesture Settings") { host.revealGestureSettings() }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Progress").font(.headline)
                    Text("Automations and CLI workflows show named steps, completion, and errors at the top of the screen. Progress takes precedence over gesture toasts.").font(.callout).foregroundStyle(Theme.secondary)
                    Button("Preview Progress Demo") {
                        previewError = host.display.previewProgress() ? nil : "Wait for the current progress session to finish before previewing."
                    }
                    Text("A short visual demo; no actions run.").font(.caption).foregroundStyle(Theme.secondary)
                    if let previewError { Text(previewError).font(.callout).foregroundStyle(.orange) }
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }
        .onDisappear { host.display.cancelProgressPreview() }
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @ObservedObject var runner: AutomationRunner
    @State private var editing = false
    @State private var json = ""
    @State private var editRevision = ""
    @State private var message: String?
    private func decodedAutomations() throws -> [SavedAutomation] {
        let value = try JSONDecoder().decode(SuperToolsControl.JSONValue.self, from: Data(json.utf8))
        let root = try ControlSchema.value()
        let shape: SuperToolsControl.JSONValue = .object(["type": .string("array"), "items": .object(["$ref": .string("#/$defs/Automation")])])
        let errors = JSONShapeValidation.errors(value, schema: shape, root: root, path: "automations")
        guard errors.isEmpty else { throw ActionExecutor.ActionError.message(errors.joined(separator: " ")) }
        return try value.decode([SavedAutomation].self)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Automations & CLI", systemImage: "terminal").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(trackpad.configuration.automations) { automation in
                    HStack {
                        Text(automation.name)
                        Text("\(automation.steps.count) steps").font(.caption).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Run") {
                            do { _ = try host.commands.run(automation.id.uuidString); message = nil }
                            catch { message = error.localizedDescription }
                        }.disabled(runner.active != nil)
                    }
                }
                if let active = runner.active {
                    HStack {
                        Text("\(active.title) · \(active.state.rawValue.capitalized) · \(active.completedCount)/\(active.steps.count)")
                        Spacer()
                        Button("Cancel") { runner.cancel(active.id) }.disabled(active.state == .cancelling)
                    }
                    if let note = active.message { Text(note).font(.caption).foregroundStyle(Theme.secondary) }
                } else if let last = runner.history.last {
                    Text("\(last.title) · \(last.state.rawValue.capitalized)").font(.callout).foregroundStyle(Theme.secondary)
                    if let note = last.message { Text(note).font(.caption).foregroundStyle(Theme.secondary) }
                }
                HStack {
                    Button("Edit Automations…") {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        do { json = String(decoding: try encoder.encode(trackpad.configuration.automations), as: UTF8.self); editRevision = try trackpad.configuration.revision(); message = nil; editing = true }
                        catch { message = error.localizedDescription }
                    }
                    Button("Copy CLI Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/handytoolbelt").path, forType: .string)
                    }
                }
                if let error = host.controlError { Text(error).font(.callout).foregroundStyle(.orange) }
                if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            }.padding(.top, 12)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Automations").font(.title2)
                Text("Edit the saved automation array. Each step has a name and either an action or a delay in seconds.").font(.callout).foregroundStyle(Theme.secondary)
                TextEditor(text: $json).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Theme.field)
                if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Button("Add Example") {
                        do {
                            var values = try decodedAutomations()
                            values.append(.init(name: "New automation", steps: [.init(name: "Show text", action: .init(kind: .showText, text: "Ready")), .init(name: "Wait", delay: 1)]))
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            json = String(decoding: try encoder.encode(values), as: UTF8.self)
                        } catch { message = error.localizedDescription }
                    }
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        do {
                            var value = trackpad.configuration
                            value.automations = try decodedAutomations()
                            _ = try host.commands.apply(value, expectedRevision: editRevision)
                            editing = false; message = nil
                        } catch { message = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 680, height: 520).graphiteTheme()
        }
    }
}
