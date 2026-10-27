import AppKit
import SwiftUI
import HandyToolbeltCore

/// Main-thread AppKit identity keeps our SwiftUI accessibility provider out of
/// the worker queue. Only the explicitly registered settings window qualifies.
final class MainWindowPresence {
    static let shared = MainWindowPresence()
    private weak var window: NSWindow?
    private var identity = UUID()
    private var isOpen = false
    private var closeObserver: NSObjectProtocol?
    private var visibilityObserver: NSObjectProtocol?
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

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }

    // SwiftUI/AppKit can reopen a retained window without calling our explicit
    // reveal path or moving its reader. Recover from native visibility as well.
    private func reconcileNativeReopen() {
        guard !isOpen, !suppressesLaunchWindow, let window,
              window.isVisible else { return }
        isOpen = true
        deferPresenceUpdate()
    }

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
        guard self.window !== window else { reconcileNativeReopen(); return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        self.window = window
        identity = UUID()
        isOpen = !suppressesLaunchWindow
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.isOpen = false
            self?.deferPresenceUpdate()
        }
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            self?.reconcileNativeReopen()
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
        reconcileNativeReopen()
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
    var presence: MainWindowPresence = .shared
    func makeNSView(context: Context) -> NSView { Reader(presence: presence) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Reader: NSView {
        let presence: MainWindowPresence
        init(presence: MainWindowPresence) {
            self.presence = presence
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presence.attach(window) }
        }
    }
}
