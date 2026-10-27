import SwiftUI

struct AccessibilityAccessView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @State private var showRecovery = false

    private var settingsName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    var body: some View {
        PermissionAccessSection(
            title: "Accessibility",
            symbol: "accessibility",
            fulfilled: trackpad.hasAccessibility,
            explanation: "Enable HandyToolbelt in System Settings → Privacy & Security → \(settingsName). This lets gestures run actions and the switcher focus windows.",
            host: host,
            openSettings: trackpad.openAccessibility
        ) {
            if !trackpad.hasAccessibility {
                HeaderDisclosureGroup("Already enabled, or not listed?", isExpanded: $showRecovery) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If the switch is already on, restart HandyToolbelt. If access is still missing, remove its old entry with −, then add this copy with + and enable it. A rebuilt or moved app can leave an outdated entry.")
                        Text("Reveal App shows the exact copy to add. Return here and choose Check Again; restart if macOS requests it.")
                        Button("Reveal App in Finder", action: host.revealApp)
                    }.font(.callout).foregroundStyle(Theme.secondary).padding(.top, 6)
                }.font(.callout)
            }
        }
    }
}
