import AppKit
import Combine
import ScreenCaptureKit
import HandyToolbeltCore

enum WindowPreviewCaptureError: LocalizedError {
    case windowUnavailable, imageUnavailable
    var errorDescription: String? {
        switch self {
        case .windowUnavailable: return "The window is no longer available."
        case .imageUnavailable: return "macOS did not return a preview image."
        }
    }
}

protocol WindowPreviewCapturing: AnyObject {
    func hasPermission() -> Bool
    func requestPermission()
    func loadWindows(completion: @escaping (Result<[WindowPreviewCandidate], Error>) -> Void)
    func capture(id: UInt32, size: CGSize, completion: @escaping (Result<CGImage, Error>) -> Void)
}

final class ScreenCaptureWindowPreviewCapture: WindowPreviewCapturing {
    private var windows: [UInt32: SCWindow] = [:]
    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    func loadWindows(completion: @escaping (Result<[WindowPreviewCandidate], Error>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { completion(.failure(error)); return }
                let windows = content?.windows.filter { $0.windowLayer == 0 && $0.owningApplication != nil } ?? []
                self.windows = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                completion(.success(windows.map { WindowPreviewCandidate(id: $0.windowID, processID: $0.owningApplication!.processID, title: $0.title, frame: $0.frame) }))
            }
        }
    }
    func capture(id: UInt32, size: CGSize, completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard let window = windows[id] else { completion(.failure(WindowPreviewCaptureError.windowUnavailable)); return }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width); configuration.height = Int(size.height)
        configuration.capturesAudio = false
        configuration.showsCursor = false; configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) { image, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)) }
                else if let image { completion(.success(image)) }
                else { completion(.failure(WindowPreviewCaptureError.imageUnavailable)) }
            }
        }
    }
}

/// One-shot window images exist only for the current chooser. No streams or disk cache.
/// All state is owned by the main queue; native callbacks return there before inspecting it.
final class WindowPreviewService: ObservableObject {
    @Published private(set) var images: [UUID: NSImage] = [:]
    @Published private(set) var hasPermission: Bool
    @Published private(set) var didRequestPermission = false
    @Published private(set) var accessVerifiedThisSession = false
    // This records our explanation and a successful test, never a macOS grant.
    static let noticeVersion = 1
    static let noticeKey = "windowPreview.directCaptureNoticeVersion"
    @Published private(set) var hasAcknowledgedNotice: Bool
    var canUsePreviews: Bool { hasPermission && hasAcknowledgedNotice }
    private let defaults: UserDefaults
    private let capture: WindowPreviewCapturing
    private var lifetime = WindowPreviewLifetime()
    private var items: [WindowItem] = []
    private var eligibleIDs = Set<UUID>()
    private var visibleIDs: [UUID] = []
    private var candidates: [UInt32: WindowPreviewCandidate] = [:]
    private var matches: [UUID: UInt32] = [:]
    private var attempted = Set<UUID>()
    private var captureRetryCounts: [UUID: Int] = [:]
    private var readyCaptureRetries = Set<UUID>()
    private var remainingCaptureRetries = WindowPreviewService.captureRetryLimit
    private static let captureRetryLimit = 8
    private static let captureRetryDelays: [TimeInterval] = [0.08, 0.18]
    private static let contentRetryDelay: TimeInterval = 0.12
    private var cacheOrder: [UUID] = []
    // Keep actual native work accounted for even after invalidating its generation.
    private var contentRequest: UUID?
    private var captures: [UUID: (item: UUID, generation: UInt64)] = [:]
    private var contentLoaded = false
    private enum ContentRetry { case available, scheduled, used }
    private var contentRetry = ContentRetry.available

    init(capture: WindowPreviewCapturing? = nil, defaults: UserDefaults = .standard) {
        let capture = capture ?? ScreenCaptureWindowPreviewCapture()
        self.capture = capture; self.hasPermission = capture.hasPermission()
        self.defaults = defaults
        self.hasAcknowledgedNotice = defaults.integer(forKey: Self.noticeKey) == Self.noticeVersion
    }
    func refreshPermission() {
        let permission = capture.hasPermission()
        if hasPermission != permission { hasPermission = permission }
        if !permission {
            if accessVerifiedThisSession { accessVerifiedThisSession = false }
            end()
        }
    }
    /// Called exclusively by the explicit settings button.
    func requestPermission() {
        didRequestPermission = true
        capture.requestPermission()
        refreshPermission()
    }
    func noteSuccessfulAccessCheck() {
        refreshPermission()
        guard hasPermission else { return }
        accessVerifiedThisSession = true
        if !hasAcknowledgedNotice {
            defaults.set(Self.noticeVersion, forKey: Self.noticeKey)
            hasAcknowledgedNotice = true
        }
    }
    func begin(items: [WindowItem]) {
        end()
        refreshPermission()
        guard canUsePreviews else { return }
        self.items = items
        eligibleIDs = Set(items.lazy.filter {
            !$0.isHidden && !$0.isMinimized && !$0.captureTitle.isEmpty
        }.map(\.id))
        lifetime.begin()
    }
    func updateMetadata(_ enriched: [WindowItem]) {
        guard lifetime.isActive else { return }
        let updates = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = items.map { item in
            guard let update = updates[item.id], update.processID == item.processID,
                  update.captureTitle == item.captureTitle else { return item }
            var enriched = item
            enriched.frame = update.frame
            return enriched
        }
        rebuildMatches()
        pump()
    }
    private func rebuildMatches() {
        matches = [:]
        var assigned = Set<UInt32>()
        let available = Array(candidates.values)
        for item in items {
            if let id = WindowPreviewPolicy.uniqueMatch(for: item, windows: items, candidates: available), assigned.insert(id).inserted {
                matches[item.id] = id
            }
        }
    }
    func end() {
        lifetime.end()
        items = []; eligibleIDs = []; visibleIDs = []; candidates = [:]; matches = [:]
        attempted = []; captureRetryCounts = [:]; readyCaptureRetries = []; cacheOrder = []
        remainingCaptureRetries = Self.captureRetryLimit
        if !images.isEmpty { images = [:] }
        contentLoaded = false
        contentRetry = .available
    }
    func setVisible(_ ids: [UUID]) {
        guard lifetime.isActive else { return }
        visibleIDs = ids.prefix(WindowPreviewPolicy.cacheLimit).filter { eligibleIDs.contains($0) }
        pump()
    }
    private func pump() {
        guard lifetime.isActive, hasAcknowledgedNotice, !visibleIDs.isEmpty else { return }
        guard capture.hasPermission() else { refreshPermission(); return }
        if !contentLoaded {
            loadContent()
            return
        }
        if hasUnmatchedVisibleItems { scheduleContentRetry() }
        for id in visibleIDs {
            guard captures.count < WindowPreviewPolicy.concurrencyLimit else { break }
            guard images[id] == nil, !attempted.contains(id) || readyCaptureRetries.contains(id),
                  let nativeID = matches[id], let window = candidates[nativeID],
                  let size = WindowPreviewPolicy.imageSize(for: window.frame) else { continue }
            readyCaptureRetries.remove(id)
            attempted.insert(id)
            let request = UUID(), token = lifetime.generation
            captures[request] = (id, token)
            capture.capture(id: nativeID, size: size) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.captures.removeValue(forKey: request) != nil else { return }
                    guard self.lifetime.accepts(token) else { self.pump(); return }
                    guard self.capture.hasPermission() else { self.refreshPermission(); return }
                    guard self.matches[id] == nativeID else {
                        self.attempted.remove(id)
                        self.pump()
                        return
                    }
                    if case let .success(image) = result, image.width <= 480, image.height <= 300 {
                        self.accessVerifiedThisSession = true
                        self.images[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                        self.cacheOrder.append(id)
                        while self.cacheOrder.count > WindowPreviewPolicy.cacheLimit {
                            let evicted = self.cacheOrder.first(where: { !self.visibleIDs.contains($0) }) ?? self.cacheOrder[0]
                            self.cacheOrder.removeAll { $0 == evicted }; self.images.removeValue(forKey: evicted)
                            self.attempted.remove(evicted)
                        }
                    } else if case let .failure(error) = result, Self.isTransient(error) {
                        self.scheduleCaptureRetry(id: id, generation: token)
                    }
                    self.pump()
                }
            }
        }
    }

    private var hasUnmatchedVisibleItems: Bool {
        visibleIDs.contains { images[$0] == nil && matches[$0] == nil }
    }

    private func loadContent() {
        guard contentRequest == nil else { return }
        let request = UUID(), token = lifetime.generation
        contentRequest = request
        capture.loadWindows { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.contentRequest == request else { return }
                self.contentRequest = nil
                guard self.lifetime.accepts(token) else { self.pump(); return }
                self.contentLoaded = true
                switch result {
                case let .success(candidates):
                    self.candidates = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                case let .failure(error):
                    if !Self.isTransient(error) { self.contentRetry = .used }
                }
                self.rebuildMatches()
                self.pump()
            }
        }
    }

    private func scheduleContentRetry() {
        guard contentRetry == .available else { return }
        contentRetry = .scheduled
        let token = lifetime.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentRetryDelay) { [weak self] in
            guard let self, self.lifetime.accepts(token) else { return }
            self.contentRetry = .available
            guard self.hasUnmatchedVisibleItems else { return }
            guard self.capture.hasPermission() else { self.refreshPermission(); return }
            self.contentRetry = .used
            self.loadContent()
        }
    }

    private func scheduleCaptureRetry(id: UUID, generation: UInt64) {
        let retries = captureRetryCounts[id, default: 0]
        guard remainingCaptureRetries > 0, retries < Self.captureRetryDelays.count else { return }
        remainingCaptureRetries -= 1
        captureRetryCounts[id] = retries + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureRetryDelays[retries]) { [weak self] in
            guard let self, self.lifetime.accepts(generation) else { return }
            self.readyCaptureRetries.insert(id)
            self.pump()
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if error is WindowPreviewCaptureError { return true }
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return false }
        switch SCStreamError.Code(rawValue: error.code) {
        case .failedToStart, .failedApplicationConnectionInvalid, .failedApplicationConnectionInterrupted,
             .failedNoMatchingApplicationContext, .internalError, .noWindowList, .noDisplayList,
             .noCaptureSource:
            return true
        default:
            return false
        }
    }
}
