import Foundation
import CoreGraphics

/// Identity makes a canceled expiration harmless even after replacement.
public struct FeedbackLifetime {
    public private(set) var current: UUID?
    public init() {}
    @discardableResult public mutating func replace() -> UUID { let id = UUID(); current = id; return id }
    @discardableResult public mutating func expire(_ id: UUID) -> Bool {
        guard current == id else { return false }
        current = nil; return true
    }
    public mutating func cancel() { current = nil }
}

public enum FeedbackGeometry {
    public static func frame(size: CGSize, visibleFrame: CGRect, top: Bool, screenFrame: CGRect? = nil) -> CGRect {
        let inset = min(16, max(0, min(visibleFrame.width, visibleFrame.height) / 8))
        let area = visibleFrame.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(max(0, size.width), area.width), height: min(max(0, size.height), area.height))
        let center = screenFrame ?? visibleFrame
        let x = min(max(center.midX - size.width / 2, area.minX), area.maxX - size.width)
        let y = top ? area.maxY - size.height
            : min(max(center.midY - size.height / 2, area.minY), area.maxY - size.height)
        return CGRect(x: x,
                      y: y,
                      width: size.width, height: size.height)
    }
}
