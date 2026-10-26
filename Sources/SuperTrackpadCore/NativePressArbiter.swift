import Foundation

/// Native mouse and NSEvent pressure monitors can deliver release and stage 2
/// in different orders. Timestamps assign pressure to its original physical press;
/// a short release grace permits late delivery without mixing rapid presses.
/// Payloads contain immutable matching context, never a fresh lookup at release.
public struct NativePressArbiter<Payload> {
    public static var releaseGrace: Double { 0.04 }
    private struct Press {
        var payload: Payload
        var down: Double
        var up: Double?
        var forced = false
    }
    private var presses: [Press] = []
    public init() {}
    public var hasPending: Bool { !presses.isEmpty }
    public mutating func begin(_ payload: Payload, at time: Double) {
        guard time.isFinite else { cancel(); return }
        // An overlapping down is invalid; do not execute its abandoned click.
        presses.removeAll { $0.up == nil }
        presses.append(Press(payload: payload, down: time))
    }
    public mutating func release(at time: Double) {
        guard time.isFinite, let index = presses.lastIndex(where: { $0.up == nil }), time >= presses[index].down else { return }
        presses[index].up = time
    }
    public mutating func stage(_ stage: Int, at time: Double) -> Payload? {
        guard stage == 2, time.isFinite,
              let index = presses.lastIndex(where: { time >= $0.down && ($0.up == nil || time <= $0.up!) }),
              !presses[index].forced else { return nil }
        presses[index].forced = true
        return presses[index].payload
    }
    public mutating func finish(at time: Double) -> [Payload] {
        let completed = presses.filter { $0.up.map { time >= $0 + Self.releaseGrace } ?? false }
        presses.removeAll { $0.up.map { time >= $0 + Self.releaseGrace } ?? false }
        return completed.filter { !$0.forced }.map(\.payload)
    }
    public mutating func invalidate(where invalid: (Payload) -> Bool) { presses.removeAll { invalid($0.payload) } }
    public mutating func validate(_ valid: (inout Payload) -> Bool) {
        presses = presses.compactMap { press in
            var value = press
            if value.up != nil { return value } // Membership freezes at native release.
            return valid(&value.payload) ? value : nil
        }
    }
    public mutating func cancel() { presses.removeAll() }
}

/// Contact lifts may precede native mouse-up. Subsets preserve the captured
/// press; additions, replacement IDs, corner movement, or stale data cancel it.
public struct NativePressContacts {
    public let deviceID: UInt64
    public let ids: Set<Int>
    private var remainingIDs: Set<Int>
    public private(set) var lastFrame: Double
    public let corner: Corner
    public let cornerFinger: Int?
    public let cornerSize: Double
    private let cornerOrigin: TouchPoint?
    private let movementTolerance: Double
    public init(deviceID: UInt64, contacts: [Contact], corner: Corner, cornerFinger: Int?, cornerSize: Double, time: Double, movementTolerance: Double = 0.035) {
        self.deviceID = deviceID; ids = Set(contacts.map(\.id)); self.corner = corner
        self.cornerFinger = cornerFinger; self.cornerSize = cornerSize
        remainingIDs = ids; lastFrame = time
        cornerOrigin = contacts.first(where: { $0.id == cornerFinger })?.position
        self.movementTolerance = movementTolerance
    }
    public mutating func accepts(deviceID: UInt64, contacts: [Contact], at time: Double) -> Bool {
        if self.deviceID != deviceID { return contacts.isEmpty }
        guard time.isFinite, time >= lastFrame, time - lastFrame < 0.15, contacts.count == Set(contacts.map(\.id)).count, Set(contacts.map(\.id)).isSubset(of: remainingIDs),
              contacts.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && (0...1).contains($0.position.x) && (0...1).contains($0.position.y) }) else { return false }
        if let cornerFinger, !contacts.isEmpty, !contacts.contains(where: { $0.id == cornerFinger }) { return false }
        remainingIDs = Set(contacts.map(\.id)); lastFrame = time
        if let cornerFinger, let point = contacts.first(where: { $0.id == cornerFinger }) {
            return corner.contains(point.position, size: cornerSize) && cornerOrigin.map { hypot(point.position.x - $0.x, point.position.y - $0.y) <= movementTolerance } == true
        }
        return true
    }
}
