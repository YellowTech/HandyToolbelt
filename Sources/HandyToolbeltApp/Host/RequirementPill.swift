import SwiftUI
import HandyToolbeltCore

struct RequirementPill: View {
    let title: String
    let fulfilled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: fulfilled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(fulfilled ? Theme.requirementFulfilled : Theme.requirementMissing)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background((fulfilled ? Theme.requirementFulfilled : Theme.requirementMissing).opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder((fulfilled ? Theme.requirementFulfilled : Theme.requirementMissing).opacity(0.45)))
        }.buttonStyle(.plain).fixedSize()
            .accessibilityLabel("\(title): \(fulfilled ? "requirement fulfilled" : "access required"). Review in Global Settings")
            .help("Review \(title) in Global Settings")
    }
}

/// Both permission controls share status, explicit refresh feedback, and recovery actions.
/// Refreshing only queries grants; preview capture remains an explicit setup action.
struct PermissionAccessSection<Content: View>: View {
    let title: String
    let symbol: String
    let fulfilled: Bool
    let explanation: String
    @ObservedObject var host: ProductivityModel
    let openSettings: () -> Void
    var testPreview: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var didCheck = false

    private var statusColor: Color { fulfilled ? Theme.requirementFulfilled : Theme.requirementMissing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(title, systemImage: symbol).font(.headline)
                Spacer(minLength: 8)
                Label(fulfilled ? "Enabled" : "Not enabled", systemImage: fulfilled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(statusColor.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(statusColor.opacity(0.45)))
                    .fixedSize()
            }
            Text(explanation)
                .font(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open System Settings…", action: openSettings)
                Button("Check Again") { host.refreshPermissions(); didCheck = true }
                Button(host.isRestarting ? "Restarting…" : "Restart HandyToolbelt", action: host.restart)
                    .disabled(host.isRestarting)
                if let testPreview { Button("Open Setup…", action: testPreview) }
            }
            if didCheck {
                Label(fulfilled ? "macOS reports access enabled for this running app." : "macOS reports no access for this running app. Enable access in System Settings, then restart if needed.",
                      systemImage: fulfilled ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ScreenRecordingAccessView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var model: WindowSwitcherModel
    var body: some View {
        PermissionAccessSection(
            title: "Screen & System Audio Recording",
            symbol: "rectangle.on.rectangle",
            fulfilled: model.previews.hasPermission,
            explanation: "Allow HandyToolbelt in System Settings → Privacy & Security → Screen & System Audio Recording for window previews. Open Setup explains the separate direct-capture confirmation before testing one image. Previews never capture audio; macOS may ask again later.",
            host: host,
            openSettings: model.openPreviewSettings,
            testPreview: model.openPreviewSetup
        ) {
            if !model.previews.hasAcknowledgedNotice {
                Text("Preview setup is required before the chooser captures images. App icons remain available.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            if model.previews.accessVerifiedThisSession {
                Text("A window preview was verified this session.").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }
}
