import Foundation

public enum WindowShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
    case optionTab, commandTab, controlOptionTab
    public var id: String { rawValue }
    public var title: String {
        switch self { case .optionTab: return "⌥ Tab"; case .commandTab: return "⌘ Tab"; case .controlOptionTab: return "⌃ ⌥ Tab" }
    }
    public var modifiers: UInt64 {
        switch self { case .optionTab: return 1 << 19; case .commandTab: return 1 << 20; case .controlOptionTab: return (1 << 18) | (1 << 19) }
    }
    public func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCode == 48 && flags & ((1 << 18) | (1 << 19) | (1 << 20)) == modifiers
    }
    public func isHeld(flags: UInt64) -> Bool { flags & modifiers == modifiers }
}

public enum WindowLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case list, grid
    public var id: String { rawValue }
    public var title: String { self == .list ? "List" : "Grid" }
    public func verticalStep(_ direction: Int, columns: Int) -> Int { direction * (self == .grid ? max(1, columns) : 1) }
}

public struct WindowSwitcherSettings: Codable, Equatable, Sendable {
    public var isEnabled = true
    public var shortcut: WindowShortcut = .optionTab
    public var currentAppOnly = false
    public var includeMinimized = true
    public var includeHidden = true
    public var layout: WindowLayout = .list
    public var showsPreviews = false
    /// Read only for migrating configurations written before Snapping became independent.
    public var snappingEnabled = false
    public var previewScale: Double = 1
    public static func validatedPreviewScale(_ value: Double) -> Double { value.isFinite ? min(1.5, max(0.75, value)) : 1 }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case isEnabled, shortcut, currentAppOnly, includeMinimized, includeHidden, layout, showsPreviews, snappingEnabled, previewScale
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        shortcut = try values.decode(WindowShortcut.self, forKey: .shortcut)
        currentAppOnly = try values.decode(Bool.self, forKey: .currentAppOnly)
        includeMinimized = try values.decode(Bool.self, forKey: .includeMinimized)
        includeHidden = try values.decode(Bool.self, forKey: .includeHidden)
        layout = try values.decodeIfPresent(WindowLayout.self, forKey: .layout) ?? .list
        showsPreviews = try values.decodeIfPresent(Bool.self, forKey: .showsPreviews) ?? false
        snappingEnabled = try values.decodeIfPresent(Bool.self, forKey: .snappingEnabled) ?? false
        previewScale = Self.validatedPreviewScale(try values.decodeIfPresent(Double.self, forKey: .previewScale) ?? 1)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(shortcut, forKey: .shortcut)
        try values.encode(currentAppOnly, forKey: .currentAppOnly)
        try values.encode(includeMinimized, forKey: .includeMinimized)
        try values.encode(includeHidden, forKey: .includeHidden)
        try values.encode(layout, forKey: .layout)
        try values.encode(showsPreviews, forKey: .showsPreviews)
        try values.encode(Self.validatedPreviewScale(previewScale), forKey: .previewScale)
    }

}

public struct WindowItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var processID: Int32
    public var appName: String
    public var bundleIdentifier: String
    public var title: String
    public var isMinimized: Bool
    public var isHidden: Bool
    /// Original Accessibility title and screen-space frame, used only for conservative preview matching.
    public var captureTitle: String
    public var frame: CGRect?
    public init(id: UUID = UUID(), processID: Int32, appName: String, bundleIdentifier: String, title: String, isMinimized: Bool = false, isHidden: Bool = false, frame: CGRect? = nil) {
        self.id = id; self.processID = processID; self.appName = appName; self.bundleIdentifier = bundleIdentifier
        self.captureTitle = title; self.frame = frame
        self.title = title.isEmpty ? "Untitled window" : title
        self.isMinimized = isMinimized; self.isHidden = isHidden
    }
}

/// Eligibility describes switchable application windows, independently of Space or visibility.
public enum WindowEligibility {
    public static func isEligible(role: String?, subrole: String?, isMain: Bool? = nil, mainIsSettable: Bool? = nil) -> Bool {
        guard role == "AXWindow" else { return false }
        switch subrole {
        case "AXStandardWindow":
            // AXMain describes current status, and read-only/unsupported AX does not disqualify a real window.
            return true
        case "AXDialog":
            // Keep independently addressable dialogs with positive main evidence. Writability is only
            // a conservative fallback; it is not the same contract as NSWindow.canBecomeMain.
            return isMain == true || mainIsSettable == true
        default:
            return false
        }
    }
}

public enum WindowOrdering {
    public static func candidates(_ windows: [WindowItem], settings: WindowSwitcherSettings, currentProcessID: Int32?) -> [WindowItem] {
        windows.filter {
            (settings.includeMinimized || !$0.isMinimized) && (settings.includeHidden || !$0.isHidden) &&
            (!settings.currentAppOnly || $0.processID == currentProcessID)
        }
    }
    public static func recentFirst(_ windows: [WindowItem], history: [UUID], focusedID: UUID?) -> [WindowItem] {
        var ids = history
        if let focusedID { ids.removeAll { $0 == focusedID }; ids.insert(focusedID, at: 0) }
        let rank = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return windows.enumerated().sorted {
            let a = rank[$0.element.id] ?? Int.max, b = rank[$1.element.id] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}

/// The order stays fixed while the chooser is open, even as focus changes.
public struct WindowSelection: Sendable {
    public private(set) var ids: [UUID] = []
    public private(set) var selectedID: UUID?
    public init() {}
    public mutating func begin(ids: [UUID], focusedID: UUID?, direction: Int = 1) {
        self.ids = ids
        guard !ids.isEmpty else { selectedID = nil; return }
        if let focusedID, let index = ids.firstIndex(of: focusedID) {
            selectedID = ids[wrapped(index + direction, count: ids.count)]
        } else { selectedID = ids[wrapped(direction > 0 ? direction - 1 : direction, count: ids.count)] }
    }
    public mutating func step(_ direction: Int) {
        guard !ids.isEmpty else { selectedID = nil; return }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedID = ids[wrapped(index + direction, count: ids.count)]
    }
    public mutating func select(_ id: UUID) { if ids.contains(id) { selectedID = id } }
    public mutating func retain(_ available: Set<UUID>) {
        ids = ids.filter { available.contains($0) }
        if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
    }
    private func wrapped(_ index: Int, count: Int) -> Int { ((index % count) + count) % count }
}

/// Repeated gestures cycle a stable list instead of bouncing between the two newest windows.
public struct WindowGestureCycle: Sendable {
    private var selection = WindowSelection()
    private var lastTime: Double = -.infinity
    public init() {}
    public mutating func next(ids: [UUID], focusedID: UUID?, direction: Int, at time: Double) -> UUID? {
        if time >= lastTime && time - lastTime < 1.5 && selection.selectedID == focusedID && Set(selection.ids) == Set(ids) {
            selection.step(direction)
        } else { selection.begin(ids: ids, focusedID: focusedID, direction: direction) }
        lastTime = time
        return selection.selectedID
    }
}

/// Public ScreenCaptureKit metadata, kept separate from private Accessibility identity.
public struct WindowPreviewCandidate: Equatable, Sendable {
    public var id: UInt32
    public var processID: Int32
    public var title: String?
    public var frame: CGRect
    public init(id: UInt32, processID: Int32, title: String?, frame: CGRect) {
        self.id = id; self.processID = processID; self.title = title; self.frame = frame
    }
}

public enum WindowPreviewPolicy {
    public static let cacheLimit = 32
    public static let concurrencyLimit = 2
    public static func imageSize(for frame: CGRect) -> CGSize? {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let scale = min(1, 480 / frame.width, 300 / frame.height)
        return CGSize(width: max(1, floor(frame.width * scale)), height: max(1, floor(frame.height * scale)))
    }
    public static func uniqueMatch(for item: WindowItem, windows: [WindowItem], candidates: [WindowPreviewCandidate]) -> UInt32? {
        guard !item.isHidden, !item.isMinimized, !item.captureTitle.isEmpty, let frame = item.frame,
              imageSize(for: frame) != nil, frame.origin.x.isFinite, frame.origin.y.isFinite else { return nil }
        // Both sides must be unique; a duplicated AX window must never share a screenshot.
        let peers = windows.filter { $0.processID == item.processID && $0.captureTitle == item.captureTitle && $0.frame == frame }
        guard peers.count == 1, peers.first?.id == item.id else { return nil }
        let matches = candidates.filter { $0.processID == item.processID && $0.title == item.captureTitle && $0.frame == frame }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }
}

/// Native capture callbacks cannot be cancelled; a generation rejects results after any lifecycle change.
public struct WindowPreviewLifetime: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isActive = false
    public init() {}
    @discardableResult public mutating func begin() -> UInt64 { generation &+= 1; isActive = true; return generation }
    public mutating func end() { generation &+= 1; isActive = false }
    public func accepts(_ token: UInt64) -> Bool { isActive && generation == token }
}

public enum WindowChooserGeometry {
    public static func size(available: CGSize, layout: WindowLayout, previews: Bool, previewScale: Double = 1) -> CGSize {
        CGSize(width: max(1, min(max(1, available.width - 32), layout == .grid ? 900 : (previews ? 660 * WindowSwitcherSettings.validatedPreviewScale(previewScale) : 570))),
               height: max(1, min(max(1, available.height - 32), layout == .grid || previews ? 580 : 420)))
    }
    public static func columns(width: Double, previews: Bool, previewScale: Double = 1) -> Int {
        max(1, Int((max(1, width) - 24) / (previews ? 210 * WindowSwitcherSettings.validatedPreviewScale(previewScale) : 170)))
    }
}
