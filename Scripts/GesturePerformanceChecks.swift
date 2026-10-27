// Development-only deterministic notification benchmark; never starts input or dispatches actions.
import AppKit
import Combine
import HandyToolbeltCore

@main
struct GesturePerformanceChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HandyToolbelt-performance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        try store.save(AppConfiguration())
        let model = AppModel(storage: store)
        var modelChanges = 0, visualChanges = 0
        let modelSubscription = model.objectWillChange.sink { modelChanges += 1 }
        let visualSubscription = model.touchVisualization.objectWillChange.sink { visualChanges += 1 }
        for _ in 0..<100 { model.refreshPermissions() }
        print("100 unchanged permission checks: \(modelChanges) AppModel notifications")
        check(modelChanges == 0, "Unchanged permission checks must not invalidate forms")
        modelChanges = 0
        for _ in 0..<100 { model.clearContactReadout() }
        check(modelChanges == 0, "Idle watchdog must not invalidate forms")
        model.contacts = [Contact(id: 1, x: 0.2, y: 0.3)]
        model.activeCorner = .topLeft; model.modifierFinger = 1
        model.clearContactReadout()
        check(model.contacts.isEmpty && model.activeCorner == .none && model.modifierFinger == nil, "Watchdog clears live state")
        modelChanges = 0
        for _ in 0..<100 { model.touchVisualization.reset() }
        print("100 idle visualization resets: \(visualChanges) visualization notifications")
        check(visualChanges == 0, "Repeated idle resets must not invalidate drawing")
        var readoutChanges = 0
        let readoutSubscription = model.gymReadout.objectWillChange.sink { readoutChanges += 1 }
        for i in 0..<120 {
            var snapshot = GymSnapshot(); snapshot.deviceName = "Frame \(i)"
            model.gymSnapshot = snapshot
        }
        print("120 Gym readouts: \(modelChanges) AppModel notifications")
        check(modelChanges == 0 && readoutChanges == 120, "Gym readouts must update below the form observation boundary")
        modelChanges = 0
        model.gymAttempts = [.init(message: "Attempt", matched: false, recognized: false)]
        model.gymAttempts = []
        check(modelChanges == 0, "Attempt history must not invalidate the parent forms")
        var stale = model.gymSnapshot
        stale.contacts = [Contact(id: 1, x: 0.2, y: 0.3)]
        stale.modifier = .topLeft; stale.modifierFinger = 1
        model.gymSnapshot = stale
        model.clearContactReadout()
        check(model.gymSnapshot.contacts.isEmpty && model.gymSnapshot.modifier == .none && model.gymSnapshot.modifierFinger == nil,
              "Watchdog releases diagnostic contacts and modifiers")
        check(model.gymSnapshot.feedback == stale.feedback, "Watchdog retains the diagnostic result")
        modelChanges = 0; visualChanges = 0
        for _ in 0..<20 { model.selectWorkspace(.gym); model.selectWorkspace(.mappings) }
        print("20 Mappings/Gym round trips: \(modelChanges) AppModel, \(visualChanges) visualization notifications")
        check(modelChanges <= 41 && visualChanges == 0, "Idle workspace navigation must avoid repeated reset publications")
        let visualization = model.touchVisualization
        var pressChanges = 0
        let pressSubscription = visualization.pressReadout.objectWillChange.sink { pressChanges += 1 }
        visualChanges = 0
        for i in 0..<120 {
            let time = 10 + Double(i) / 120
            visualization.submit(GymSnapshot(contacts: [Contact(id: 1, x: Double(i) / 150, y: 0.4, pressure: Double(i) / 20)]), deviceID: 1, at: time)
            check(visualization.render(at: time), "Live contacts keep display sampling active")
        }
        print("120 moving/pressure frames: \(visualChanges) drawing, \(pressChanges) pressure-readout notifications")
        check(visualChanges == 120 && pressChanges == 1, "Full-rate drawings preserve positions/pressure without invalidating the press text")
        check(visualization.frame.contacts[0].position.x > 0.7 && visualization.frame.contacts[0].pressure! > 5, "Position and pressure keep following input")
        visualChanges = 0
        visualization.updatePress(stage: 2, at: 11)
        visualization.submit(GymSnapshot(contacts: [Contact(id: 1, x: 0.9, y: 0.6)]), deviceID: 1, at: 11)
        check(visualization.render(at: 11), "Click animation remains active")
        check(visualChanges == 1 && visualization.press.kind == .forceClick && visualization.pressReadout.state.press.kind == .forceClick,
              "Concurrent position and click changes draw once and forward the actual native stage")
        visualization.submit(GymSnapshot(), deviceID: 1, at: 11.01)
        _ = visualization.render(at: 11.01)
        check(visualization.frame.contacts.isEmpty && !visualization.pressReadout.state.isTouching, "Lift is immediate")
        check(!visualization.render(at: 11.7) && visualization.press.kind == .touch, "Feedback tail stops within 650 ms")
        visualization.submit(GymSnapshot(contacts: [Contact(id: 2, x: 0.2, y: 0.4)]), deviceID: 2, at: 12)
        _ = visualization.render(at: 12)
        check(!visualization.render(at: 12.3) && visualization.frame.contacts.isEmpty, "Stale input releases drawing and stops clock")
        print("Gesture performance regressions passed")
        withExtendedLifetime([modelSubscription, visualSubscription, readoutSubscription, pressSubscription]) {}
    }
}
