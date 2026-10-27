import XCTest
@testable import HandyToolbeltCore

final class AutomationTests: XCTestCase {
    func testLegacyMigrationAndCanonicalRevision() throws {
        var config = AppConfiguration()
        config.displayModuleEnabled = true
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json["version"] = 5
        json.removeValue(forKey: "automations"); json.removeValue(forKey: "displayModuleEnabled")
        let migrated = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(migrated.displayModuleEnabled); XCTAssertTrue(migrated.automations.isEmpty)
        XCTAssertEqual(try config.revision(), try migrated.revision())
        XCTAssertTrue(config.validation().isValid)
    }
    func testAutomationValidation() {
        var config = AppConfiguration()
        let step = AutomationStep(name: "Wait", delay: 1)
        config.automations = [.init(name: "Prepare", steps: [step])]
        XCTAssertTrue(config.validation().isValid)
        config.automations[0].steps[0].delay = 31
        XCTAssertFalse(config.validation().isValid)
        config.automations[0].steps[0].delay = .infinity
        XCTAssertFalse(config.validation().isValid)
        config.automations[0].steps = Array(repeating: step, count: 33)
        XCTAssertTrue(config.validation().errors.contains { $0.contains("1–32") })
    }
    func testNestedAndMissingReferences() {
        var config = AppConfiguration()
        config.automations = [.init(name: "Nested", steps: [.init(name: "Run", action: .init(kind: .automation, automationID: UUID()))])]
        XCTAssertTrue(config.validation().errors.contains { $0.contains("nested") })
        config.automations = []
        config.bindings = [.init(gesture: .init(kind: .tap), action: .init(kind: .automation, automationID: UUID()))]
        XCTAssertTrue(config.validation().errors.contains { $0.contains("missing automation") })
    }
    func testDisabledIncompleteActionIsWarning() {
        var config = AppConfiguration()
        config.bindings = [.init(gesture: .init(kind: .tap), action: .init(kind: .shortcut), isEnabled: false)]
        XCTAssertTrue(config.validation().isValid); XCTAssertEqual(config.validation().warnings.count, 1)
        config.bindings[0].isEnabled = true
        XCTAssertFalse(config.validation().isValid)
    }
    func testGestureConflictsAndTuningBounds() {
        var config = AppConfiguration()
        let first = GestureBinding(gesture: .init(kind: .tap), action: .init())
        config.bindings = [first, .init(gesture: first.gesture, action: first.action)]
        XCTAssertFalse(config.validation().isValid)
        config.bindings = []; config.trackpadTuning.tapDuration = .nan
        XCTAssertFalse(config.validation().isValid)
    }
    func testProgressExpiryRenewalAndTerminalDeadline() {
        var now = 0.0
        var sessions = ProgressSessions(now: { now })
        var progress = WorkflowProgress(title: "Prepare", steps: ["First", "Second"])
        sessions.begin(progress)
        now = 29; XCTAssertTrue(sessions.update(progress))
        now = 31; sessions.expire(); XCTAssertNotNil(sessions.latest)
        progress.steps[0].state = .completed; progress.state = .completed
        XCTAssertTrue(sessions.update(progress)); XCTAssertEqual(progress.completedCount, 1)
        now = 32; sessions.expire(); XCTAssertNil(sessions.latest)
    }
    func testProgressBoundedMetadataAndActivePriority() {
        var now = 0.0
        var sessions = ProgressSessions(now: { now })
        for index in 0..<5 { sessions.begin(.init(title: "\(index)", steps: ["Step"])) }
        XCTAssertEqual(sessions.sessions.count, 4)
        var latest = sessions.latest!.progress; latest.state = .completed
        sessions.update(latest)
        XCTAssertEqual(sessions.latest?.progress.title, "3")
        sessions.dismiss(); XCTAssertTrue(sessions.sessions.isEmpty)
        sessions.begin(.init(title: "Expired", steps: ["Step"]))
        now = 30; sessions.expire(); XCTAssertNil(sessions.latest)
    }
    func testOwnedProgressSurvivesLongActionsAndExpiresAfterTerminalUpdate() {
        var now = 0.0
        var sessions = ProgressSessions(now: { now })
        var owned = WorkflowProgress(title: "Long action", steps: ["Wait", "Finish"])
        sessions.begin(owned, lifetime: .automation)
        XCTAssertNil(sessions.nextExpiry)
        var external = WorkflowProgress(title: "Quick external", steps: ["Step"])
        sessions.begin(external)
        external.state = .completed
        XCTAssertTrue(sessions.update(external))
        XCTAssertEqual(sessions.latest?.progress.id, owned.id)
        now = 90; sessions.expire()
        XCTAssertEqual(sessions.latest?.progress.id, owned.id)
        owned.steps[0].state = .completed
        XCTAssertTrue(sessions.update(owned))
        owned.state = .completed
        XCTAssertTrue(sessions.update(owned))
        XCTAssertEqual(sessions.nextExpiry, 91)
        now = 91; sessions.expire()
        XCTAssertFalse(sessions.update(owned))
        XCTAssertNil(sessions.latest)
    }
    func testExternalExpiryAndDismissedOwnedProgressCannotResurrect() {
        var now = 0.0
        var sessions = ProgressSessions(now: { now })
        let external = WorkflowProgress(title: "External", steps: ["Step"])
        var owned = WorkflowProgress(title: "Owned", steps: ["Step"])
        sessions.begin(owned, lifetime: .automation)
        sessions.begin(external)
        now = 30; sessions.expire()
        XCTAssertFalse(sessions.update(external))
        XCTAssertEqual(sessions.latest?.progress.id, owned.id)
        sessions.dismiss(owned.id)
        owned.state = .completed
        XCTAssertFalse(sessions.update(owned))
        sessions.begin(owned, lifetime: .automation)
        sessions.dismiss() // Overlays disabling or the user session becoming unavailable.
        XCTAssertFalse(sessions.update(owned))
        XCTAssertNil(sessions.latest)
    }
    func testOwnedFailureAndCancellationExpireAfterThreeSeconds() {
        for state in [WorkflowState.failed, .cancelled] {
            var now = 0.0
            var sessions = ProgressSessions(now: { now })
            var owned = WorkflowProgress(title: "Owned", steps: ["Step"])
            sessions.begin(owned, lifetime: .automation)
            now = 100; owned.state = state
            XCTAssertTrue(sessions.update(owned))
            XCTAssertEqual(sessions.nextExpiry, 103)
            now = 103; sessions.expire()
            XCTAssertFalse(sessions.update(owned))
        }
    }
    func testOrdinaryOneFingerGesturesAreRejectedButCornerAndStackChildrenRemainValid() {
        for kind in [GestureKind.tap, .click, .swipeLeft] {
            var config = AppConfiguration()
            config.bindings = [.init(gesture: .init(kind: kind, fingers: 1), action: .init())]
            XCTAssertTrue(config.validation().errors.contains { $0.contains("invalid finger count") })
            config.bindings[0].gesture.fingers = 2
            XCTAssertTrue(config.validation().isValid)
            config.bindings[0].gesture.fingers = 1
            config.bindings[0].gesture.corner = .topLeft
            XCTAssertTrue(config.validation().isValid)
            config.bindings = []
            config.stacks = [.init(isEnabled: true, bindings: [.init(gesture: .init(kind: kind, fingers: 1), actions: [.init()])])]
            XCTAssertTrue(config.validation().isValid)
        }
    }

}
