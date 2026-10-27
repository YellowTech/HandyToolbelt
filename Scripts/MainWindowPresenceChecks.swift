import AppKit
import HandyToolbeltCore

@main
struct MainWindowPresenceChecks {
    static func main() {
        _ = NSApplication.shared
        var pending: [() -> Void] = []
        var policies: [NSApplication.ActivationPolicy] = []
        var concealed = 0, presented = 0
        var hidden = false
        let presence = MainWindowPresence(schedule: { pending.append($0) }, policy: { policies.append($0) },
                                          conceal: { _ in concealed += 1 }, present: { _ in presented += 1 },
                                          hidden: { hidden }, active: { false })
        func flush() { let work = pending; pending.removeAll(); work.forEach { $0() } }
        let window = TestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        precondition(presence.snapshot(includeFrame: false) == nil, "Unregistered native windows and panels are excluded")
        presence.attach(window)
        precondition(policies.isEmpty, "Attachment defers native policy writes beyond SwiftUI layout")
        let id = presence.snapshot(includeFrame: false)!.item.id
        flush()
        precondition(policies.last == .regular)
        presence.attach(window)
        precondition(presence.snapshot(includeFrame: false)!.item.id == id, "Reattachment preserves identity")
        window.testMinimized = true; hidden = true
        let item = presence.snapshot(includeFrame: false)!.item
        precondition(item.id == id && item.isMinimized && item.isHidden)
        precondition(item.appName == "HandyToolbelt", "Own-window entries use the public app name")
        precondition(WindowOrdering.candidates([item], settings: WindowSwitcherSettings(), currentProcessID: getpid()).count == 1)
        var filters = WindowSwitcherSettings(); filters.includeMinimized = false
        precondition(WindowOrdering.candidates([item], settings: filters, currentProcessID: getpid()).isEmpty)
        filters.includeMinimized = true; filters.includeHidden = false
        precondition(WindowOrdering.candidates([item], settings: filters, currentProcessID: getpid()).isEmpty)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        precondition(presence.snapshot(includeFrame: false) == nil)
        flush(); precondition(policies.last == .accessory)
        presence.prepareToOpen(); presence.reveal()
        precondition(presence.snapshot(includeFrame: false)!.item.id == id && presented == 1)
        presence.suppressRestoredLaunchWindow()
        precondition(presence.snapshot(includeFrame: false) == nil)
        flush(); precondition(concealed == 1 && policies.last == .accessory)
        // A queued suppression must never hide a later explicit reopen.
        presence.suppressRestoredLaunchWindow(); presence.prepareToOpen(); presence.reveal(); flush()
        precondition(concealed == 1 && policies.last == .regular && presented == 2)
        // Nor may attachment's pending regular policy resurrect a closed window.
        let replacement = TestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        replacement.isReleasedWhenClosed = false
        presence.attach(replacement)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacement)
        flush(); precondition(policies.last == .accessory && presence.snapshot(includeFrame: false) == nil)
        print("Main window presence checks passed")
    }
}

private final class TestWindow: NSWindow {
    var testMinimized = false
    override var isMiniaturized: Bool { testMinimized }
}
