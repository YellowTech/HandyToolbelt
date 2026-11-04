import AppKit
import ApplicationServices
import SwiftUI

private var accessibilitySettingsName: String {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
}

struct AccessibilityAccessView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel

    var body: some View {
        PermissionAccessSection(
            title: "Accessibility",
            symbol: "accessibility",
            fulfilled: trackpad.hasAccessibility,
            explanation: "Allow HandyToolbelt in System Settings → Privacy & Security → \(accessibilitySettingsName) so gestures can run actions and the window tools can focus and move windows.",
            host: host,
            openSettings: trackpad.openAccessibility,
            openSetup: host.openAccessibilitySetup
        ) {
            if !trackpad.hasAccessibility {
                AccessibilityRecoveryView(revealApp: host.revealApp)
            }
        }
    }
}

struct AccessibilitySetupView: View {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @State private var started = false
    @State private var didCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Accessibility setup").font(.title2.weight(.semibold))
            Text("Accessibility lets HandyToolbelt run gesture actions, focus windows, and move windows for snapping.")
                .font(.callout).foregroundStyle(Theme.secondary)
            Divider()
            if trackpad.hasAccessibility {
                Label("Accessibility is enabled for this running app.", systemImage: "checkmark.circle")
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(started
                         ? "Enable HandyToolbelt in System Settings → Privacy & Security → \(accessibilitySettingsName), then return here and choose Check Again."
                         : "Select Start Setup to ask macOS for access. Then enable HandyToolbelt in System Settings → Privacy & Security → \(accessibilitySettingsName).")
                    if didCheck {
                        Text("macOS still reports no access for this running app.")
                    }
                }.font(.callout).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    Button("Open System Settings…", action: trackpad.openAccessibility)
                    Button("Restart HandyToolbelt") { host.dismissPermissionSetup(); host.restart() }
                        .disabled(host.isRestarting)
                }
                AccessibilityRecoveryView(revealApp: host.revealApp)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if trackpad.hasAccessibility {
                    Button("Done", action: host.dismissPermissionSetup).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: host.dismissPermissionSetup).keyboardShortcut(.cancelAction)
                    Button(started ? "Check Again" : "Start Setup") {
                        if started {
                            host.refreshPermissions()
                            didCheck = true
                        } else {
                            start()
                        }
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 480)
        .graphiteTheme()
        .background(PermissionSetupWindowLifecycle(onHidden: host.dismissPermissionSetup))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            host.dismissPermissionSetup()
        }
    }

    private func start() {
        started = true
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        host.refreshPermissions()
    }
}

private struct AccessibilityRecoveryView: View {
    let revealApp: () -> Void

    var body: some View {
        HeaderDisclosureGroup("Already enabled, or not listed?") {
            VStack(alignment: .leading, spacing: 8) {
                Text("If the switch is already on, restart HandyToolbelt. If access is still missing, remove its old entry with −, then add this copy with + and enable it. A rebuilt or moved app can leave an outdated entry.")
                Text("Reveal App shows the exact copy to add. Return here and choose Check Again. Restart if macOS requests it.")
                Button("Reveal App in Finder", action: revealApp)
            }.font(.callout).foregroundStyle(Theme.secondary).padding(.top, 6)
        }.font(.callout)
    }
}
