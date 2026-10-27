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
public enum GestureStackActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case action, holdModifiers
    public var id: String { rawValue }
}
public struct GestureStackAction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: GestureStackActionKind
    public var action: GestureAction
    public var modifiers: Set<KeyboardModifier>
    public init(id: UUID = UUID(), kind: GestureStackActionKind = .action, action: GestureAction = .init(kind: .showText, text: "Stack"), modifiers: Set<KeyboardModifier> = [.option]) {
        self.id = id; self.kind = kind; self.action = action; self.modifiers = modifiers
    }
    private enum CodingKeys: String, CodingKey { case id, kind, action, modifiers }
    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id); try v.encode(kind, forKey: .kind); try v.encode(action, forKey: .action)
        try v.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
    }
}
public struct GestureStackBinding: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var displayName: String { let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? gesture.title : trimmed }
    public var id: UUID
    public var gesture: GestureSpec
    public var keyboardModifiers: KeyboardModifierRequirement
    public var actions: [GestureAction]
    public var isEnabled: Bool
    public init(id: UUID = UUID(), name: String = "", gesture: GestureSpec = .init(kind: .tap, fingers: 1), keyboardModifiers: KeyboardModifierRequirement = .any, actions: [GestureAction] = [], isEnabled: Bool = true) {
        self.id = id; self.name = name; self.gesture = gesture; self.keyboardModifiers = keyboardModifiers; self.actions = actions; self.isEnabled = isEnabled
    }
    private enum CodingKeys: String, CodingKey { case id, name, gesture, keyboardModifiers, actions, isEnabled }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        name = try v.decodeIfPresent(String.self, forKey: .name) ?? ""
        id = try v.decode(UUID.self, forKey: .id); gesture = try v.decode(GestureSpec.self, forKey: .gesture)
        keyboardModifiers = try v.decodeIfPresent(KeyboardModifierRequirement.self, forKey: .keyboardModifiers) ?? .any
        actions = try v.decode([GestureAction].self, forKey: .actions); isEnabled = try v.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
public struct GestureStack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var device: InputDevice
    public var corner: Corner
    public var applicationGroupID: UUID?
    public var keyboardModifiers: KeyboardModifierRequirement
    public var isEnabled: Bool
    public var startActions: [GestureStackAction]
    public var bindings: [GestureStackBinding]
    public var releaseActions: [GestureAction]
    public init(id: UUID = UUID(), name: String = "New stack", device: InputDevice = .trackpad, corner: Corner = .topLeft, applicationGroupID: UUID? = nil, keyboardModifiers: KeyboardModifierRequirement = .any, isEnabled: Bool = false, startActions: [GestureStackAction] = [], bindings: [GestureStackBinding] = [], releaseActions: [GestureAction] = []) {
        self.id = id; self.name = name; self.device = device; self.corner = corner; self.applicationGroupID = applicationGroupID; self.keyboardModifiers = keyboardModifiers; self.isEnabled = isEnabled; self.startActions = startActions; self.bindings = bindings; self.releaseActions = releaseActions
    }
    private enum CodingKeys: String, CodingKey { case id, name, device, corner, applicationGroupID, keyboardModifiers, isEnabled, startActions, bindings, releaseActions }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(UUID.self, forKey: .id); name = try v.decode(String.self, forKey: .name); device = try v.decode(InputDevice.self, forKey: .device); corner = try v.decode(Corner.self, forKey: .corner)
        applicationGroupID = try v.decodeIfPresent(UUID.self, forKey: .applicationGroupID)
        keyboardModifiers = try v.decodeIfPresent(KeyboardModifierRequirement.self, forKey: .keyboardModifiers) ?? .any
        isEnabled = try v.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        startActions = try v.decode([GestureStackAction].self, forKey: .startActions); bindings = try v.decode([GestureStackBinding].self, forKey: .bindings); releaseActions = try v.decode([GestureAction].self, forKey: .releaseActions)
    }
}
public extension AppConfiguration {
    func scopeTitle(for stack: GestureStack) -> String { guard let id = stack.applicationGroupID else { return "Everywhere" }; return applicationGroups.first { $0.id == id }?.displayName ?? "Missing app group" }
    func applies(_ stack: GestureStack, to bundleIdentifier: String?) -> Bool { guard let id = stack.applicationGroupID else { return true }; return applicationGroups.first { $0.id == id }?.contains(bundleIdentifier) ?? false }
    func scopesOverlap(_ first: UUID?, _ second: UUID?) -> Bool {
        guard let first, let second else { return true }
        guard let a = applicationGroups.first(where: { $0.id == first }), let b = applicationGroups.first(where: { $0.id == second }) else { return false }
        return a.applications.contains { b.contains($0.bundleIdentifier) }
    }
    func conflictMessages(for binding: GestureBinding) -> [String] {
        guard binding.isEnabled else { return [] }
        var messages: [String] = []
        if bindings.contains(where: { other in
            other.id != binding.id && other.isEnabled && other.device == binding.device && other.gesture == binding.gesture && other.keyboardModifiers.overlaps(binding.keyboardModifiers) && ((other.applicationGroupID == nil && binding.applicationGroupID == nil) || (other.applicationGroupID != nil && binding.applicationGroupID != nil && scopesOverlap(other.applicationGroupID, binding.applicationGroupID)))
        }) { messages.append("Overlaps an enabled binding for the same gesture and scope.") }
        if binding.gesture.corner != .none && stacks.contains(where: { $0.isEnabled && $0.device == binding.device && $0.corner == binding.gesture.corner && $0.keyboardModifiers.overlaps(binding.keyboardModifiers) && scopesOverlap($0.applicationGroupID, binding.applicationGroupID) }) { messages.append("Corner is reserved by an enabled gesture stack in an overlapping scope.") }
        return messages
    }
    func conflictMessages(for stack: GestureStack) -> [String] {
        guard stack.isEnabled else { return [] }
        var messages: [String] = []
        if stacks.contains(where: { $0.id != stack.id && $0.isEnabled && $0.device == stack.device && $0.corner == stack.corner && $0.keyboardModifiers.overlaps(stack.keyboardModifiers) && scopesOverlap($0.applicationGroupID, stack.applicationGroupID) }) { messages.append("Overlaps an enabled gesture stack using the same corner.") }
        if bindings.contains(where: { $0.isEnabled && $0.device == stack.device && $0.gesture.corner == stack.corner && $0.keyboardModifiers.overlaps(stack.keyboardModifiers) && scopesOverlap($0.applicationGroupID, stack.applicationGroupID) }) { messages.append("Corner is used by an enabled ordinary binding in an overlapping scope.") }
        return messages
    }
    /// Focused semantic validation for dispatch and editor activation, excluding unrelated drafts.
    func stackValidationMessages(for stack: GestureStack) -> [String] {
        var isolated = self
        isolated.bindings = []
        isolated.stacks = [stack]
        isolated.stacks[0].isEnabled = true
        // Automation definitions remain present so stack references are validated.
        return isolated.validation().errors.filter { $0.hasPrefix("Stack ") || $0.hasPrefix("Duplicate stack") }
    }
    func matchStack(device: InputDevice, corner: Corner, frontmostBundleIdentifier: String? = nil, keyboardModifiers: Set<KeyboardModifier> = []) -> GestureStack? {
        let candidates = stacks.filter { $0.isEnabled && $0.device == device && $0.corner == corner && corner != .none && $0.keyboardModifiers.matches(keyboardModifiers) && applies($0, to: frontmostBundleIdentifier) }
        guard candidates.count == 1 else { return nil }
        if bindings.contains(where: { $0.isEnabled && $0.device == device && $0.gesture.corner == corner && $0.keyboardModifiers.matches(keyboardModifiers) && applies($0, to: frontmostBundleIdentifier) }) { return nil }
        let selected = candidates[0]
        return stackValidationMessages(for: selected).isEmpty ? selected : nil
    }
}
