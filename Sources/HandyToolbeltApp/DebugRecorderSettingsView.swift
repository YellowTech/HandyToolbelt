import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DebugRecorderSettingsView: View {
    @State private var enabled = DebugEventRecorder.shared.isEnabled
    @State private var status = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Debug recorder", systemImage: "ladybug").font(.headline)
            Toggle("Record recent input diagnostics", isOn: $enabled)
                .onChange(of: enabled) { _, value in DebugEventRecorder.shared.setEnabled(value); status = "" }
            Text("Keeps up to 15 seconds in memory: touch positions and pressure, generic keyboard events, gesture decisions, and snapping. Never records typed text, key codes, app names, window titles, or screenshots. Turning this off clears the buffer. Recording resets to off when HandyToolbelt quits. macOS Secure Input may hide keyboard events.")
                .font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Save Last 15 Seconds…", action: save).disabled(!enabled)
            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(failed ? Color.red : Theme.secondary).textSelection(.enabled)
            }
        }
    }
    private func save() {
        do {
            // Freeze the requested interval before showing a panel or writing files.
            let data = try DebugEventRecorder.shared.snapshot()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "HandyToolbelt-debug.json"
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                DispatchQueue.global(qos: .utility).async {
                    let result = Result { try data.write(to: url, options: .atomic) }
                    DispatchQueue.main.async {
                        switch result {
                        case .success: failed = false; status = "Saved diagnostics locally."
                        case let .failure(error): failed = true; status = "Could not save diagnostics: \(error.localizedDescription)"
                        }
                    }
                }
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        } catch { failed = true; status = "Could not save diagnostics: \(error.localizedDescription)" }
    }
}
