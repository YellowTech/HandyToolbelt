import AppKit
import SwiftUI
import SuperTrackpadCore

/// Main-thread AppKit identity keeps our SwiftUI accessibility provider out of
/// the worker queue. Only the explicitly registered settings window qualifies.
final class MainWindowPresence {
    static let shared = MainWindowPresence()
    private weak var window: NSWindow?
    private var identity = UUID()
    private var isOpen = false
    private var closeObserver: NSObjectProtocol?
    private var generation: UInt64 = 0
    private let schedule: (@escaping () -> Void) -> Void
    private let policy: (NSApplication.ActivationPolicy) -> Void
    private let conceal: (NSWindow) -> Void
    private let present: (NSWindow) -> Void
    private let hidden: () -> Bool
    private let active: () -> Bool
    var suppressesLaunchWindow = false

    // Load the installed bundle's icon once, avoiding a stale running Dock tile.
    // SwiftPM/debug bundles may not contain an ICNS resource.
    private static let applicationIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
        if policy == .regular, let image = applicationIcon {
            NSApp.applicationIconImage = image
        }
    }

    init(schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         policy: @escaping (NSApplication.ActivationPolicy) -> Void = { MainWindowPresence.applyActivationPolicy($0) },
         conceal: @escaping (NSWindow) -> Void = { $0.orderOut(nil) },
         present: @escaping (NSWindow) -> Void = { window in
             NSApp.unhide(nil)
             if window.isMiniaturized { window.deminiaturize(nil) }
             window.makeKeyAndOrderFront(nil)
             NSApp.activate(ignoringOtherApps: true)
         }, hidden: @escaping () -> Bool = { NSApp.isHidden }, active: @escaping () -> Bool = { NSApp.isActive }) {
        self.schedule = schedule; self.policy = policy; self.conceal = conceal
        self.present = present; self.hidden = hidden; self.active = active
    }

    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    private func deferPresenceUpdate() {
        generation &+= 1
        let token = generation
        schedule { [weak self] in
            guard let self, token == self.generation else { return }
            if self.suppressesLaunchWindow, let window = self.window { self.conceal(window) }
            self.policy(self.isOpen ? .regular : .accessory)
        }
    }

    func attach(_ window: NSWindow) {
        precondition(Thread.isMainThread)
        guard self.window !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        self.window = window
        identity = UUID()
        isOpen = !suppressesLaunchWindow
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.isOpen = false
            self?.deferPresenceUpdate()
        }
        deferPresenceUpdate()
    }

    func suppressRestoredLaunchWindow() {
        precondition(Thread.isMainThread)
        suppressesLaunchWindow = true
        isOpen = false
        deferPresenceUpdate()
    }

    func prepareToOpen() {
        precondition(Thread.isMainThread)
        suppressesLaunchWindow = false
        generation &+= 1
        policy(.regular)
    }

    func reveal() {
        precondition(Thread.isMainThread)
        guard let window else { return }
        isOpen = true
        generation &+= 1
        policy(.regular)
        present(window)
    }

    func snapshot(includeFrame: Bool) -> (item: WindowItem, focused: Bool)? {
        precondition(Thread.isMainThread)
        guard isOpen, let window else { return nil }
        // AX and ScreenCaptureKit use a top-left origin on the primary screen.
        let frame = window.frame
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let captureFrame = CGRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height)
        let item = WindowItem(id: identity, processID: getpid(), appName: "HandyToolbelt", bundleIdentifier: Bundle.main.bundleIdentifier ?? "", title: window.title, isMinimized: window.isMiniaturized, isHidden: hidden(), frame: includeFrame ? captureFrame : nil)
        return (item, active() && window.isKeyWindow)
    }

    func activate(_ id: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard isOpen, window != nil, identity == id else { return false }
        reveal()
        return true
    }
}

struct MainWindowPresenceReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reader() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Reader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindowPresence.shared.attach(window) }
        }
    }
}
