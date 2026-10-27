import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func stackRoundTripAndLegacyDefaults() throws {
    var config = AppConfiguration(); config.bindings = []
    config.stacks = [.init(name: "Tabs", isEnabled: true, startActions: [.init(kind: .holdModifiers)], bindings: [.init(gesture: .init(kind: .tipTapLeft), actions: [.init(system: .previousTab)])], releaseActions: [.init(kind: .openApplication, applicationBundleIdentifier: "com.apple.finder")])]
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.stacks == config.stacks)
    #expect(restored.validation().isValid)
    let legacy = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"version":4,"bindings":[]}"#.utf8))
    #expect(legacy.version == 6); #expect(legacy.stacks.isEmpty)
}
@Test func stacksReserveCornerInBothDirections() {
    var config = AppConfiguration()
    let binding = GestureBinding(gesture: .init(kind: .tap, fingers: 1, corner: .topLeft), action: .init())
    let stack = GestureStack(isEnabled: true)
    config.bindings = [binding]; config.stacks = [stack]
    #expect(!config.conflictMessages(for: binding).isEmpty)
    #expect(!config.conflictMessages(for: stack).isEmpty)
    config.stacks[0].keyboardModifiers = .init(mode: .exact, modifiers: [.option])
    config.bindings[0].keyboardModifiers = .none
    #expect(config.conflictMessages(for: config.stacks[0]).isEmpty)
    #expect(config.conflictMessages(for: config.bindings[0]).isEmpty)
}
@Test func physicalModifiersSelectNormalBinding() {
    var config = AppConfiguration()
    let spec = GestureSpec(kind: .tap, fingers: 2)
    config.bindings = [.init(gesture: spec, action: .init(system: .nextTab), keyboardModifiers: .none), .init(gesture: spec, action: .init(system: .previousTab), keyboardModifiers: .init(mode: .exact, modifiers: [.command]))]
    #expect(config.validation().isValid)
    #expect(config.match(device: .trackpad, gesture: spec)?.action.system == .nextTab)
    #expect(config.match(device: .trackpad, gesture: spec, keyboardModifiers: [.command])?.action.system == .previousTab)
    #expect(config.match(device: .trackpad, gesture: spec, keyboardModifiers: [.option]) == nil)
}
@Test func malformedStacksAndDrafts() {
    var config = AppConfiguration(); config.bindings = []
    config.stacks = [.init(corner: .none, isEnabled: true, startActions: [.init(kind: .holdModifiers, modifiers: [])], bindings: [.init(gesture: .init(kind: .tap, fingers: 5, corner: .topRight), actions: [.init(kind: .automation)])])]
    #expect(!config.validation().isValid)
    config.stacks[0].isEnabled = false
    #expect(config.validation().isValid); #expect(!config.validation().warnings.isEmpty)
}
@Test func stackScopesAndOverlap() {
    var config = AppConfiguration(); config.bindings = []
    let first = ApplicationGroup.examples[0]
    var second = first; second.id = UUID(); second.applications = []
    config.applicationGroups = [first, second]
    config.stacks = [.init(applicationGroupID: first.id, isEnabled: true), .init(applicationGroupID: second.id, isEnabled: true)]
    #expect(config.validation().isValid)
    config.stacks[1].applicationGroupID = first.id
    #expect(!config.validation().isValid)
}

@Test func ambiguousCornerDispatchFailsClosed() {
    var config = AppConfiguration()
    let gesture = GestureSpec(kind: .tap, fingers: 1, corner: .topLeft)
    config.bindings = [.init(gesture: gesture, action: .init())]
    config.stacks = [.init(isEnabled: true)]
    #expect(config.match(device: .trackpad, gesture: gesture) == nil)
    #expect(config.matchStack(device: .trackpad, corner: .topLeft) == nil)
    config.bindings[0].applicationGroupID = ApplicationGroup.browsersID
    #expect(config.matchStack(device: .trackpad, corner: .topLeft, frontmostBundleIdentifier: "com.apple.Terminal") != nil)
    config.stacks[0].corner = .none
    #expect(config.matchStack(device: .trackpad, corner: .none) == nil)
}
