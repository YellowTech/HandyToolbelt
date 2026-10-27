import Foundation
import Testing
@testable import HandyToolbeltCore

private let gesture = GestureSpec(kind: .tipTapLeft)
private let safari = "com.apple.Safari"
private let terminal = "com.apple.Terminal"

private func mapping(group: UUID? = nil, action: SystemAction = .mute, enabled: Bool = true) -> GestureBinding {
    .init(gesture: gesture, action: .init(system: action), isEnabled: enabled, applicationGroupID: group)
}

@Test func browserExamplesOnlyMatchTheFocusedBrowser() throws {
    let config = AppConfiguration()
    let result = try #require(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari))
    #expect(result.action.system == .previousTab)
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: terminal) == nil)
    #expect(config.match(device: .trackpad, gesture: gesture) == nil)
    #expect(config.match(device: .magicMouse, gesture: gesture, frontmostBundleIdentifier: safari) == nil)
}

@Test func appGroupOverridesGlobalAndFallsBackOutsideGroup() {
    var config = AppConfiguration()
    let global = mapping()
    let browser = mapping(group: ApplicationGroup.browsersID, action: .previousTab)
    config.bindings = [global, browser]
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == browser)
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: terminal) == global)
    #expect(!config.hasConflict(global))
    #expect(!config.hasConflict(browser))
    config.bindings[1].isEnabled = false
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == global)
}

@Test func disjointGroupsCanReuseTheSameGesture() {
    var config = AppConfiguration()
    let browser = mapping(group: ApplicationGroup.browsersID)
    let shell = mapping(group: config.applicationGroups[2].id, action: .nextTab)
    config.bindings = [browser, shell]
    #expect(!config.hasConflict(browser))
    #expect(!config.hasConflict(shell))
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == browser)
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: terminal) == shell)
}

@Test func overlappingGroupsBlockOnlyTheirSharedApplications() {
    var config = AppConfiguration()
    let mixed = ApplicationGroup(name: "Work", applications: [.init("Safari", safari), .init("Terminal", terminal)])
    config.applicationGroups.append(mixed)
    let browser = mapping(group: ApplicationGroup.browsersID)
    let work = mapping(group: mixed.id, action: .nextTab)
    config.bindings = [mapping(), browser, work]
    #expect(config.hasConflict(browser))
    #expect(config.conflictingApplications(for: browser) == ["Safari"])
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == nil)
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: "org.mozilla.firefox") == browser)
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: terminal) == work)
}

@Test func duplicateWithinGroupBlocksAndInvalidScopedActionsDoNotFallThrough() {
    var config = AppConfiguration()
    let browser = mapping(group: ApplicationGroup.browsersID)
    var invalid = mapping(group: ApplicationGroup.browsersID)
    invalid.action = .init(kind: .shortcut)
    config.bindings = [mapping(), browser, invalid]
    #expect(config.hasConflict(browser))
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == nil)
    config.bindings.remove(at: 1)
    #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == nil)
}

@Test func missingAndEmptyGroupsNeverBecomeGlobal() {
    var config = AppConfiguration()
    let empty = ApplicationGroup(name: "Empty")
    config.applicationGroups.append(empty)
    for id in [empty.id, UUID()] {
        let binding = mapping(group: id)
        config.bindings = [binding]
        #expect(!config.applies(binding, to: safari))
        #expect(config.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == nil)
    }
    #expect(config.scopeTitle(for: config.bindings[0]) == "Missing app group")
}

@Test func membershipEditsAndRenamesApplyWithoutChangingBindingIdentity() {
    var config = AppConfiguration()
    let original = config.bindings[0]
    config.applicationGroups[0].name = "Web"
    config.applicationGroups[0].applications.removeAll { $0.id == safari }
    #expect(config.scopeTitle(for: original) == "Web")
    #expect(!config.applies(original, to: safari))
    #expect(config.applies(original, to: "org.mozilla.firefox"))
    config.applicationGroups[0].applications.append(.init("Terminal", terminal))
    #expect(config.applies(original, to: terminal))
    #expect(config.bindings[0] == original)
}

@Test func groupMatchingUsesExactIdentityInsteadOfDisplayNameOrPrefix() {
    let group = ApplicationGroup(name: "Browsers", applications: [.init("Safari", safari)])
    #expect(group.contains(safari))
    #expect(!group.contains("Safari"))
    #expect(!group.contains("com.apple.SafariTechnologyPreview"))
    #expect(!group.contains(nil))
    #expect(!group.contains(""))
}

@Test func groupSettingsRoundTripWithMappingsAndTuning() throws {
    var config = AppConfiguration()
    config.applicationGroups[0].name = "My browsers"
    config.trackpadTuning.handAngleDegrees = 23
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.applicationGroups == config.applicationGroups)
    #expect(restored.bindings == config.bindings)
    #expect(restored.trackpadTuning == config.trackpadTuning)
    #expect(restored.version == 6)
}

@Test func legacyMigrationPreservesExistingGlobalMappings() throws {
    var config = AppConfiguration()
    for i in config.bindings.indices { config.bindings[i].applicationGroupID = nil }
    config.trackpadTuning.handAngleDegrees = 28
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    json["version"] = 1
    json["isEnabled"] = false
    json.removeValue(forKey: "applicationGroups")
    let migrated = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(migrated.version == 6)
    #expect(migrated.bindings == config.bindings)
    #expect(migrated.trackpadTuning == config.trackpadTuning)
    #expect(migrated.applicationGroups == ApplicationGroup.examples)
    #expect(!migrated.trackpadModuleEnabled)
}

@Test func deletingAllGroupsStaysEmptyAcrossRelaunch() throws {
    var config = AppConfiguration()
    config.applicationGroups = []
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.applicationGroups.isEmpty)
    #expect(restored.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: safari) == nil)
}

@Test func unsupportedFutureSettingsAreRejected() throws {
    var config = AppConfiguration(); config.version = 999
    let data = try JSONEncoder().encode(config)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(AppConfiguration.self, from: data) }
}

@Test func focusSwitchRequiresHeldFingersToLiftBeforeNextGesture() {
    var context = GestureFocusContext()
    #expect(context.update(bundleIdentifier: safari, processIdentifier: 1) == true)
    #expect(context.acceptsFrame(deviceID: 10, hasContacts: true) == true)
    let generation = context.generation
    #expect(context.update(bundleIdentifier: terminal, processIdentifier: 2) == true)
    #expect(context.generation != generation)
    #expect(context.acceptsFrame(deviceID: 10, hasContacts: true) == false)
    #expect(context.acceptsFrame(deviceID: 20, hasContacts: true) == true)
    #expect(context.acceptsFrame(deviceID: 10, hasContacts: false) == false)
    #expect(context.acceptsFrame(deviceID: 10, hasContacts: true) == true)
}

@Test func focusGenerationCancelsQueuedActionsEvenAfterSwitchingBack() {
    var context = GestureFocusContext()
    context.update(bundleIdentifier: safari, processIdentifier: 1)
    let queued = context.generation
    #expect(context.update(bundleIdentifier: safari, processIdentifier: 1) == false)
    #expect(context.generation == queued)
    context.update(bundleIdentifier: terminal, processIdentifier: 2)
    context.update(bundleIdentifier: safari, processIdentifier: 1)
    #expect(context.generation != queued)
    let oldProcess = context.generation
    context.update(bundleIdentifier: safari, processIdentifier: 3)
    #expect(context.generation != oldProcess)
}

@Test func disconnectClearsFocusReleaseGateForReconnectedDevice() {
    var context = GestureFocusContext()
    context.update(bundleIdentifier: safari, processIdentifier: 1)
    _ = context.acceptsFrame(deviceID: 10, hasContacts: true)
    context.update(bundleIdentifier: terminal, processIdentifier: 2)
    context.forgetDevices(except: [])
    #expect(context.acceptsFrame(deviceID: 10, hasContacts: true) == true)
}
