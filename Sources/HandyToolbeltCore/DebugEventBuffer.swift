import Foundation

public enum DebugEventCategory: String, Codable { case touch, keyboard, recognition, suppression, click, stack, snapping }
public struct DebugEvent: Codable {
    public let time: Double
    public let category: DebugEventCategory
    public let event: String
    public let fields: [String: String]
}
/// Bounded diagnostics containing only explicitly supplied, privacy-safe fields.
public struct DebugEventBuffer {
    private var storage: [DebugEvent?]
    private var head = 0
    private var count = 0
    public var events: [DebugEvent] { (0..<count).compactMap { storage[(head + $0) % capacity] } }
    public let capacity: Int
    public init(capacity: Int = 12000) { self.capacity = max(1, capacity); storage = Array(repeating: nil, count: max(1, capacity)) }
    public mutating func append(category: DebugEventCategory, event: String, fields: [String: String], at time: Double) {
        guard time.isFinite, count == 0 || time >= (storage[(head + count - 1) % capacity]?.time ?? -.infinity) else { return }
        prune(at: time)
        let safeFields = Dictionary(fields.sorted { $0.key < $1.key }.prefix(24).map { (String($0.key.prefix(48)), String($0.value.prefix(256))) }, uniquingKeysWith: { first, _ in first })
        if count == capacity { removeFirst() }
        storage[(head + count) % capacity] = DebugEvent(time: time, category: category, event: String(event.prefix(64)), fields: safeFields)
        count += 1
    }
    public mutating func snapshot(at time: Double) -> [DebugEvent] { prune(at: time); return events }
    private mutating func removeFirst() { storage[head] = nil; head = (head + 1) % capacity; count -= 1 }
    private mutating func prune(at time: Double) {
        while count > 0, let first = storage[head], first.time < time - 15 { removeFirst() }
    }
}
