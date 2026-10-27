import AppKit
import SwiftUI
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
        // Use the actual SwiftUI representable in a native hosting hierarchy.
        // Direct attach() checks cannot catch a retained window reopening without
        // moving its background reader to another window.
        var nativePolicies: [NSApplication.ActivationPolicy] = []
        let nativePresence = MainWindowPresence(policy: { nativePolicies.append($0) }, hidden: { false }, active: { false })
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = NSHostingView(rootView: ModuleHostingSurface(selection: .first) { _ in
            AnyView(WorkspaceHostingSurface(selection: .first) { _ in AnyView(Text("Main content")) })
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MainWindowPresenceReader(presence: nativePresence)))
        native.orderFront(nil)
        native.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let nativeID = nativePresence.snapshot(includeFrame: false)!.item.id
        native.close()
        precondition(nativePresence.snapshot(includeFrame: false) == nil)
        native.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(nativePresence.snapshot(includeFrame: false)?.item.id == nativeID,
                     "A native reopen of the same registered window restores its switcher entry")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(nativePolicies.last == .regular, "Native reopening restores regular activation policy")
        // Auxiliary native windows must not replace the registered main identity.
        panel.orderFront(nil)
        precondition(nativePresence.snapshot(includeFrame: false)?.item.id == nativeID)
        panel.orderOut(nil)
        native.close()
        precondition(nativePresence.snapshot(includeFrame: false) == nil)
        // Native visibility during a suppressed login launch must not resurrect it.
        nativePresence.suppressRestoredLaunchWindow()
        native.orderFront(nil)
        precondition(nativePresence.snapshot(includeFrame: false) == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!native.isVisible && nativePolicies.last == .accessory)
        nativePresence.prepareToOpen()
        nativePresence.reveal()
        precondition(nativePresence.snapshot(includeFrame: false)?.item.id == nativeID)
        native.close()
        print("Main window presence checks passed")
    }
}

private final class TestWindow: NSWindow {
    var testMinimized = false
    override var isMiniaturized: Bool { testMinimized }
}

// Only the cache's finite selection keys are relevant to this native fixture.
enum FixtureSelection: CaseIterable { case first, second }
typealias ProductivitySection = FixtureSelection
typealias TrackpadWorkspace = FixtureSelection
