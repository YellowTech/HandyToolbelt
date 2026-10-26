import Foundation
import Testing
@testable import SuperTrackpadCore

private func sampleWindows() -> [WindowItem] {
    [.init(processID: 1, appName: "Browser", bundleIdentifier: "browser", title: "First"),
     .init(processID: 1, appName: "Browser", bundleIdentifier: "browser", title: "Second"),
     .init(processID: 2, appName: "Editor", bundleIdentifier: "editor", title: "Project")]
}

@Test func separateWindowsOfSameAppStaySeparate() {
    let windows = sampleWindows()
    let settings = WindowSwitcherSettings()
    #expect(WindowOrdering.candidates(windows, settings: settings, currentProcessID: 1).count == 3)
    var selection = WindowSelection()
    selection.begin(ids: windows.map(\.id), focusedID: windows[0].id)
    #expect(selection.selectedID == windows[1].id)
    selection.step(1)
    #expect(selection.selectedID == windows[2].id)
}

@Test func windowScopeAndVisibilityFiltersCompose() {
    var windows = sampleWindows()
    windows[0].isMinimized = true; windows[2].isHidden = true
    var settings = WindowSwitcherSettings()
    #expect(WindowOrdering.candidates(windows, settings: settings, currentProcessID: 1).count == 3)
    settings.includeMinimized = false; settings.includeHidden = false
    #expect(WindowOrdering.candidates(windows, settings: settings, currentProcessID: 1) == [windows[1]])
    settings.includeMinimized = true; settings.currentAppOnly = true
    #expect(WindowOrdering.candidates(windows, settings: settings, currentProcessID: 1) == Array(windows.prefix(2)))
    #expect(WindowOrdering.candidates(windows, settings: settings, currentProcessID: nil).isEmpty)
}

@Test func mruOrderingPreservesUnseenOrderAndPrioritizesActualFocus() {
    let windows = sampleWindows()
    let ordered = WindowOrdering.recentFirst(windows, history: [windows[1].id, windows[2].id, windows[1].id, UUID()], focusedID: windows[0].id)
    #expect(ordered.map(\.id) == [windows[0].id, windows[1].id, windows[2].id])
    #expect(WindowOrdering.recentFirst(windows, history: [], focusedID: nil) == windows)
}

@Test func windowSelectionWrapsInBothDirectionsAndAcceptsLargeSteps() {
    let ids = sampleWindows().map(\.id)
    var selection = WindowSelection()
    selection.begin(ids: ids, focusedID: ids[0], direction: -1)
    #expect(selection.selectedID == ids[2])
    selection.step(1)
    #expect(selection.selectedID == ids[0])
    selection.step(8)
    #expect(selection.selectedID == ids[2])
    selection.step(-8)
    #expect(selection.selectedID == ids[0])
}

@Test func selectionHandlesNoFocusAndQuickMultiplePresses() {
    let ids = sampleWindows().map(\.id)
    var selection = WindowSelection()
    selection.begin(ids: ids, focusedID: nil)
    #expect(selection.selectedID == ids[0])
    selection.step(1)
    #expect(selection.selectedID == ids[1])
    selection.begin(ids: ids, focusedID: nil, direction: -1)
    #expect(selection.selectedID == ids[2])
    selection.step(1)
    #expect(selection.selectedID == ids[0])
}

@Test func selectionHandlesEmptySingleAndClosedWindows() {
    let ids = sampleWindows().map(\.id)
    var selection = WindowSelection()
    selection.begin(ids: [], focusedID: nil); selection.step(-1)
    #expect(selection.selectedID == nil)
    selection.begin(ids: [ids[0]], focusedID: ids[0]); selection.step(1)
    #expect(selection.selectedID == ids[0])
    selection.begin(ids: ids, focusedID: ids[0])
    selection.retain([ids[0], ids[2]])
    #expect(selection.ids == [ids[0], ids[2]])
    #expect(selection.selectedID == ids[0])
    selection.select(UUID())
    #expect(selection.selectedID == ids[0])
    selection.retain([])
    #expect(selection.selectedID == nil)
}

@Test func repeatedGesturesCycleInsteadOfBouncingAfterMruChanges() {
    let ids = sampleWindows().map(\.id)
    var cycle = WindowGestureCycle()
    #expect(cycle.next(ids: ids, focusedID: ids[0], direction: 1, at: 0) == ids[1])
    #expect(cycle.next(ids: [ids[1], ids[0], ids[2]], focusedID: ids[1], direction: 1, at: 0.4) == ids[2])
    #expect(cycle.next(ids: [ids[2], ids[1], ids[0]], focusedID: ids[2], direction: 1, at: 0.8) == ids[0])
    #expect(cycle.next(ids: ids, focusedID: ids[0], direction: -1, at: 1) == ids[2])
}

@Test func gestureCycleResetsOnTimeoutNewWindowOrExternalFocus() {
    let ids = sampleWindows().map(\.id)
    var cycle = WindowGestureCycle()
    _ = cycle.next(ids: ids, focusedID: ids[0], direction: 1, at: 0)
    #expect(cycle.next(ids: [ids[1], ids[0], ids[2]], focusedID: ids[1], direction: 1, at: 3) == ids[0])
    #expect(cycle.next(ids: [ids[2], ids[1], ids[0]], focusedID: ids[2], direction: 1, at: 3.2) == ids[1])
    #expect(cycle.next(ids: [ids[1], ids[0]], focusedID: ids[1], direction: 1, at: 3.4) == ids[0])
}

@Test func shortcutMatchesModifiersExactlyButAllowsReverseShift() {
    for shortcut in WindowShortcut.allCases {
        #expect(shortcut.matches(keyCode: 48, flags: shortcut.modifiers))
        #expect(shortcut.matches(keyCode: 48, flags: shortcut.modifiers | (1 << 17)))
        #expect(!shortcut.matches(keyCode: 49, flags: shortcut.modifiers))
        #expect(!shortcut.matches(keyCode: 48, flags: 0))
        #expect(shortcut.isHeld(flags: shortcut.modifiers))
        #expect(!shortcut.isHeld(flags: 0))
    }
    #expect(!WindowShortcut.optionTab.matches(keyCode: 48, flags: WindowShortcut.commandTab.modifiers))
    #expect(!WindowShortcut.optionTab.matches(keyCode: 48, flags: WindowShortcut.controlOptionTab.modifiers))
}

@Test func productivityMigrationPreservesExistingSettingsAndStartsWithSeparateModules() throws {
    var old = AppConfiguration()
    old.trackpadTuning.handAngleDegrees = 22
    old.bindings[0].applicationGroupID = nil
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    json["version"] = 2
    json["isEnabled"] = false
    for key in ["trackpadModuleEnabled", "pauseAll", "windowSwitcher"] { json.removeValue(forKey: key) }
    let loaded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(loaded.bindings == old.bindings)
    #expect(loaded.applicationGroups == old.applicationGroups)
    #expect(loaded.trackpadTuning == old.trackpadTuning)
    #expect(!loaded.trackpadModuleEnabled && loaded.windowSwitcher.isEnabled)
    #expect(!loaded.trackpadModuleEnabled)
    #expect(loaded.windowSwitcher.shortcut == .optionTab)
}

@Test func productivitySettingsAndWindowActionsRoundTrip() throws {
    var config = AppConfiguration()
    config.trackpadModuleEnabled = false
    config.windowSwitcher.shortcut = .commandTab; config.windowSwitcher.includeMinimized = false
    config.windowSwitcher.currentAppOnly = true
    config.bindings.append(.init(gesture: .init(kind: .tipTapRight, corner: .bottomLeft), action: .init(system: .nextWindow)))
    let loaded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(!loaded.trackpadModuleEnabled)
    #expect(loaded.windowSwitcher == config.windowSwitcher)
    #expect(loaded.bindings == config.bindings)
    #expect(loaded.bindings.last?.action.system.isWindowAction == true)
}

@Test func windowChooserLegacySettingsKeepListWithoutPreviews() throws {
    let data = Data(#"{"isEnabled":true,"shortcut":"optionTab","currentAppOnly":false,"includeMinimized":true,"includeHidden":true}"#.utf8)
    let decoded = try JSONDecoder().decode(WindowSwitcherSettings.self, from: data)
    #expect(decoded.layout == .list && !decoded.showsPreviews)
    for key in ["isEnabled", "shortcut"] {
        var invalid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        invalid.removeValue(forKey: key)
        let malformed = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WindowSwitcherSettings.self, from: malformed) }
    }
    for layout in WindowLayout.allCases {
        for previews in [false, true] {
            var settings = decoded; settings.layout = layout; settings.showsPreviews = previews
            #expect(try JSONDecoder().decode(WindowSwitcherSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }
}

@Test func gridArrowsUseColumnsAndKeepSelectionStable() {
    let ids = (0..<8).map { _ in UUID() }
    var selection = WindowSelection()
    selection.begin(ids: ids, focusedID: nil)
    selection.step(WindowLayout.grid.verticalStep(1, columns: 3))
    #expect(selection.selectedID == ids[3])
    selection.step(WindowLayout.grid.verticalStep(-1, columns: 3))
    #expect(selection.selectedID == ids[0])
    selection.step(WindowLayout.grid.verticalStep(-1, columns: 3))
    #expect(selection.selectedID == ids[5])
    selection.step(1) // Tab and horizontal arrows still advance one window.
    #expect(selection.selectedID == ids[6])
    #expect(WindowLayout.list.verticalStep(1, columns: 4) == 1)
    #expect(WindowLayout.grid.verticalStep(1, columns: 0) == 1)
}

@Test func previewMatchingRequiresUniqueExactMetadataOnBothSides() {
    let frame = CGRect(x: 20, y: 30, width: 800, height: 600)
    let item = WindowItem(processID: 42, appName: "Editor", bundleIdentifier: "editor", title: "Document", frame: frame)
    let candidate = WindowPreviewCandidate(id: 7, processID: 42, title: "Document", frame: frame)
    #expect(WindowPreviewPolicy.uniqueMatch(for: item, windows: [item], candidates: [candidate]) == 7)
    var duplicate = item; duplicate.id = UUID()
    #expect(WindowPreviewPolicy.uniqueMatch(for: item, windows: [item, duplicate], candidates: [candidate]) == nil)
    var second = candidate; second.id = 8
    #expect(WindowPreviewPolicy.uniqueMatch(for: item, windows: [item], candidates: [candidate, second]) == nil)
    var changed = candidate; changed.processID = 43
    #expect(WindowPreviewPolicy.uniqueMatch(for: item, windows: [item], candidates: [changed]) == nil)
    changed = candidate; changed.title = "document"
    #expect(WindowPreviewPolicy.uniqueMatch(for: item, windows: [item], candidates: [changed]) == nil)
    changed = candidate; changed.frame.origin.x += 1
    #expect(WindowPreviewPolicy.uniqueMatch(for: item, windows: [item], candidates: [changed]) == nil)
    var unavailable = item; unavailable.frame = nil
    #expect(WindowPreviewPolicy.uniqueMatch(for: unavailable, windows: [unavailable], candidates: [candidate]) == nil)
    unavailable = item; unavailable.isMinimized = true
    #expect(WindowPreviewPolicy.uniqueMatch(for: unavailable, windows: [unavailable], candidates: [candidate]) == nil)
    unavailable = item; unavailable.isHidden = true
    #expect(WindowPreviewPolicy.uniqueMatch(for: unavailable, windows: [unavailable], candidates: [candidate]) == nil)
    unavailable = item; unavailable.captureTitle = ""
    #expect(WindowPreviewPolicy.uniqueMatch(for: unavailable, windows: [unavailable], candidates: [candidate]) == nil)
}

@Test func previewImagesAndChooserStayBounded() {
    #expect(WindowPreviewPolicy.imageSize(for: CGRect(x: 0, y: 0, width: 4000, height: 2000)) == CGSize(width: 480, height: 240))
    #expect(WindowPreviewPolicy.imageSize(for: CGRect(x: 0, y: 0, width: 500, height: 2000)) == CGSize(width: 75, height: 300))
    #expect(WindowPreviewPolicy.imageSize(for: CGRect(x: 0, y: 0, width: 80, height: 40)) == CGSize(width: 80, height: 40))
    #expect(WindowPreviewPolicy.imageSize(for: .zero) == nil)
    for layout in WindowLayout.allCases {
        for previews in [false, true] {
            let available = CGSize(width: 500, height: 300)
            let size = WindowChooserGeometry.size(available: available, layout: layout, previews: previews)
            #expect(size.width <= available.width && size.height <= available.height)
            #expect(WindowChooserGeometry.columns(width: size.width, previews: previews) >= 1)
        }
    }
}

@Test func previewGenerationRejectsClosedAndReplacedSessions() {
    var session = WindowPreviewLifetime()
    let first = session.begin()
    #expect(session.accepts(first))
    session.end()
    #expect(!session.accepts(first))
    let second = session.begin()
    #expect(!session.accepts(first) && session.accepts(second))
    session.end() // Disable, pause, screen lock and cancel share the same invalidation.
    #expect(!session.accepts(second))
}

@Test func ordinaryWindowEligibilityDoesNotRequireMainStatusOrWritableAX() {
    for isMain: Bool? in [nil, false, true] {
        for settable: Bool? in [nil, false, true] {
            #expect(WindowEligibility.isEligible(role: "AXWindow", subrole: "AXStandardWindow", isMain: isMain, mainIsSettable: settable))
        }
    }
    #expect(!WindowEligibility.isEligible(role: nil, subrole: "AXStandardWindow"))
    #expect(!WindowEligibility.isEligible(role: "AXSheet", subrole: "AXStandardWindow"))
}

@Test func auxiliaryWindowRolesAreExcludedEvenWithMainEvidence() {
    for subrole: String? in [nil, "AXUnknown", "AXFloatingWindow", "AXSystemFloatingWindow", "AXSystemDialog", "AXDecorative", "CustomOverlay"] {
        #expect(!WindowEligibility.isEligible(role: "AXWindow", subrole: subrole, isMain: true, mainIsSettable: true))
    }
}

@Test func independentDialogsRequirePositiveMainEvidence() {
    #expect(WindowEligibility.isEligible(role: "AXWindow", subrole: "AXDialog", isMain: true))
    #expect(WindowEligibility.isEligible(role: "AXWindow", subrole: "AXDialog", isMain: false, mainIsSettable: true))
    for isMain: Bool? in [nil, false] {
        for settable: Bool? in [nil, false] {
            #expect(!WindowEligibility.isEligible(role: "AXWindow", subrole: "AXDialog", isMain: isMain, mainIsSettable: settable))
        }
    }
}

@Test func ordinaryEligibilityKeepsMinimizedHiddenAndUnpreviewableWindows() {
    let windows = [
        WindowItem(processID: 1, appName: "App", bundleIdentifier: "app", title: "Minimized", isMinimized: true),
        WindowItem(processID: 1, appName: "App", bundleIdentifier: "app", title: "Hidden", isHidden: true),
        WindowItem(processID: 1, appName: "App", bundleIdentifier: "app", title: "Other Space", frame: nil)
    ]
    #expect(WindowEligibility.isEligible(role: "AXWindow", subrole: "AXStandardWindow", isMain: false, mainIsSettable: false))
    #expect(WindowOrdering.candidates(windows, settings: WindowSwitcherSettings(), currentProcessID: 1) == windows)
}

@Test func versionFourDefaultsAndLegacyEnablementMigration() throws {
    let minimal = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"version":4,"bindings":[]}"#.utf8))
    #expect(!minimal.trackpadModuleEnabled)
    for version in 1...3 {
        for actions in [false, true] {
            for paused in [false, true] {
                let json: [String: Any] = ["version": version, "bindings": [], "isEnabled": actions, "pauseAll": paused]
                let migrated = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
                #expect(migrated.trackpadModuleEnabled == (actions && !paused))
                #expect(migrated.displayModuleEnabled == !paused && migrated.coffeeModuleEnabled == !paused && migrated.windowSwitcher.isEnabled == !paused)
                let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
                #expect(encoded["isEnabled"] == nil && encoded["pauseAll"] == nil)
            }
        }
    }
}

@Test func independentSnappingMigrationAndPreviewSize() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let configuration = AppConfiguration()
    let base = try JSONSerialization.jsonObject(with: encoder.encode(configuration)) as! [String: Any]
    for switcherEnabled in [false, true] {
        var old = base
        old.removeValue(forKey: "snappingModuleEnabled")
        var settings = old["windowSwitcher"] as! [String: Any]
        settings["isEnabled"] = switcherEnabled
        settings["snappingEnabled"] = true
        settings.removeValue(forKey: "previewScale")
        old["windowSwitcher"] = settings
        let migrated = try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(migrated.snappingModuleEnabled == switcherEnabled)
        #expect(!migrated.windowSwitcher.snappingEnabled)
        #expect(migrated.windowSwitcher.previewScale == 1)
        old["snappingModuleEnabled"] = !switcherEnabled
        let explicit = try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(explicit.snappingModuleEnabled == !switcherEnabled)
        let saved = try JSONSerialization.jsonObject(with: encoder.encode(explicit)) as! [String: Any]
        #expect((saved["windowSwitcher"] as! [String: Any])["snappingEnabled"] == nil)
    }
    #expect(WindowSwitcherSettings.validatedPreviewScale(.infinity) == 1)
    #expect(WindowSwitcherSettings.validatedPreviewScale(5) == 1.5)
    #expect(WindowSwitcherSettings.validatedPreviewScale(0) == 0.75)
    #expect(WindowChooserGeometry.columns(width: 900, previews: true, previewScale: 0.75) > WindowChooserGeometry.columns(width: 900, previews: true, previewScale: 1.5))
    #expect(WindowChooserGeometry.columns(width: 900, previews: false, previewScale: 0.75) == WindowChooserGeometry.columns(width: 900, previews: false, previewScale: 1.5))
}
