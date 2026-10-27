import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func legacyBrowserActionsNormalizeInEverySavedLocation() throws {
    let previous = GestureAction(system: .previousTab, script: "retained", text: "retained", textDuration: 2, automationID: UUID(), applicationBundleIdentifier: "com.apple.Safari")
    let next = GestureAction(system: .nextTab)
    var expected = AppConfiguration()
    expected.bindings = [.init(gesture: .init(kind: .tipTapLeft), action: previous.canonicalized, isEnabled: false, applicationGroupID: ApplicationGroup.browsersID, keyboardModifiers: .none)]
    expected.bindings[0].showsToast = false
    expected.stacks = [.init(name: "Browser", applicationGroupID: ApplicationGroup.browsersID, isEnabled: true,
        startActions: [.init(action: previous.canonicalized)],
        bindings: [.init(actions: [previous.canonicalized, next.canonicalized], isEnabled: false)],
        releaseActions: [next.canonicalized])]
    expected.automations = [.init(name: "Browser", steps: [.init(name: "Previous", action: previous.canonicalized), .init(name: "Next", action: next.canonicalized)])]
    // Recreate the on-disk legacy shape, including inactive aliases on other kinds.
    func legacy(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(legacy) }
        guard var object = value as? [String: Any] else { return value }
        object = object.mapValues(legacy)
        if object["kind"] as? String == "shortcut", let shortcut = object["shortcut"] as? [String: Any], shortcut["keyCode"] as? Int == 48 {
            object["kind"] = "system"
            object["system"] = (shortcut["modifiers"] as? Int == (1 << 18)) ? "nextTab" : "previousTab"
            object.removeValue(forKey: "shortcut")
        }
        return object
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let legacyData = try JSONSerialization.data(withJSONObject: legacy(JSONSerialization.jsonObject(with: encoder.encode(expected))))
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: legacyData)
    // Exact encoded equality covers IDs, enable flags, scopes, modifier requirements and unrelated action fields.
    #expect(try encoder.encode(restored) == encoder.encode(expected))
    #expect(restored.bindings[0].action.kind == .shortcut)
    #expect(restored.stacks[0].startActions[0].action.shortcut?.display == "⌃⇧⇥")
    #expect(restored.stacks[0].releaseActions[0].shortcut?.display == "⌃⇥")
    let output = try encoder.encode(restored)
    #expect(!String(decoding: output, as: UTF8.self).contains("previousTab"))
    #expect(!String(decoding: output, as: UTF8.self).contains("nextTab"))
    #expect(try encoder.encode(JSONDecoder().decode(AppConfiguration.self, from: output)) == output)
}

@Test func canonicalActionsPreserveOtherKindsAndOfferValidSystemDefaults() throws {
    #expect(GestureAction().isValid)
    #expect(SystemAction.selectableCases.contains(GestureAction().system))
    #expect(!SystemAction.selectableCases.contains(.previousTab))
    #expect(!SystemAction.selectableCases.contains(.nextTab))
    let unrelated = GestureAction(kind: .showText, shortcut: .init(keyCode: 0, modifiers: 0, keyLabel: "A"), system: .previousTab, text: "Hello")
    let restored = try JSONDecoder().decode(GestureAction.self, from: JSONEncoder().encode(unrelated))
    #expect(restored.kind == .showText)
    #expect(restored.shortcut == unrelated.shortcut)
    #expect(restored.text == "Hello")
    #expect(restored.system == .middleClick)
    for system in SystemAction.selectableCases {
        let action = GestureAction(system: system)
        #expect(try JSONDecoder().decode(GestureAction.self, from: JSONEncoder().encode(action)) == action)
    }
}
