import Foundation

/// Presentation only. Recognition and calibration always consume the original contacts.
/// No prediction: the display never overshoots a measured position or invents a touch.
public struct TouchSmoothing {
    public private(set) var contacts: [Contact] = []
    private var targets: [Contact] = []
    private var receivedAt: Double?
    private var renderedAt: Double?

    public init() {}

    public mutating func receive(_ contacts: [Contact], at time: Double) {
        guard time.isFinite, time >= (receivedAt ?? -.infinity) else { return }
        // Forget lifted fingers even if a new down arrives before the next display tick.
        let ids = Set(contacts.map(\.id))
        self.contacts.removeAll { !ids.contains($0.id) }
        targets = contacts
        receivedAt = time
    }

    @discardableResult public mutating func render(at time: Double) -> [Contact] {
        guard time.isFinite, let receivedAt, time - receivedAt < 0.25 else {
            reset(); return []
        }
        let elapsed = max(0, time - (renderedAt ?? time))
        // 8 ms removes sensor jitter without the drag of a conventional UI animation.
        let positionWeight = 1 - exp(-elapsed / 0.008)
        let pressureWeight = 1 - exp(-elapsed / 0.025)
        let previous = Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        contacts = targets.map { target in
            guard let old = previous[target.id], elapsed < 0.1 else { return target }
            var next = target
            next.position.x = old.position.x + (target.position.x - old.position.x) * positionWeight
            next.position.y = old.position.y + (target.position.y - old.position.y) * positionWeight
            if let pressure = target.pressure, let oldPressure = old.pressure {
                next.pressure = oldPressure + (pressure - oldPressure) * pressureWeight
            }
            return next
        }
        renderedAt = time
        return contacts
    }

    public mutating func reset() {
        contacts = []; targets = []; receivedAt = nil; renderedAt = nil
    }
}
