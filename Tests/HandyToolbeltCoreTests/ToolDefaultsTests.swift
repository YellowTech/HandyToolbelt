import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func freshToolsAreOffAndSavedChoicesSurviveReload() throws {
    let fresh = AppConfiguration()
    let minimal = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"version":6,"bindings":[]}"#.utf8))
    for value in [fresh, minimal] {
        #expect(!value.trackpadModuleEnabled && !value.windowSwitcher.isEnabled && !value.snappingModuleEnabled)
        #expect(!value.displayModuleEnabled && !value.powerModuleEnabled && !value.coffeeModuleEnabled)
    }
    var enabled = fresh
    enabled.trackpadModuleEnabled = true
    enabled.windowSwitcher.isEnabled = true
    enabled.snappingModuleEnabled = true
    enabled.displayModuleEnabled = true
    enabled.powerModuleEnabled = true
    enabled.coffeeModuleEnabled = true
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(enabled))
    #expect(restored.trackpadModuleEnabled && restored.windowSwitcher.isEnabled && restored.snappingModuleEnabled)
    #expect(restored.displayModuleEnabled && restored.powerModuleEnabled && restored.coffeeModuleEnabled)
}
