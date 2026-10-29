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
    /// Returns whether the synchronous body ran. Unsupported adapters remain paced.
    func withImmediateUpdates(isCurrent: () -> Bool, _ body: () -> Void) -> Bool
}
public extension WindowSnapWindowAccess {
    func withImmediateUpdates(isCurrent: () -> Bool, _ body: () -> Void) -> Bool { false }
}

/// A synchronous lease only. Cleanup deliberately ignores session eligibility:
/// accepted mode changes still need restoration after cancellation or focus loss.
public enum WindowSnapImmediateUpdates {
    @discardableResult public static func perform(assistiveTechnologyEnabled: Bool,
        isEligible: () -> Bool, readMode: () -> Bool?, writeMode: (Bool) -> Bool,
        diagnostic: (String) -> Void = { _ in }, body: () -> Void) -> Bool {
        guard !assistiveTechnologyEnabled, isEligible() else { return false }
        guard let original = readMode(), isEligible() else { diagnostic("enhanced_ui_unavailable"); return false }
        if !original {
            diagnostic("enhanced_ui_already_disabled")
            guard isEligible() else { return false }
            body()
            return true
        }
        guard isEligible() else { return false }
        // Owe cleanup before the call: a rejected setter may still have changed it.
        defer {
            var restored = false
            for _ in 0..<2 {
                _ = writeMode(true)
                if readMode() == true { restored = true; break }
            }
            diagnostic(restored ? "enhanced_ui_restore_verified" : "enhanced_ui_restore_failed")
        }
        let disabled = writeMode(false)
        guard isEligible(), disabled, isEligible() else { return false }
        guard readMode() == false, isEligible() else { diagnostic("enhanced_ui_disable_unconfirmed"); return false }
        diagnostic("enhanced_ui_disabled")
        body()
        return true
    }
}

/// A move is established by actual window translation, then survives OS edge clamping.
/// Any observed resize permanently disqualifies that mouse-down session.
public struct WindowSnapDrag {
    public let initial: CGRect
    public let down: CGPoint
    public private(set) var confirmed = false
    public private(set) var invalidated = false
    private struct Observation {
        var time: TimeInterval
        var frame: CGRect
        var pointer: CGPoint
    }
    private var recentObservations: [Observation] = []
    private var lastObservationTime: TimeInterval?
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
    @discardableResult public mutating func observe(frame: CGRect, pointer: CGPoint, topBoundary: CGFloat? = nil,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !invalidated else { return false }
        guard abs(frame.width-initial.width) < 2, abs(frame.height-initial.height) < 2 else {
            invalidated = true; return false
        }
        // AX can repeat an old frame while the pointer continues, then jump to
        // a position associated with an earlier pointer. Keep only a brief,
        // bounded causal history; a clock reset must not reuse future evidence.
        if !time.isFinite || lastObservationTime.map({ time <= $0 }) == true {
            recentObservations.removeAll(keepingCapacity: true)
        }
        lastObservationTime = time.isFinite ? time : nil
        recentObservations.removeAll { time - $0.time > 0.25 }
        if time.isFinite {
            recentObservations.append(Observation(time: time, frame: frame, pointer: pointer))
            if recentObservations.count > 12 { recentObservations.removeFirst(recentObservations.count - 12) }
        }
        if !confirmed {
            let pointerDelta = CGPoint(x: pointer.x-down.x, y: pointer.y-down.y)
            confirmed = WindowSnapping.isMove(initial: initial, current: frame,
                pointerDelta: pointerDelta, topBoundary: topBoundary)
            if !confirmed, let earlierFrame {
                confirmed = WindowSnapping.isMove(initial: earlierFrame, current: frame,
                    pointerDelta: pointerDelta, topBoundary: topBoundary)
            }
            if !confirmed {
                for baselineIndex in recentObservations.indices {
                    let baseline = recentObservations[baselineIndex]
                    for endpoint in recentObservations.dropFirst(baselineIndex + 1) {
                        if WindowSnapping.isMove(initial: baseline.frame, current: frame,
                            pointerDelta: CGPoint(x: endpoint.pointer.x-baseline.pointer.x,
                                                  y: endpoint.pointer.y-baseline.pointer.y), topBoundary: topBoundary) {
                            confirmed = true
                            break
                        }
                    }
                    if confirmed { break }
                }
            }
        }
        // Preserve real upward motion while qualification catches up with AX;
        // a later confirmed frame may already be back at the top boundary.
        let baselines = [initial, earlierFrame, observedFrame].compactMap { $0 }
        if baselines.contains(where: { $0.minY - frame.minY >= 8 }) { upwardMoveProven = true }
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

/// Release-time AX success is provisional: the owning app can still finish its native drag.
/// The adapter schedules observations on its serial worker, never blocking an input callback.
public struct WindowSnapApplication {
    public let target: CGRect
    public private(set) var attempts = 0
    private var pacedAttempts = 0
    private enum Phase { case ready, moving, sizing, correcting, retaining }
    private var phase = Phase.ready
    private var observations = 0
    private var previousObservation: CGRect?
    private var stableObservations = 0
    private var initialFrame: CGRect?
    private var fastTried = false
    private var fastObservations: Int?
    private var fastMatchingObservations = 0
    private var fastAccepted = false
    private var finished: Result?
    public init(target: CGRect) { self.target = target }
    public static func matches(_ frame: CGRect, _ target: CGRect) -> Bool {
        abs(frame.minX-target.minX) < 2 && abs(frame.minY-target.minY) < 2 &&
        abs(frame.width-target.width) < 2 && abs(frame.height-target.height) < 2
    }
    public enum Result { case pending, succeeded, limited, failed }
    private mutating func finish(_ result: Result) -> Result { finished = result; return result }
    private mutating func awaitSettlement(_ phase: Phase) {
        self.phase = phase
        previousObservation = nil
        stableObservations = 0
    }
    private mutating func retain(_ frame: CGRect, diagnostic: (String, CGRect?) -> Void) -> Result {
        guard let initialFrame, !Self.matches(frame, initialFrame) else { return finish(.failed) }
        diagnostic("retained_limited", frame)
        return finish(.limited)
    }
    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite &&
        frame.width.isFinite && frame.height.isFinite
    }
    private static func applyImmediately(window: WindowSnapWindowAccess, target: CGRect,
        isCurrent: () -> Bool, onWrite: () -> Void) -> Bool {
        func eligible() -> Bool { isCurrent() && window.isEligibleAndActive() && isCurrent() }
        func read() -> CGRect? {
            guard eligible(), let frame = window.readFrame(), eligible(), validFrame(frame) else { return nil }
            return frame
        }
        guard var frame = read() else { return false }
        if abs(frame.minX-target.minX) >= 2 || abs(frame.minY-target.minY) >= 2 {
            guard eligible() else { return false }
            onWrite()
            guard window.setPosition(target.origin), eligible(), let moved = read() else { return false }
            frame = moved
        }
        if abs(frame.width-target.width) >= 2 || abs(frame.height-target.height) >= 2 {
            guard eligible() else { return false }
            onWrite()
            guard window.setSize(target.size), eligible(), let resized = read() else { return false }
            frame = resized
        }
        if abs(frame.minX-target.minX) >= 2 || abs(frame.minY-target.minY) >= 2 {
            guard eligible() else { return false }
            onWrite()
            guard window.setPosition(target.origin), eligible(), read() != nil else { return false }
        }
        return true
    }
    /// Try one scoped immediate change and verify it across scheduled readbacks.
    /// If unavailable or unsuccessful, paced writes wait for three stable readings
    /// between attributes to let asynchronous frame updates settle.
    public mutating func advance(window: WindowSnapWindowAccess, diagnostic: (String, CGRect?) -> Void = { _, _ in }, isCurrent: () -> Bool) -> Result {
        if let finished { return finished }
        // With the monitor's 100ms cadence, even an ever-changing owner ends in
        // about 4.4 seconds. At most one fast batch and three paced passes can issue effects.
        guard observations < 44 else { return finish(.failed) }
        observations += 1
        guard isCurrent(), window.isEligibleAndActive(), isCurrent(), let frame = window.readFrame(),
              isCurrent(), window.isEligibleAndActive(), isCurrent(), Self.validFrame(frame) else { return finish(.failed) }
        diagnostic("readback", frame)
        if initialFrame == nil { initialFrame = frame }
        if let count = fastObservations {
            fastObservations = count + 1
            fastMatchingObservations = Self.matches(frame, target) ? fastMatchingObservations + 1 : 0
            guard count + 1 >= 3 else { return .pending }
            fastObservations = nil
            if fastAccepted, fastMatchingObservations >= 3 {
                diagnostic("fast_verified", frame)
                return finish(.succeeded)
            }
            diagnostic("fast_fallback", frame)
            awaitSettlement(.ready)
        }
        if let previousObservation, Self.matches(frame, previousObservation) { stableObservations += 1 }
        else { stableObservations = 1 }
        previousObservation = frame
        if phase == .ready, Self.matches(frame, target) {
            return stableObservations >= 2 ? finish(.succeeded) : .pending
        }
        if stableObservations >= 3, Self.matches(frame, target) { return finish(.succeeded) }
        if phase == .ready, !fastTried {
            fastTried = true
            diagnostic("fast_attempt", frame)
            var accepted = false
            var wrote = false
            let ran = window.withImmediateUpdates(isCurrent: isCurrent) {
                accepted = Self.applyImmediately(window: window, target: target, isCurrent: isCurrent, onWrite: { wrote = true })
            }
            if wrote { attempts += 1 }
            guard isCurrent(), window.isEligibleAndActive(), isCurrent() else { return finish(.failed) }
            if ran {
                if !accepted { diagnostic("fast_batch_failed", nil) }
                fastAccepted = accepted
                fastObservations = 0
                fastMatchingObservations = 0
                previousObservation = nil
                stableObservations = 0
                return .pending
            }
            diagnostic("fast_unavailable", frame)
        }
        if phase != .ready {
            guard stableObservations >= 3 else { return .pending }
            if phase == .retaining { return retain(frame, diagnostic: diagnostic) }
        }
        let next: Phase
        switch phase {
        case .ready:
            next = .moving
        case .moving:
            next = .sizing
        case .sizing:
            if abs(frame.minX-target.minX) >= 2 || abs(frame.minY-target.minY) >= 2 {
                next = .correcting
            } else {
                if pacedAttempts >= 3 { return retain(frame, diagnostic: diagnostic) }
                next = .moving
            }
        case .correcting:
            if pacedAttempts >= 3 { return retain(frame, diagnostic: diagnostic) }
            next = .moving
        case .retaining:
            return retain(frame, diagnostic: diagnostic)
        }
        guard isCurrent(), window.isEligibleAndActive(), isCurrent() else { return finish(.failed) }
        let accepted: Bool
        if next == .sizing {
            accepted = window.setSize(target.size)
        } else {
            if next == .moving { attempts += 1; pacedAttempts += 1 }
            accepted = window.setPosition(target.origin)
        }
        guard isCurrent(), window.isEligibleAndActive(), isCurrent() else { return finish(.failed) }
        awaitSettlement(accepted ? next : .retaining)
        return .pending
    }
}
