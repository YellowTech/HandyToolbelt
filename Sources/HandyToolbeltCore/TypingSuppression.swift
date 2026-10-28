import Foundation

/// Hardware typing blocks recognition until the cooldown ends and each held
/// contact sequence has fully lifted. Modifier transitions never extend it.
public struct TypingSuppression {
    public private(set) var deadline: Double = -.infinity
    private var heldDevices = Set<UInt64>()
    private var acceptedFrameTimes: [UInt64: Double] = [:]
    public init() {}
    public mutating func keyDown(at time: Double, synthetic: Bool = false, modifier: Bool = false) {
        guard time.isFinite, !synthetic, !modifier else { return }
        deadline = max(deadline, time + 0.5)
    }
    public func coolingDown(at time: Double) -> Bool { time < deadline }
    public mutating func requireLift(deviceID: UInt64) { heldDevices.insert(deviceID) }
    public mutating func suppresses(deviceID: UInt64, hasContacts: Bool, at time: Double) -> Bool {
        // Invalid or queued older lifts cannot clear a held-contact barrier.
        guard time.isFinite, time >= (acceptedFrameTimes[deviceID] ?? -.infinity) else { return true }
        acceptedFrameTimes[deviceID] = time
        if coolingDown(at: time) {
            if hasContacts { heldDevices.insert(deviceID) } else { heldDevices.remove(deviceID) }
            return true
        }
        if heldDevices.contains(deviceID) {
            if !hasContacts { heldDevices.remove(deviceID) }
            return true
        }
        return false
    }
}
