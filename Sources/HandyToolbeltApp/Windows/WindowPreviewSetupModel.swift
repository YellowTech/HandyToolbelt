import AppKit
import Combine
import HandyToolbeltCore

/// A setup session is explicit and transient. Screen Recording is queryable; the
/// direct-window alert is not. Only a real capture can confirm the current check.
final class WindowPreviewSetupModel: ObservableObject {
    enum Phase: Equatable {
        case introduction, screenAccess, checking, ready, problem(String)
    }
    @Published private(set) var isPresented = false
    @Published private(set) var phase: Phase = .introduction
    @Published private(set) var hasScreenAccess = false
    @Published private(set) var nativeWorkPending = false
    var onSuccessfulCheck: (() -> Void)?
    var presentationIsVisible: () -> Bool = { true }
    private let capture: WindowPreviewCapturing
    private let ownProcessID: pid_t
    private let timeout: TimeInterval
    private var generation = UUID()
    private var nativeRequest: UUID?
    private var deadline: DispatchWorkItem?
    private var continueAfterPermission = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init(capture: WindowPreviewCapturing = ScreenCaptureWindowPreviewCapture(),
         ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
         timeout: TimeInterval = 25, observeSystem: Bool = true) {
        self.capture = capture; self.ownProcessID = ownProcessID; self.timeout = timeout
        if observeSystem {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.applicationBecameActive() })
            observers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
            }
            lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.dismiss() }
        }
    }
    deinit {
        deadline?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }
    func present() {
        generation = UUID(); continueAfterPermission = false
        hasScreenAccess = capture.hasPermission()
        phase = nativeRequest == nil ? .introduction : .problem("A previous macOS preview check is still finishing. Respond to its prompt, or restart HandyToolbelt and check again.")
        isPresented = true
    }
    func dismiss() {
        generation = UUID(); continueAfterPermission = false
        deadline?.cancel(); deadline = nil; isPresented = false
        // The one-shot native API cannot be cancelled. Keep its slot occupied
        // until it returns, preventing overlapping retries after a close/timeout.
    }
    func start() {
        guard isPresented, presentationIsVisible(), nativeRequest == nil else { return }
        hasScreenAccess = capture.hasPermission()
        if hasScreenAccess { testCapture(); return }
        phase = .screenAccess; continueAfterPermission = true
        let session = generation
        capture.requestPermission()
        guard isPresented, generation == session else { return }
        applicationBecameActive()
    }
    /// A passive refresh never prompts. Reactivation can advance only the
    /// sequence started explicitly within the still-presented setup session.
    func applicationBecameActive() {
        guard isPresented, presentationIsVisible() else { return }
        hasScreenAccess = capture.hasPermission()
        if continueAfterPermission, hasScreenAccess, nativeRequest == nil {
            continueAfterPermission = false; testCapture()
        }
    }
    func checkAgain() {
        guard isPresented, presentationIsVisible(), nativeRequest == nil else { return }
        continueAfterPermission = false
        hasScreenAccess = capture.hasPermission()
        if hasScreenAccess { testCapture() } else { phase = .screenAccess }
    }
    private func testCapture() {
        guard isPresented, presentationIsVisible(), nativeRequest == nil else { return }
        continueAfterPermission = false; phase = .checking
        let session = generation, request = UUID()
        nativeRequest = request; nativeWorkPending = true
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented, self.presentationIsVisible(), self.generation == session, self.nativeRequest == request else { return }
            self.generation = UUID()
            self.phase = .problem("macOS has not finished the check. Respond to any access prompt. If it stays here, restart HandyToolbelt and check again.")
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        capture.loadWindows { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.accepts(session, request) else { self.finish(request); return }
                switch result {
                case let .failure(error): self.fail(error.localizedDescription, request: request)
                case let .success(windows):
                    // A different app validates the same access the chooser uses.
                    guard let window = windows.first(where: { $0.processID != self.ownProcessID && WindowPreviewPolicy.imageSize(for: $0.frame) != nil }) else {
                        self.fail("Open a window in another app, then check again.", request: request); return
                    }
                    let size = WindowPreviewPolicy.imageSize(for: window.frame)!
                    self.capture.capture(id: window.id, size: CGSize(width: max(1, size.width / 2), height: max(1, size.height / 2))) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard self.accepts(session, request) else { self.finish(request); return }
                            self.hasScreenAccess = self.capture.hasPermission()
                            switch result {
                            case let .success(image) where self.hasScreenAccess && image.width > 0 && image.height > 0 && image.width <= 480 && image.height <= 300:
                                self.finish(request); self.phase = .ready; self.onSuccessfulCheck?() // Image is discarded here.
                            case let .failure(error): self.fail(error.localizedDescription, request: request)
                            default: self.fail("macOS did not provide a usable preview. Check access and try again.", request: request)
                            }
                        }
                    }
                }
            }
        }
    }
    private func accepts(_ session: UUID, _ request: UUID) -> Bool {
        isPresented && presentationIsVisible() && generation == session && nativeRequest == request
    }
    private func finish(_ request: UUID) {
        guard nativeRequest == request else { return }
        deadline?.cancel(); deadline = nil; nativeRequest = nil; nativeWorkPending = false
    }
    private func fail(_ message: String, request: UUID) {
        hasScreenAccess = capture.hasPermission()
        finish(request); phase = .problem(message)
    }
}
