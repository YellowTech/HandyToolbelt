import Testing
import Foundation
@testable import HandyToolbeltCore

private func anchors(_ count: Int) -> [Contact] {
    (0..<count).map { Contact(id: $0 + 1, x: 0.4 + Double($0) * 0.08, y: 0.5) }
}

@Test func expandedTipTapCountsAndMiddle() {
    for count in 1...3 {
        for (x, kind) in [(0.2, GestureKind.tipTapLeft), (0.85, .tipTapRight)] {
            var r = GestureRecognizer()
            let held = anchors(count)
            _ = r.process(held, at: 0)
            _ = r.process(held + [Contact(id: 8, x: x, y: 0.5)], at: 0.2)
            #expect(r.process(held, at: 0.28) == [.init(kind: kind, fingers: count + 1)])
            #expect(r.process([], at: 0.3).isEmpty)
        }
    }
    var r = GestureRecognizer()
    let held = [Contact(id: 1, x: 0.3, y: 0.5), Contact(id: 2, x: 0.7, y: 0.5)]
    _ = r.process(held, at: 0)
    _ = r.process(held + [Contact(id: 3, x: 0.5, y: 0.5)], at: 0.2)
    #expect(r.process(held, at: 0.28) == [.init(kind: .tipTapMiddle)])
}

@Test func anchoredSwipeDirectionsRepeatAndNoTap() {
    for count in 1...3 {
        for (dx, dy, kind) in [(-0.18, 0.0, GestureKind.tipSwipeLeft), (0.18, 0, .tipSwipeRight), (0, 0.22, .tipSwipeUp), (0, -0.22, .tipSwipeDown)] {
            var r = GestureRecognizer()
            let held = anchors(count)
            _ = r.process(held, at: 0)
            for stroke in 0...1 {
                let t = 0.2 + Double(stroke) * 0.25
                _ = r.process(held + [Contact(id: 8, x: 0.75, y: 0.5)], at: t)
                let moved = held + [Contact(id: 8, x: 0.75 + dx, y: 0.5 + dy)]
                #expect(r.process(moved, at: t + 0.06) == [.init(kind: kind, fingers: count + 1)])
                #expect(r.process(moved, at: t + 0.08).isEmpty)
                #expect(r.process(held, at: t + 0.1).isEmpty)
            }
            #expect(r.process([], at: 0.6).isEmpty)
        }
    }
}

@Test func anchoredRejectsAnchorChangesAndClick() {
    for mutation in 0...4 {
        var r = GestureRecognizer()
        let held = anchors(2)
        let active = Contact(id: 8, x: 0.8, y: 0.5)
        _ = r.process(held, at: 0)
        _ = r.process(held + [active], at: 0.2)
        var changed = held
        switch mutation {
        case 0: changed.removeFirst()
        case 1: changed[0].id = 20
        case 2: changed[0].position.x += 0.1
        case 3: changed.append(Contact(id: 20, x: 0.2, y: 0.4))
        default: #expect(r.physicalClick(at: 0.21) == .init(kind: .click, fingers: 3))
        }
        #expect(r.process(changed, at: 0.28, physicalButtonDown: mutation == 4).isEmpty)
        #expect(r.process([], at: 0.32).isEmpty)
    }
}

@Test func slowAnchoredSwipeDoesNotReportPrematureFailure() {
    var recognizer = GestureRecognizer()
    let held = anchors(2)
    let active = Contact(id: 8, x: 0.75, y: 0.5)
    _ = recognizer.process(held, at: 0)
    _ = recognizer.process(held + [active], at: 0.2)
    #expect(recognizer.process(held + [active], at: 0.55).isEmpty)
    #expect(recognizer.feedbackSequence == 0)
    #expect(recognizer.feedback.phase == .candidate)
    #expect(recognizer.process(held + [.init(id: 8, x: 0.95, y: 0.5)], at: 0.65) == [.init(kind: .tipSwipeRight, fingers: 3)])
    #expect(recognizer.feedbackSequence == 1)
    #expect(recognizer.process(held, at: 0.7).isEmpty)
}

@Test func anchoredCountsAndLegacyCodable() throws {
    #expect(GestureSpec(kind: .tipTapLeft).fingers == 2)
    #expect(GestureSpec(kind: .tipTapMiddle).fingers == 3)
    #expect(GestureSpec(kind: .tipSwipeUp, fingers: 5).normalized().fingers == 4)
    #expect(GestureSpec(kind: .tipTapMiddle, fingers: 2).normalized().fingers == 3)
    #expect(GestureSpec(kind: .tap).allowedFingerCounts(isStackChild: true) == [1, 2, 3, 4])
    #expect(GestureSpec(kind: .tipTapRight, fingers: 4, corner: .topLeft).totalFingerCount == 5)
    let legacy = Data(#"{"kind":"tipTapLeft","fingers":2,"corner":"none"}"#.utf8)
    #expect(try JSONDecoder().decode(GestureSpec.self, from: legacy) == .init(kind: .tipTapLeft))
    var config = AppConfiguration()
    config.bindings = [.init(gesture: .init(kind: .tipTapMiddle, fingers: 2), action: .init())]
    #expect(!config.validation().errors.isEmpty)
}

@Test func middleUsesTiltedHandAxis() {
    var r = GestureRecognizer()
    r.tuning.handAngleDegrees = 60
    let held = [Contact(id: 1, x: 0.5, y: 0.2), Contact(id: 2, x: 0.5, y: 0.8)]
    _ = r.process(held, at: 0)
    _ = r.process(held + [Contact(id: 3, x: 0.5, y: 0.5)], at: 0.2)
    #expect(r.process(held, at: 0.28) == [.init(kind: .tipTapMiddle)])
}

@Test func fourFreeFingerAnchoredSwipeWithCornerAndStackCounts() throws {
    var r = GestureRecognizer()
    let corner = Contact(id: 90, x: 0.05, y: 0.95)
    let corners: Set<Corner> = [.topLeft]
    let held = anchors(3)
    _ = r.process([corner], at: 0, enabledCorners: corners)
    _ = r.process([corner], at: 0.3, enabledCorners: corners)
    _ = r.process([corner] + held, at: 0.32, enabledCorners: corners)
    _ = r.process([corner] + held + [Contact(id: 8, x: 0.75, y: 0.5)], at: 0.52, enabledCorners: corners)
    #expect(r.process([corner] + held + [Contact(id: 8, x: 0.95, y: 0.5)], at: 0.58, enabledCorners: corners) == [.init(kind: .tipSwipeRight, fingers: 4, corner: .topLeft)])
    #expect(r.physicalClick(at: 0.59) == nil)
    #expect(r.process([corner] + held, at: 0.62, enabledCorners: corners).isEmpty)
    #expect(r.process([], at: 0.65, enabledCorners: corners).isEmpty)
    var configuration = AppConfiguration()
    configuration.stacks = [.init(name: "Anchored", isEnabled: true, bindings: [.init(gesture: .init(kind: .tipSwipeRight, fingers: 4), actions: [.init(system: .nextTab)])])]
    #expect(configuration.validation().errors.isEmpty)
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(restored.version == 6)
    #expect(restored.stacks.first?.bindings.first?.gesture.fingers == 4)
}

@Test func anchoredClickDispatchIsIndependentOfRawButtonOrdering() {
    for rawFirst in [false, true] {
        for swipeEmitted in [false, true] {
            var r = GestureRecognizer()
            let held = anchors(2)
            var frame = held + [Contact(id: 8, x: 0.75, y: 0.5)]
            _ = r.process(held, at: 0)
            _ = r.process(frame, at: 0.2)
            if swipeEmitted {
                frame[2].position.x = 0.95
                #expect(r.process(frame, at: 0.25) == [.init(kind: .tipSwipeRight, fingers: 3)])
            }
            if rawFirst { #expect(r.process(frame, at: 0.26, physicalButtonDown: true).isEmpty) }
            #expect(r.physicalClick(at: 0.27) == (swipeEmitted ? nil : .init(kind: .click, fingers: 3)))
            if !rawFirst { #expect(r.process(frame, at: 0.28, physicalButtonDown: true).isEmpty) }
            #expect(r.process(held, at: 0.3).isEmpty)
            #expect(r.process([], at: 0.32).isEmpty)
        }
    }
}

@Test func replacingAllAnchorsRequiresFullRelease() {
    var r = GestureRecognizer()
    let held = anchors(2)
    let active = Contact(id: 8, x: 0.75, y: 0.5)
    _ = r.process(held, at: 0)
    _ = r.process(held + [active], at: 0.2)
    let replacement = held.map { Contact(id: $0.id + 30, x: $0.position.x, y: $0.position.y) }
    #expect(r.process(replacement + [active], at: 0.24).isEmpty)
    #expect(r.process(replacement, at: 0.28).isEmpty)
    #expect(r.process(replacement + [Contact(id: 9, x: 0.8, y: 0.5)], at: 0.48).isEmpty)
    #expect(r.process(replacement, at: 0.54).isEmpty)
    #expect(r.process([], at: 0.56).isEmpty)
    _ = r.process(held, at: 0.6)
    _ = r.process(held + [active], at: 0.8)
    #expect(r.process(held, at: 0.88) == [.init(kind: .tipTapRight, fingers: 3)])
}

@Test func cornerAcquisitionAndAnchoredAttemptCannotCreateChordTap() {
    var r = GestureRecognizer()
    let corner = Contact(id: 90, x: 0.05, y: 0.95)
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    let tapper = Contact(id: 2, x: 0.75, y: 0.5)
    let corners: Set<Corner> = [.topLeft]
    _ = r.process([corner, anchor], at: 0, enabledCorners: corners)
    #expect(r.process([corner, anchor, tapper], at: 0.26, enabledCorners: corners).isEmpty)
    #expect(r.process([corner, anchor], at: 0.32, enabledCorners: corners) == [.init(kind: .tipTapRight, corner: .topLeft)])
    #expect(r.process([corner], at: 0.38, enabledCorners: corners).isEmpty)
    #expect(r.process([], at: 0.4, enabledCorners: corners).isEmpty)
}
