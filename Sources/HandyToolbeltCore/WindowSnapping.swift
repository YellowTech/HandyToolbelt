import Foundation

/// Geometry uses the public CG/Accessibility global coordinate system (top-left origin).
public enum WindowSnapping {
    /// Public event routing identifies the actual input handler even beneath a cursor or
    /// click-through overlay. An unknown nonzero handler never falls through to another window.
    public static func selectWindow(at point: CGPoint, candidates: [WindowSnapCandidate], ownPID: Int32,
        handlingWindowID: UInt32? = nil, eventTargetPID: Int32? = nil) -> WindowSnapSelection {
        let method: String
        let surface: WindowSnapCandidate?
        if let handlingWindowID, handlingWindowID != 0 {
            method = "event_handling_window"
            surface = candidates.first { $0.windowID == handlingWindowID }
            if surface == nil { return WindowSnapSelection(method: method, rejection: "event_handler_metadata_unavailable") }
        } else {
            method = "first_containing_surface"
            surface = candidates.first { $0.alpha > 0 && $0.frame.contains(point) }
        }
        guard let surface else { return WindowSnapSelection(method: method, rejection: "no_containing_surface") }
        guard surface.processID != ownPID else { return WindowSnapSelection(method: method, rejection: "own_process") }
        guard surface.processID > 0, surface.layer == 0, surface.alpha > 0 else {
            return WindowSnapSelection(method: method, rejection: "nonstandard_surface")
        }
        if let eventTargetPID, eventTargetPID > 0, eventTargetPID != surface.processID {
            return WindowSnapSelection(method: method, rejection: "event_target_pid_mismatch")
        }
        return WindowSnapSelection(candidate: surface, method: method)
    }
    /// Conservative fallback for callers without authoritative handling-window metadata.
    public static func hitProcess(at point: CGPoint, candidates: [WindowSnapCandidate], ownPID: Int32) -> Int32? {
        selectWindow(at: point, candidates: candidates, ownPID: ownPID).candidate?.processID
    }
    public static func eligible(macOSMajorVersion: Int, separateSpaces: Bool) -> Bool {
        macOSMajorVersion < 15 || !separateSpaces
    }
    public static func cgRect(_ appKitRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryTop - appKitRect.maxY, width: appKitRect.width, height: appKitRect.height)
    }
    public static func target(pointer: CGPoint, screen: CGRect, visible: CGRect, edge: CGFloat = 12) -> CGRect? {
        guard screen.contains(pointer), visible.width > 0, visible.height > 0 else { return nil }
        let left = pointer.x <= screen.minX + edge
        let right = pointer.x >= screen.maxX - edge
        // AppKit stops the titlebar at the work-area/menu-bar boundary.
        let top = pointer.y <= max(screen.minY, visible.minY) + edge
        let bottom = pointer.y >= screen.maxY - edge
        if (left || right) && (top || bottom) {
            return CGRect(x: left ? visible.minX : visible.midX, y: top ? visible.minY : visible.midY,
                          width: visible.width / 2, height: visible.height / 2)
        }
        if top { return visible }
        if left || right {
            return CGRect(x: left ? visible.minX : visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        }
        return nil
    }
    public static func isMove(initial: CGRect, current: CGRect, pointerDelta: CGPoint, topBoundary: CGFloat? = nil) -> Bool {
        let dx = current.minX - initial.minX, dy = current.minY - initial.minY
        guard abs(current.width - initial.width) < 2, abs(current.height - initial.height) < 2,
              hypot(dx, dy) >= 8 else { return false }
        if hypot(dx - pointerDelta.x, dy - pointerDelta.y) < 12 { return true }
        // A first observation may already be clamped under the menu bar. Require
        // real upward window translation to that exact boundary, while the free
        // horizontal axis still follows the pointer. A stationary/content drag or
        // an already-top horizontal drag cannot establish movement by this path.
        guard let topBoundary, abs(current.minY - topBoundary) < 2, dy <= -8,
              pointerDelta.y <= dy, abs(dx - pointerDelta.x) < 12 else { return false }
        return true
    }
}

/// Generation boundary shared by input capture, AX identity resolution and asynchronous results.
/// Callers serialize access; resolving a stale down can never establish a replacement target.
public struct WindowSnapSession: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var targetPID: Int32?
    public init() {}
    public mutating func invalidate() { generation &+= 1; targetPID = nil }
    public func isCurrent(_ token: UInt64) -> Bool { token == generation }
    @discardableResult public mutating func resolve(pid: Int32, token: UInt64) -> Bool {
        guard isCurrent(token) else { return false }; targetPID = pid; return true
    }
    /// The mouse-down may itself activate its target before the worker has resolved identity.
    @discardableResult public mutating func activated(pid: Int32) -> Bool {
        guard let targetPID, targetPID != pid else { return false }
        invalidate(); return true
    }
}

/// The AX adapter implements these synchronous operations on the monitor's serial worker.
public protocol WindowSnapWindowAccess: AnyObject {
    var processID: Int32 { get }
    func isEligibleAndActive() -> Bool
    func readFrame() -> CGRect?
    func setSize(_ size: CGSize) -> Bool
    func setPosition(_ point: CGPoint) -> Bool
}

/// A move is established by actual window translation, then survives OS edge clamping.
/// Any observed resize permanently disqualifies that mouse-down session.
public struct WindowSnapDrag {
    public let initial: CGRect
    public let down: CGPoint
    public private(set) var confirmed = false
    public private(set) var invalidated = false
    private var previousFrame: CGRect?
    private var previousPointer: CGPoint?
    private let earlierFrame: CGRect?
    private var observedFrame: CGRect?
    private var upwardMoveProven = false
    /// The optional earlier frame is a public WindowServer snapshot selected by
    /// the event-handling ID before AX resolution; matching dimensions qualify
    /// it as an additional movement baseline for the app-scoped hit window.
    public init(initial: CGRect, down: CGPoint, earlierFrame: CGRect? = nil) {
        self.initial = initial; self.down = down
        if let earlierFrame, earlierFrame.contains(down),
           abs(earlierFrame.width - initial.width) < 2, abs(earlierFrame.height - initial.height) < 2 {
            self.earlierFrame = earlierFrame
        } else { self.earlierFrame = nil }
    }
    @discardableResult public mutating func observe(frame: CGRect, pointer: CGPoint, topBoundary: CGFloat? = nil) -> Bool {
        guard !invalidated else { return false }
        guard abs(frame.width-initial.width) < 2, abs(frame.height-initial.height) < 2 else {
            invalidated = true; return false
        }
        if !confirmed {
            let pointerDelta = CGPoint(x: pointer.x-down.x, y: pointer.y-down.y)
            confirmed = WindowSnapping.isMove(initial: initial, current: frame,
                pointerDelta: pointerDelta, topBoundary: topBoundary)
            if !confirmed, let earlierFrame {
                confirmed = WindowSnapping.isMove(initial: earlierFrame, current: frame,
                    pointerDelta: pointerDelta, topBoundary: topBoundary)
            }
            if !confirmed, let previousFrame, let previousPointer {
                // The first AX read can arrive after down has already moved the window.
                confirmed = WindowSnapping.isMove(initial: previousFrame, current: frame,
                    pointerDelta: CGPoint(x: pointer.x-previousPointer.x, y: pointer.y-previousPointer.y), topBoundary: topBoundary)
            }
            previousFrame = frame
            previousPointer = pointer
        }
        if confirmed {
            let baselines = [initial, earlierFrame, observedFrame].compactMap { $0 }
            if baselines.contains(where: { $0.minY - frame.minY >= 8 }) { upwardMoveProven = true }
        }
        observedFrame = frame
        return confirmed
    }
    /// Recompute on every observation/release so leaving the activation band cancels.
    /// A window already at the menu bar needs upward intent; horizontal titlebar
    /// movement there must not maximize it merely because its pointer starts in the band.
    public func target(pointer: CGPoint, screen: CGRect, visible: CGRect, edge: CGFloat = 12) -> CGRect? {
        guard confirmed, !invalidated, screen.contains(pointer) else { return nil }
        var activationPointer = pointer
        let grabOffset = down.y - (earlierFrame ?? initial).minY
        if upwardMoveProven, let observedFrame, abs(observedFrame.minY - visible.minY) < 2,
           grabOffset >= 0, grabOffset <= 44,
           pointer.y <= visible.minY + max(edge, grabOffset + 2) {
            // The titlebar is already touching the menu bar, but the pointer remains
            // at its captured grab offset. Project only this qualified top intent
            // into the ordinary top/corner band; release outside it cancels again.
            activationPointer.y = min(pointer.y, visible.minY + edge)
        }
        guard let target = WindowSnapping.target(pointer: activationPointer, screen: screen, visible: visible, edge: edge) else { return nil }
        if target == visible, abs(initial.minY - visible.minY) < 2, !upwardMoveProven,
           down.y - pointer.y < 8 { return nil }
        return target
    }
    /// A public AX setter already in flight cannot be revoked. Token checks prevent all later writes.
    @discardableResult public mutating func commit(target: CGRect, pointer: CGPoint,
        window: WindowSnapWindowAccess, isCurrent: () -> Bool) -> Bool {
        guard isCurrent(), window.isEligibleAndActive(), let frame = window.readFrame(),
              observe(frame: frame, pointer: pointer), isCurrent() else { return false }
        guard window.setSize(target.size), isCurrent(), let resized = window.readFrame() else { return false }
        guard abs(resized.width-target.width) < 2, abs(resized.height-target.height) < 2 else {
            // Apps can report success while enforcing their minimum size. Restore once, best effort.
            if isCurrent(), window.isEligibleAndActive(), isCurrent() { _ = window.setSize(frame.size) }
            return false
        }
        guard window.isEligibleAndActive(), isCurrent() else { return false }
        return window.setPosition(target.origin)
    }
}

/// Immutable public WindowServer metadata; selecting a PID performs no AX requests.
public struct WindowSnapCandidate {
    public var processID: Int32
    public var windowID: UInt32?
    public var frame: CGRect
    public var layer: Int
    public var alpha: Double
    public init(processID: Int32, frame: CGRect, layer: Int = 0, alpha: Double = 1, windowID: UInt32? = nil) {
        self.processID = processID; self.windowID = windowID; self.frame = frame; self.layer = layer; self.alpha = alpha
    }
}

public struct WindowSnapSelection {
    public var candidate: WindowSnapCandidate?
    public var method: String
    public var rejection: String?
    public init(candidate: WindowSnapCandidate? = nil, method: String, rejection: String? = nil) {
        self.candidate = candidate; self.method = method; self.rejection = rejection
    }
}

/// A single bounded interaction summary. Never stores window content, titles or input paths.
public struct WindowSnapDiagnostics: Codable, Equatable, Sendable {
    public var generation: UInt64 = 0
    public var stage = "idle"
    public var reason: String?
    public var mouseDownCount = 0
    public var mouseDragCount = 0
    public var mouseUpCount = 0
    public var processedDragCount = 0
    public var selectedPID: Int32?
    public var firstContainingLayer: Int?
    public var firstContainingPID: Int32?
    public var eventTargetPID: Int32?
    public var eventHandlingWindowID: UInt32?
    public var eventUnderPointerWindowID: UInt32?
    public var axHitError: Int32?
    public var axResults: [String: Int32] = [:]
    public var routingMethod: String?
    public var resolutionMethod: String?
    public var resolved = false
    public var movementConfirmed = false
    public var targetFound = false
    public var commitSucceeded: Bool?
    public var completed = false
    public init() {}
}

/// Fixed-size runtime evidence survives subsequent ordinary clicks.
public struct WindowSnapDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var totalMouseDownCount = 0
    public var totalMouseDragCount = 0
    public var totalMouseUpCount = 0
    public var latestInteraction = WindowSnapDiagnostics()
    public var completedDrags: [WindowSnapDiagnostics] = []
    public init() {}
    public mutating func recordCompletedDrag(_ interaction: WindowSnapDiagnostics) {
        guard interaction.completed, interaction.mouseDragCount > 0 else { return }
        completedDrags.append(interaction)
        if completedDrags.count > 8 { completedDrags.removeFirst(completedDrags.count - 8) }
    }
}
