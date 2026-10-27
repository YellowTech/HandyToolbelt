import Foundation

public struct GestureTuning: Codable, Equatable, Sendable {
    public var longTouchDuration = 0.55
    public var doubleTapInterval = 0.28
    public var tapDuration = 0.30
    public var tapTravel = 0.035
    public var anchorHold = 0.16
    public var cornerHold = 0.25
    public var swipeTravel = 0.13
    public var handAngleDegrees = 0.0
    public var tipSeparation = 0.055
    public var tipMaxSeparation = 0.45
    public var tipEdgeDeadzone = 0.04
    public var cornerSize = 0.22
    public init() {}

    private enum CodingKeys: String, CodingKey { case tipMaxSeparation, tipEdgeDeadzone, tapDuration, tapTravel, anchorHold, cornerHold, swipeTravel, handAngleDegrees, tipSeparation, cornerSize, longTouchDuration, doubleTapInterval }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tipMaxSeparation = try values.decodeIfPresent(Double.self, forKey: .tipMaxSeparation) ?? tipMaxSeparation
        tipEdgeDeadzone = try values.decodeIfPresent(Double.self, forKey: .tipEdgeDeadzone) ?? tipEdgeDeadzone
        tapDuration = try values.decode(Double.self, forKey: .tapDuration)
        tapTravel = try values.decode(Double.self, forKey: .tapTravel)
        anchorHold = try values.decode(Double.self, forKey: .anchorHold)
        cornerHold = try values.decode(Double.self, forKey: .cornerHold)
        swipeTravel = try values.decode(Double.self, forKey: .swipeTravel)
        handAngleDegrees = try values.decode(Double.self, forKey: .handAngleDegrees)
        tipSeparation = try values.decode(Double.self, forKey: .tipSeparation)
        cornerSize = try values.decode(Double.self, forKey: .cornerSize)
        longTouchDuration = try values.decodeIfPresent(Double.self, forKey: .longTouchDuration) ?? longTouchDuration
        doubleTapInterval = try values.decodeIfPresent(Double.self, forKey: .doubleTapInterval) ?? doubleTapInterval
    }

    /// Shared normalization, UI, and control contract limits.
    public static let bounds: [String: ClosedRange<Double>] = [
        "longTouchDuration": 0.30...1.50,
        "doubleTapInterval": 0.15...0.60,
        "tapDuration": 0.10...0.80,
        "tapTravel": 0.01...0.12,
        "anchorHold": 0.05...0.50,
        "cornerHold": 0.10...0.80,
        "swipeTravel": 0.05...0.35,
        "handAngleDegrees": -60...60,
        "tipSeparation": 0.02...0.20,
        "cornerSize": 0.10...0.35,
        "tipMaxSeparation": 0.15...0.80,
        "tipEdgeDeadzone": 0...0.15,
    ]

    public var validated: Self {
        var result = self
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.longTouchDuration = clamp(longTouchDuration, Self.bounds["longTouchDuration"]!, 0.55)
        result.doubleTapInterval = clamp(doubleTapInterval, Self.bounds["doubleTapInterval"]!, 0.28)
        result.tapDuration = clamp(tapDuration, Self.bounds["tapDuration"]!, 0.30)
        result.tapTravel = clamp(tapTravel, Self.bounds["tapTravel"]!, 0.035)
        result.anchorHold = clamp(anchorHold, Self.bounds["anchorHold"]!, 0.16)
        result.cornerHold = clamp(cornerHold, Self.bounds["cornerHold"]!, 0.25)
        result.swipeTravel = clamp(swipeTravel, Self.bounds["swipeTravel"]!, 0.13)
        result.handAngleDegrees = clamp(handAngleDegrees, Self.bounds["handAngleDegrees"]!, 0)
        result.tipSeparation = clamp(tipSeparation, Self.bounds["tipSeparation"]!, 0.055)
        result.tipMaxSeparation = clamp(tipMaxSeparation, Self.bounds["tipMaxSeparation"]!, 0.45)
        result.tipEdgeDeadzone = clamp(tipEdgeDeadzone, Self.bounds["tipEdgeDeadzone"]!, 0.04)
        result.cornerSize = clamp(cornerSize, Self.bounds["cornerSize"]!, 0.22)
        return result
    }

    /// Distances along the hand axis use surface-width units; compensate for trackpad aspect ratio.
    public func projectedSeparation(from anchor: TouchPoint, to tapper: TouchPoint, aspectRatio: Double) -> Double {
        let angle = handAngleDegrees * .pi / 180
        return (tapper.x - anchor.x) * cos(angle) + (tapper.y - anchor.y) / Self.safeAspect(aspectRatio) * sin(angle)
    }
    public static func safeAspect(_ aspect: Double) -> Double { aspect.isFinite && (0.5...4).contains(aspect) ? aspect : 1.6 }
}

public enum DetectionPhase: String, Sendable {
    case idle, holding, candidate, recognized, rejected
}

public struct DetectionFeedback: Equatable, Sendable {
    public var phase: DetectionPhase = .idle
    public var message = "Rest a finger to begin."
    public var anchorID: Int?
    public var tapperID: Int?
    public var anchorPosition: TouchPoint?
    public var tapperPosition: TouchPoint?
    public var holdTime: Double = 0
    public var tapTime: Double = 0
    public var travel: Double = 0
    public var separation: Double = 0
    public var fingerCount: Int = 0
    public var gesture: GestureSpec?
    public init() {}
}
