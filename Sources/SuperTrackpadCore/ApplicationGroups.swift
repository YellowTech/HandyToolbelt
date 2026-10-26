import Foundation

public struct GroupApplication: Codable, Equatable, Identifiable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var id: String { bundleIdentifier }
    public init(_ name: String, _ bundleIdentifier: String) {
        self.name = name; self.bundleIdentifier = bundleIdentifier
    }
}

public struct ApplicationGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var applications: [GroupApplication]
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled group" : trimmed
    }
    public init(id: UUID = UUID(), name: String, applications: [GroupApplication] = []) {
        self.id = id; self.name = name; self.applications = applications
    }
    public func contains(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return applications.contains { $0.bundleIdentifier == bundleIdentifier }
    }
    public static let browsersID = UUID(uuidString: "2729C500-A134-4A75-8582-96E696AC1A01")!
    public static let examples: [ApplicationGroup] = [
        .init(id: browsersID, name: "Browsers", applications: [
            .init("Safari", "com.apple.Safari"), .init("Google Chrome", "com.google.Chrome"),
            .init("Firefox", "org.mozilla.firefox"), .init("Microsoft Edge", "com.microsoft.edgemac"),
            .init("Brave Browser", "com.brave.Browser"), .init("Arc", "company.thebrowser.Browser")
        ]),
        .init(id: UUID(uuidString: "2729C500-A134-4A75-8582-96E696AC1A02")!, name: "Editors", applications: [
            .init("Xcode", "com.apple.dt.Xcode"), .init("Visual Studio Code", "com.microsoft.VSCode"),
            .init("CotEditor", "com.coteditor.CotEditor")
        ]),
        .init(id: UUID(uuidString: "2729C500-A134-4A75-8582-96E696AC1A03")!, name: "Terminals", applications: [
            .init("Terminal", "com.apple.Terminal"), .init("iTerm", "com.googlecode.iterm2")
        ])
    ]
}

/// Invalidates pending actions and in-progress contacts when the focused process changes.
/// A held finger must lift before it can participate in a gesture in the next app.
public struct GestureFocusContext: Sendable {
    public private(set) var bundleIdentifier: String?
    public private(set) var processIdentifier: Int32?
    public private(set) var generation: UInt64 = 0
    private var touchedDevices = Set<UInt64>()
    private var awaitingRelease = Set<UInt64>()
    public init() {}

    @discardableResult public mutating func update(bundleIdentifier: String?, processIdentifier: Int32?) -> Bool {
        guard self.bundleIdentifier != bundleIdentifier || self.processIdentifier != processIdentifier else { return false }
        self.bundleIdentifier = bundleIdentifier; self.processIdentifier = processIdentifier
        generation &+= 1
        awaitingRelease.formUnion(touchedDevices)
        return true
    }

    public mutating func acceptsFrame(deviceID: UInt64, hasContacts: Bool) -> Bool {
        if hasContacts { touchedDevices.insert(deviceID) } else { touchedDevices.remove(deviceID) }
        if awaitingRelease.contains(deviceID) {
            if !hasContacts { awaitingRelease.remove(deviceID) }
            return false
        }
        return true
    }

    public mutating func forgetDevices(except ids: Set<UInt64>) {
        touchedDevices.formIntersection(ids); awaitingRelease.formIntersection(ids)
    }
}
