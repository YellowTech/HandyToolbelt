import SwiftUI
import SuperTrackpadCore

struct SettingsTransferView: View {
    @ObservedObject var model: SettingsTransferModel
    @ObservedObject var trackpad: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Settings backup", systemImage: "arrow.down.doc").font(.headline)
            HStack {
                Button("Export Settings…") { model.chooseExport() }.disabled(model.busy || trackpad.settingsNeedRecovery)
                Button("Import Settings…") { model.chooseImport() }.disabled(model.busy || trackpad.settingsNeedRecovery)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
            }
            .disabled(model.review != nil)
            Text("Save a JSON file to iCloud Drive or any folder, then import it on another Mac. The file includes actions and AppleScript.")
                .font(.callout).foregroundStyle(Theme.secondary)
            HeaderDisclosureGroup("What is included?") {
                Text("Includes saved tool preferences, mappings, stacks, app groups, and automations. Excludes Allow CLI control, macOS permissions, Start at login registration, active Coffee selections, and Gesture Gym trials.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            if trackpad.settingsNeedRecovery {
                Text("Recover unreadable settings in Gestures before exporting or importing.").font(.callout).foregroundStyle(Theme.secondary)
            }
            if trackpad.hasUnappliedGymChanges {
                Text("Export uses saved settings. Apply your Gesture Gym trials first if you want them included.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(model.isError ? Color.red : Theme.secondary)
                    .textSelection(.enabled).accessibilityLabel(model.isError ? "Settings backup error: \(model.status)" : model.status)
            }
            if model.backupURL != nil { Button("Reveal Backup") { model.revealBackup() } }
        }
        .sheet(item: Binding(get: { model.review }, set: { if $0 == nil, model.review != nil { model.cancel() } })) { review in
            SettingsImportReviewView(model: model, review: review)
        }
    }
}

private struct SettingsImportReviewView: View {
    @ObservedObject var model: SettingsTransferModel
    let review: SettingsImportReview
    private var config: AppConfiguration { review.configuration }
    private var actions: [GestureAction] {
        config.bindings.map(\.action) + config.stacks.flatMap { stack in
            stack.startActions.filter { $0.kind == .action }.map(\.action) + stack.bindings.flatMap(\.actions) + stack.releaseActions
        } + config.automations.flatMap { $0.steps.compactMap(\.action) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Replace Settings?").font(.title2.weight(.semibold))
                    Text(review.filename).font(.headline).textSelection(.enabled)
                    Text([count(config.bindings.count, "mapping"), count(config.stacks.count, "stack"),
                          count(config.applicationGroups.count, "app group"), count(config.automations.count, "automation")].joined(separator: " · "))
                    VStack(alignment: .leading, spacing: 5) {
                        tool("Gestures", config.trackpadModuleEnabled)
                        tool("Switcher", config.windowSwitcher.isEnabled)
                        tool("Snapping", config.snappingModuleEnabled)
                        tool("Overlays", config.displayModuleEnabled)
                        tool("Power", config.powerModuleEnabled)
                        tool("Coffee", config.coffeeModuleEnabled)
                    }.font(.callout)
                    Text("This replaces all saved settings. Current settings are backed up locally first. Allow CLI control, macOS permissions, and Start at login are managed separately.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                    Text("Includes \(count(actions.count, "action")) and \(count(actions.filter { $0.kind == .appleScript }.count, "AppleScript definition")), including disabled mappings. Importing does not run actions; enabled mappings can run them during later use.")
                        .font(.callout)
                    if !review.warnings.isEmpty {
                        ScrollView { VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, text in Text(text).font(.callout) }
                        } }.frame(maxHeight: 100)
                    }
                    HeaderDisclosureGroup("Review actions, AppleScript & automation definitions") {
                        SettingsJSONPreview(text: review.contents)
                            .frame(height: 200).background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if model.busy { HStack { ProgressView().controlSize(.small); Text(model.status).font(.callout) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Replace Settings") { model.replaceReviewedSettings() }.disabled(model.busy)
            }
        }.padding(24).frame(width: 600, height: 580)
        .interactiveDismissDisabled(model.busy)
    }
    private func tool(_ title: String, _ enabled: Bool) -> some View {
        HStack { Text(title); Spacer(); Text(enabled ? "Enabled" : "Off").foregroundStyle(Theme.secondary) }.frame(width: 230)
    }
    private func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
}

/// Native selectable text keeps long configuration files efficient and genuinely read-only.
private struct SettingsJSONPreview: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Imported settings JSON; read only")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
