import AppKit
import Combine
import ScreenCaptureKit
import SuperTrackpadCore

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
                let windows = content?.windows.filter { $0.windowLayer == 0 && $0.owningApplication != nil } ?? []
                self.windows = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                if let error { completion(.failure(error)) }
                else { completion(.success(windows.map { WindowPreviewCandidate(id: $0.windowID, processID: $0.owningApplication!.processID, title: $0.title, frame: $0.frame) })) }
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
    private let capture: WindowPreviewCapturing
    private var lifetime = WindowPreviewLifetime()
    private var items: [WindowItem] = []
    private var visibleIDs: [UUID] = []
    private var candidates: [UInt32: WindowPreviewCandidate] = [:]
    private var matches: [UUID: UInt32] = [:]
    private var attempted = Set<UUID>()
    private var cacheOrder: [UUID] = []
    // Keep actual native work accounted for even after invalidating its generation.
    private var contentRequest: UUID?
    private var captures: [UUID: (item: UUID, generation: UInt64)] = [:]
    private var contentLoaded = false

    init(capture: WindowPreviewCapturing? = nil) {
        let capture = capture ?? ScreenCaptureWindowPreviewCapture()
        self.capture = capture; self.hasPermission = capture.hasPermission()
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
    func noteSuccessfulAccessCheck() { accessVerifiedThisSession = true; refreshPermission() }
    func begin(items: [WindowItem]) {
        end()
        refreshPermission()
        guard hasPermission else { return }
        self.items = items
        lifetime.begin()
    }
    func end() {
        lifetime.end()
        items = []; visibleIDs = []; candidates = [:]; matches = [:]
        attempted = []; cacheOrder = []
        if !images.isEmpty { images = [:] }
        contentLoaded = false
    }
    func setVisible(_ ids: [UUID]) {
        guard lifetime.isActive else { return }
        visibleIDs = Array(ids.prefix(WindowPreviewPolicy.cacheLimit))
        pump()
    }
    private func pump() {
        guard lifetime.isActive, !visibleIDs.isEmpty else { return }
        guard capture.hasPermission() else { refreshPermission(); return }
        if !contentLoaded {
            guard contentRequest == nil else { return }
            let request = UUID(), token = lifetime.generation
            contentRequest = request
            capture.loadWindows { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.contentRequest == request else { return }
                    self.contentRequest = nil
                    guard self.lifetime.accepts(token) else { self.pump(); return }
                    self.contentLoaded = true
                    let candidates = (try? result.get()) ?? []
                    self.candidates = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    var assigned = Set<UInt32>()
                    for item in self.items {
                        if let id = WindowPreviewPolicy.uniqueMatch(for: item, windows: self.items, candidates: candidates), assigned.insert(id).inserted {
                            self.matches[item.id] = id
                        }
                    }
                    self.pump()
                }
            }
            return
        }
        for id in visibleIDs {
            guard captures.count < WindowPreviewPolicy.concurrencyLimit else { break }
            guard images[id] == nil, !attempted.contains(id),
                  let nativeID = matches[id], let window = candidates[nativeID],
                  let size = WindowPreviewPolicy.imageSize(for: window.frame) else { continue }
            attempted.insert(id)
            let request = UUID(), token = lifetime.generation
            captures[request] = (id, token)
            capture.capture(id: nativeID, size: size) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.captures.removeValue(forKey: request)
                    guard self.lifetime.accepts(token) else { self.pump(); return }
                    guard self.capture.hasPermission() else { self.refreshPermission(); return }
                    if case let .success(image) = result, image.width <= 480, image.height <= 300 {
                        self.accessVerifiedThisSession = true
                        self.images[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                        self.cacheOrder.append(id)
                        while self.cacheOrder.count > WindowPreviewPolicy.cacheLimit {
                            let evicted = self.cacheOrder.first(where: { !self.visibleIDs.contains($0) }) ?? self.cacheOrder[0]
                            self.cacheOrder.removeAll { $0 == evicted }; self.images.removeValue(forKey: evicted)
                            self.attempted.remove(evicted)
                        }
                    }
                    self.pump()
                }
            }
        }
    }
}
