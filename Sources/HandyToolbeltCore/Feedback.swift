import Foundation

public enum HapticPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, light, click, firm, doubleClick, strongDouble
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light click"
        case .click: return "Click"
        case .firm: return "Firm click"
        case .doubleClick: return "Double click"
        case .strongDouble: return "Strong double"
        }
    }
    public enum Pulse: Sendable { case alignment, generic, levelChange }
    public var pulses: [(delay: Double, pulse: Pulse)] {
        switch self {
        case .off: return []
        case .light: return [(0, .alignment)]
        case .click: return [(0, .generic)]
        case .firm: return [(0, .levelChange)]
        case .doubleClick: return [(0, .generic), (0.11, .generic)]
        case .strongDouble: return [(0, .levelChange), (0.085, .levelChange)]
        }
    }
}

public enum PressKind: Int, Equatable, Sendable {
    case touch = 0, click = 1, forceClick = 2
    public var title: String {
        switch self { case .touch: return "Touch"; case .click: return "Click"; case .forceClick: return "Force click" }
    }
}

/// Presentation state only. A force click comes from macOS stage 2, never a guessed
/// threshold in the uncalibrated multitouch pressure signal.
public struct PressFeedback: Equatable {
    public private(set) var stage: PressKind = .touch
    public private(set) var lastPress: PressKind = .touch
    private var beganAt: Double?
    public init() {}

    public mutating func update(stage: Int, at time: Double) {
        guard time.isFinite, (0...2).contains(stage) else { return }
        let next = PressKind(rawValue: stage)!
        if next.rawValue > self.stage.rawValue {
            lastPress = next; beganAt = time
        }
        self.stage = next
    }

    public func display(at time: Double) -> PressDisplay {
        let elapsed = beganAt.map { max(0, time - $0) } ?? .infinity
        let progress = min(1, elapsed / 0.5)
        return PressDisplay(kind: stage == .touch && elapsed < 0.65 ? lastPress : stage,
                            isHeld: stage != .touch, pulseProgress: progress,
                            needsAnimation: elapsed < 0.65)
    }
}

public struct PressDisplay: Equatable {
    public var kind: PressKind = .touch
    public var isHeld = false
    public var pulseProgress: Double = 1
    public var needsAnimation = false
    public init(kind: PressKind = .touch, isHeld: Bool = false, pulseProgress: Double = 1, needsAnimation: Bool = false) {
        self.kind = kind; self.isHeld = isHeld; self.pulseProgress = pulseProgress; self.needsAnimation = needsAnimation
    }
}
