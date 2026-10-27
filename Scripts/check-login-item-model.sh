#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cat > "$TEMP_DIR/main.swift" <<'SWIFT'
import AppKit
import Foundation

var systemStatus = LoginItemModel.Status.notRegistered
var registrations = 0
var removals = 0
var settings = 0
var shouldFail = false
struct Failure: LocalizedError { var errorDescription: String? { "Test failure" } }
let model = LoginItemModel(driver: .init(status: { systemStatus }, register: {
    registrations += 1
    if shouldFail { throw Failure() }
    systemStatus = .requiresApproval
}, unregister: {
    removals += 1
    if shouldFail { throw Failure() }
    systemStatus = .notRegistered
}, openSettings: { settings += 1 }))
func check(_ value: @autoclosure () -> Bool, _ description: String) {
    precondition(value(), description)
}
check(registrations == 0 && removals == 0, "Initialization must not mutate registration")
check(!model.enabled && !model.isSelected, "Unregistered initial state")
model.setEnabled(true)
check(registrations == 1 && model.isSelected && !model.enabled, "Pending approval isn't effective enablement")
model.setEnabled(true)
check(registrations == 1, "Pending registration must not register twice")
model.openSettings()
check(settings == 1, "Settings routed through injected driver")
systemStatus = .enabled
model.refresh()
check(model.enabled && model.errorMessage == nil, "External approval refresh")
shouldFail = true
model.setEnabled(false)
check(model.enabled && model.errorMessage?.contains("Test failure") == true, "Failure preserves OS truth")
shouldFail = false
model.setEnabled(false)
check(!model.isSelected && model.errorMessage == nil && removals == 2, "Retry reads actual status")
systemStatus = .notFound
model.refresh()
check(model.status.rawValue == "notFound" && !model.enabled, "Missing status is exposed")
let login = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
login.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
check(LoginLaunchPolicy.isLoginItemLaunch(event: login), "Login event detected")
check(!LoginLaunchPolicy.isLoginItemLaunch(event: nil), "Missing launch event is ordinary")
check(!LoginLaunchPolicy.isLoginItemLaunch(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), reason: OSType(keyAELaunchedAsServiceItem)), "Service launch isn't login launch")
check(!LoginLaunchPolicy.isLoginItemLaunch(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), reason: nil), "Manual launch is ordinary")
check(!LoginLaunchPolicy.isLoginItemLaunch(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication), reason: OSType(keyAELaunchedAsLogInItem)), "Only initial open event counts")
print("Login item fake-driver and startup policy checks passed")
SWIFT
xcrun swiftc -swift-version 5 "$ROOT/Sources/HandyToolbeltApp/Host/LoginItemModel.swift" "$TEMP_DIR/main.swift" -o "$TEMP_DIR/check"
"$TEMP_DIR/check"
xcrun swiftc -typecheck -swift-version 5 "$ROOT/Sources/HandyToolbeltApp/Host/LoginItemModel.swift" "$ROOT/Sources/HandyToolbeltApp/Host/LoginItemSettingsView.swift"
