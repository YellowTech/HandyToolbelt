import Foundation

public enum KeyboardModifier: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case control, command, option, shift
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var flag: UInt64 { switch self { case .control: 1 << 18; case .command: 1 << 20; case .option: 1 << 19; case .shift: 1 << 17 } }
    public var symbol: String { switch self { case .control: "⌃"; case .command: "⌘"; case .option: "⌥"; case .shift: "⇧" } }
    public static func modifiers(from flags: UInt64) -> Set<Self> { Set(allCases.filter { flags & $0.flag != 0 }) }
    public static func flags(for modifiers: Set<Self>) -> UInt64 { modifiers.reduce(0) { $0 | $1.flag } }
}
public struct KeyboardModifierRequirement: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case any, exact }
    public var mode: Mode
    public var modifiers: Set<KeyboardModifier>
    public init(mode: Mode = .any, modifiers: Set<KeyboardModifier> = []) { self.mode = mode; self.modifiers = modifiers }
    private enum CodingKeys: String, CodingKey { case mode, modifiers }
    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(mode, forKey: .mode); try v.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
    }
    public static let any = Self()
    public static let none = Self(mode: .exact)
    public func matches(_ modifiers: Set<KeyboardModifier>) -> Bool { mode == .any || self.modifiers == modifiers }
    public func overlaps(_ other: Self) -> Bool { mode == .any || other.mode == .any || modifiers == other.modifiers }
}
