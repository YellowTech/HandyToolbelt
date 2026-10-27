import AppKit
import SwiftUI

struct LoginItemSettingsView: View {
    @ObservedObject var model: LoginItemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Start at login", systemImage: "power").fontWeight(.medium)
                Spacer()
                Toggle("Start at login", isOn: Binding(get: { model.isSelected }, set: model.setEnabled))
                    .labelsHidden().toggleStyle(.switch).fixedSize()
            }
            if model.status == .requiresApproval {
                Text("Allow HandyToolbelt in Login Items to finish enabling start at login.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items Settings", action: model.openSettings)
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
