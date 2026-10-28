import Foundation
import HandyToolbeltCore

/// No UI publication, files, or configuration access on the sampling path.
final class DebugEventRecorder {
    static let shared = DebugEventRecorder()
    private let lock = NSLock()
    private var enabled = false
    private var buffer = DebugEventBuffer()
    private var aliases: [UInt64: Int] = [:]
    var contextProvider: (() -> [String: String])?
    var onEnabledChanged: (() -> Void)?
    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value { buffer = DebugEventBuffer(); aliases.removeAll() }
        lock.unlock()
        if value {
            record(category: .suppression, event: "recorder_enabled", fields: ["app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development", "os_version": ProcessInfo.processInfo.operatingSystemVersionString])
        }
        onEnabledChanged?()
    }
    func record(category: DebugEventCategory, event: String, fields: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        buffer.append(category: category, event: event, fields: fields, at: ProcessInfo.processInfo.systemUptime)
    }
    func touch(deviceID: UInt64, contacts: [Contact], kind: InputDevice? = nil, aspectRatio: Double? = nil, frameTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if aliases[deviceID] == nil, aliases.count < 64 { aliases[deviceID] = aliases.count + 1 }
        var fields = ["device": "device-\(aliases[deviceID] ?? 0)", "count": String(min(10, contacts.count))]
        if let kind { fields["kind"] = kind.rawValue }
        if let aspectRatio { fields["aspect_ratio"] = String(aspectRatio) }
        if let frameTime, frameTime.isFinite { fields["delivery_delay_seconds"] = String(ProcessInfo.processInfo.systemUptime - frameTime) }
        for (index, contact) in contacts.prefix(10).enumerated() {
            let pressure = contact.pressure.map { $0.isFinite ? String($0) : "unknown" } ?? "unknown"
            fields["contact-\(index)"] = "\(contact.id):\(contact.position.x),\(contact.position.y),\(pressure)"
        }
        buffer.append(category: .touch, event: "frame", fields: fields, at: ProcessInfo.processInfo.systemUptime)
    }
    func feedback(_ value: DetectionFeedback) {
        guard isEnabled else { return }
        let reason: String
        switch value.message {
        case "Corner finger lifted or moved. Lift all fingers and try again.": reason = "corner_contact_changed"
        case "Fingers are too close along the hand axis.": reason = "fingers_too_close"
        case "Move resting fingers away from the trackpad edge.": reason = "edge_deadzone"
        case "Bring the fingers closer together for an anchored gesture.": reason = "fingers_too_far"
        case "Resting fingers must settle and stay still long enough.": reason = "anchor_not_settled"
        case "Active finger moved too far for a tap or was held too long.": reason = "tap_travel_or_duration"
        default: reason = value.phase == .rejected ? "contact_or_timing_rule" : value.phase.rawValue
        }
        record(category: .recognition, event: "feedback", fields: ["phase": value.phase.rawValue, "reason": reason,
            "fingers": String(value.fingerCount), "kind": value.gesture?.kind.rawValue ?? "none",
            "corner": value.gesture?.corner.rawValue ?? "none", "hold_seconds": String(value.holdTime),
            "tap_seconds": String(value.tapTime), "travel": String(value.travel), "separation": String(value.separation)])
    }
    private struct Export: Encodable {
        let schemaVersion = 1
        let appVersion: String
        let macOSVersion: String
        let durationSeconds = 15
        let context: [String: String]
        let events: [Event]
        struct Event: Encodable {
            let time: Double
            let category: DebugEventCategory
            let event: String
            let fields: [String: String]
        }
    }
    func snapshot() throws -> Data {
        let context = contextProvider?() ?? [:]
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let events = buffer.snapshot(at: now)
        lock.unlock()
        // Relative monotonic seconds from this frozen interval's start; no wall clock.
        let export = Export(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString, context: context,
            events: events.map { Export.Event(time: max(0, $0.time - (now - 15)), category: $0.category, event: $0.event, fields: $0.fields) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}
