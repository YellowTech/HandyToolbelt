import Foundation

public struct TipTapSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let direction: GestureKind
    public let anchor: TouchPoint
    public let tapper: TouchPoint
    public let angleDegrees: Double
    public let holdTime: Double
    public let tapTime: Double
    public let travel: Double
    public let separation: Double
    public init(direction: GestureKind, anchor: TouchPoint, tapper: TouchPoint, angleDegrees: Double,
                holdTime: Double, tapTime: Double, travel: Double, separation: Double) {
        id = UUID(); self.direction = direction; self.anchor = anchor; self.tapper = tapper
        self.angleDegrees = angleDegrees; self.holdTime = holdTime; self.tapTime = tapTime
        self.travel = travel; self.separation = separation
    }
}

/// Collects deliberate, labelled attempts independently of the current detection thresholds.
/// Otherwise calibration would only learn gestures the old settings already accept.
public struct TipTapCalibration {
    public enum Outcome: Equatable { case accepted(TipTapSample), rejected(String) }
    private struct Track {
        var origin: TouchPoint
        var point: TouchPoint
        var began: Double
        var travel: Double = 0
    }
    private struct Attempt {
        let anchorID: Int
        let tapperID: Int
        let anchor: TouchPoint
        let tapper: TouchPoint
        let began: Double
        let holdTime: Double
        let direction: GestureKind
        let aspect: Double
    }
    public private(set) var samples: [TipTapSample] = []
    private var tracks: [Int: Track] = [:]
    private var attempt: Attempt?
    private var lastTime: Double?
    public init() {}
    public var leftCount: Int { samples.filter { $0.direction == .tipTapLeft }.count }
    public var rightCount: Int { samples.filter { $0.direction == .tipTapRight }.count }
    public var isComplete: Bool { leftCount >= 3 && rightCount >= 3 }
    public var nextDirection: GestureKind { leftCount < 3 ? .tipTapLeft : .tipTapRight }

    public mutating func process(_ contacts: [Contact], at time: Double, aspectRatio: Double, physicalButtonDown: Bool = false) -> Outcome? {
        guard !isComplete else { return nil }
        let ids = Set(contacts.map(\.id))
        guard time.isFinite, ids.count == contacts.count, contacts.count <= 10,
              contacts.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && (0...1).contains($0.position.x) && (0...1).contains($0.position.y) }) else {
            tracks = [:]; attempt = nil; lastTime = nil; return nil
        }
        if let lastTime, time < lastTime || time - lastTime > 0.8 { tracks = [:]; attempt = nil }
        lastTime = time
        let old = tracks
        let added = ids.subtracting(old.keys)
        for contact in contacts {
            var t = tracks[contact.id] ?? Track(origin: contact.position, point: contact.position, began: time)
            t.point = contact.position
            t.travel = max(t.travel, t.origin.distance(to: t.point))
            tracks[contact.id] = t
        }
        defer { tracks = tracks.filter { ids.contains($0.key) } }
        if attempt == nil, ids.count == 2, added.count == 1,
           let tapperID = added.first, let anchorID = ids.subtracting(added).first,
           let anchor = old[anchorID], let tapper = tracks[tapperID] {
            guard time - anchor.began >= 0.05 else { return .rejected("Rest one finger first, then tap with the other.") }
            attempt = Attempt(anchorID: anchorID, tapperID: tapperID, anchor: anchor.point, tapper: tapper.point,
                              began: time, holdTime: time - anchor.began, direction: nextDirection, aspect: GestureTuning.safeAspect(aspectRatio))
        }
        guard let current = attempt else { return nil }
        let travel = max(tracks[current.anchorID]?.travel ?? 1, tracks[current.tapperID]?.travel ?? 1)
        let duration = time - current.began
        if physicalButtonDown || !ids.contains(current.anchorID) || ids.count > 2 || duration > 0.80 || travel > 0.12 {
            attempt = nil
            if physicalButtonDown { return .rejected("That was a click. Tap lightly without pressing.") }
            if !ids.contains(current.anchorID) { return .rejected("Keep the resting finger down when the tapping finger lifts.") }
            if ids.count > 2 { return .rejected("Use just the resting finger and one tapping finger.") }
            if duration > 0.80 { return .rejected("That tap was held too long. Try a shorter tap.") }
            return .rejected("Too much movement to use this sample. Rest and tap without sliding.")
        }
        guard !ids.contains(current.tapperID) else { return nil }
        attempt = nil
        guard duration >= 0.025 else { return .rejected("The contact was too brief to measure reliably. Try again.") }
        var dx = current.tapper.x - current.anchor.x
        var dy = (current.tapper.y - current.anchor.y) / current.aspect
        if current.direction == .tipTapLeft { dx = -dx; dy = -dy }
        guard dx > 0.02 else { return .rejected("Tap on the requested side of your resting finger.") }
        let angle = atan2(dy, dx) * 180 / .pi
        guard abs(angle) <= 60 else { return .rejected("Place the tapping finger beside the resting finger, rather than directly above it.") }
        let sample = TipTapSample(direction: current.direction, anchor: current.anchor, tapper: current.tapper,
                                  angleDegrees: angle, holdTime: current.holdTime, tapTime: duration, travel: travel, separation: hypot(dx, dy))
        samples.append(sample)
        return .accepted(sample)
    }

    public func suggestion(from base: GestureTuning) -> GestureTuning? {
        guard isComplete else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(); let n = sorted.count
            return n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]
        }
        let angle = median(samples.map(\.angleDegrees))
        // Do not pretend to learn one hand axis from contradictory left/right examples.
        guard samples.filter({ abs($0.angleDegrees - angle) > 18 }).count <= 1,
              abs(median(samples.filter { $0.direction == .tipTapLeft }.map(\.angleDegrees)) -
                  median(samples.filter { $0.direction == .tipTapRight }.map(\.angleDegrees))) <= 18 else { return nil }
        var result = base
        result.handAngleDegrees = angle.rounded()
        result.tapDuration = min(0.80, max(0.18, (samples.map(\.tapTime).max() ?? 0.3) + 0.06))
        result.tapTravel = min(0.12, max(0.02, (samples.map(\.travel).max() ?? 0) * 1.4 + 0.01))
        result.anchorHold = min(base.anchorHold, max(0.05, (samples.map(\.holdTime).min() ?? base.anchorHold) * 0.8))
        // Project onto the learned axis, so the suggested minimum is consistent with recognition.
        let projection = samples.map { $0.separation * cos(($0.angleDegrees - angle) * .pi / 180) }.min() ?? base.tipSeparation
        result.tipSeparation = min(0.20, max(0.02, projection * 0.6))
        return result.validated
    }
}
