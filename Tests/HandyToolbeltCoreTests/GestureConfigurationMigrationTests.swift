import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func removedCornerBindingsMigrateAsDisabledDrafts() throws {
    var original = AppConfiguration()
    original.trackpadTuning.tipEdgeDeadzone = 0.12
    original.trackpadModuleEnabled = true
    original.bindings = [
        .init(name: "Legacy corner", gesture: .init(kind: .tap, fingers: 1),
              action: .init(kind: .showText, text: "Preserve me"),
              applicationGroupID: ApplicationGroup.browsersID,
              keyboardModifiers: .init(mode: .exact, modifiers: [.shift])),
        .init(gesture: .init(kind: .tap, fingers: 3), action: .init(system: .middleClick))
    ]
    original.bindings[0].showsToast = false
    original.bindings[0].hapticPattern = .light

    let encoder = JSONEncoder()
    var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
    legacy["version"] = 6
    legacy["stacks"] = [["corner": "topLeft", "isEnabled": true]]
    var tuning = try #require(legacy["trackpadTuning"] as? [String: Any])
    tuning["cornerHold"] = 0.4
    tuning["cornerSize"] = 0.3
    legacy["trackpadTuning"] = tuning
    var bindings = try #require(legacy["bindings"] as? [[String: Any]])
    bindings[0]["gesture"] = ["kind": "tap", "fingers": 1, "corner": "bottomRight"]
    bindings[1]["gesture"] = ["kind": "tap", "fingers": 3, "corner": "none"]
    legacy["bindings"] = bindings

    let decoder = JSONDecoder()
    let migrated = try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated.version == 7)
    #expect(migrated.trackpadModuleEnabled)
    #expect(migrated.trackpadTuning == original.trackpadTuning)
    var expected = original.bindings
    expected[0].gesture.fingers = 2
    expected[0].isEnabled = false
    #expect(migrated.bindings == expected)
    #expect(migrated.validation().isValid)
    #expect(migrated.match(device: .trackpad, gesture: expected[0].gesture,
                           frontmostBundleIdentifier: "com.apple.Safari", keyboardModifiers: [.shift]) == nil)
    #expect(migrated.match(device: .trackpad, gesture: expected[1].gesture) == expected[1])

    let saved = try encoder.encode(migrated)
    let json = String(decoding: saved, as: UTF8.self)
    for key in ["stacks", "corner", "cornerHold", "cornerSize"] {
        #expect(!json.contains("\"\(key)\""))
    }
    #expect(try decoder.decode(AppConfiguration.self, from: saved).bindings == expected)
}
