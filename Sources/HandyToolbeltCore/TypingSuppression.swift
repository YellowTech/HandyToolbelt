import Foundation

/// Hardware typing blocks recognition during a short cooldown.
/// Modifier transitions never extend it.
public struct TypingSuppression {
    public private(set) var deadline: Double = -.infinity
    public init() {}
    public mutating func keyDown(at time: Double, synthetic: Bool = false, modifier: Bool = false) {
        guard time.isFinite, !synthetic, !modifier else { return }
        deadline = max(deadline, time + 0.5)
    }
    public func coolingDown(at time: Double) -> Bool { time < deadline }
}
