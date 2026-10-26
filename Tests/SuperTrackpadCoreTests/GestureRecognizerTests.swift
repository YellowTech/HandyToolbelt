import Testing
import Foundation
@testable import SuperTrackpadCore

private func fingers(_ count: Int, dx: Double = 0, dy: Double = 0) -> [Contact] {
    (0..<count).map { Contact(id: $0 + 1, x: 0.25 + Double($0) * 0.12 + dx, y: 0.45 + dy) }
}

@Test func threeAndFourFingerTaps() {
    for count in [3, 4] {
        var r = GestureRecognizer()
        #expect(r.process(fingers(count), at: 0).isEmpty)
        #expect(r.process(fingers(count), at: 0.06).isEmpty)
        #expect(r.process([], at: 0.12) == [.init(kind: .tap, fingers: count)])
        #expect(r.process([], at: 0.15).isEmpty)
    }
}

@Test func noTapForRestingFingerOrLongHold() {
    for count in [1, 3] {
        var r = GestureRecognizer()
        _ = r.process(fingers(count), at: 0)
        _ = r.process(fingers(count), at: 0.4)
        #expect(r.process([], at: 0.5).isEmpty)
    }
}

@Test func repeatedTipTapsWithOneStationaryAnchor() {
    var r = GestureRecognizer()
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    _ = r.process([anchor], at: 0)
    _ = r.process([anchor], at: 0.2)
    _ = r.process([anchor, Contact(id: 2, x: 0.3, y: 0.5)], at: 0.22)
    #expect(r.process([anchor], at: 0.32) == [.init(kind: .tipTapLeft)])
    _ = r.process([anchor, Contact(id: 3, x: 0.7, y: 0.5)], at: 0.4)
    #expect(r.process([anchor], at: 0.51) == [.init(kind: .tipTapRight)])
    #expect(r.process([], at: 0.6).isEmpty)
}

@Test func movingAnchorCancelsTipTap() {
    var r = GestureRecognizer()
    _ = r.process([Contact(id: 1, x: 0.5, y: 0.5)], at: 0)
    _ = r.process([Contact(id: 1, x: 0.5, y: 0.5), Contact(id: 2, x: 0.3, y: 0.5)], at: 0.2)
    #expect(r.process([Contact(id: 1, x: 0.6, y: 0.5)], at: 0.28).isEmpty)
    #expect(r.process([], at: 0.3).isEmpty)
}

@Test func simultaneousChordIsNotTipTap() {
    var r = GestureRecognizer()
    _ = r.process([Contact(id: 1, x: 0.4, y: 0.4)], at: 0)
    _ = r.process([Contact(id: 1, x: 0.4, y: 0.4), Contact(id: 2, x: 0.6, y: 0.4)], at: 0.03)
    #expect(r.process([], at: 0.12) == [.init(kind: .tap, fingers: 2)])
}

@Test func physicalClickEmitsAndDoesNotAlsoTap() {
    var r = GestureRecognizer()
    _ = r.process(fingers(4), at: 0)
    _ = r.process(fingers(4), at: 0.08)
    #expect(r.physicalClick(at: 0.09) == .init(kind: .click, fingers: 4))
    #expect(r.process([], at: 0.14).isEmpty)
    #expect(r.physicalClick(at: 0.3) == nil)
}

@Test func polledPhysicalButtonCancelsTapWithoutClickPermission() {
    var r = GestureRecognizer()
    _ = r.process(fingers(3), at: 0)
    _ = r.process(fingers(3), at: 0.08, physicalButtonDown: true)
    #expect(r.process([], at: 0.14).isEmpty)
}

@Test func cornerModifierExcludesHeldFingerAndSupportsRepeat() {
    var r = GestureRecognizer()
    let corner = Contact(id: 9, x: 0.07, y: 0.94)
    let corners: Set<Corner> = [.topLeft]
    _ = r.process([corner], at: 0, enabledCorners: corners)
    _ = r.process([corner], at: 0.27, enabledCorners: corners)
    #expect(r.modifier == .topLeft)
    for (time, count) in [(0.3, 2), (0.6, 1)] {
        _ = r.process([corner] + fingers(count), at: time, enabledCorners: corners)
        #expect(r.process([corner], at: time + 0.12, enabledCorners: corners) == [.init(kind: .tap, fingers: count, corner: .topLeft)])
    }
    #expect(r.process([], at: 0.8, enabledCorners: corners).isEmpty)
}

@Test func releasingCornerCannotTriggerUnmodifiedTap() {
    var r = GestureRecognizer()
    let corner = Contact(id: 9, x: 0.07, y: 0.94)
    let corners: Set<Corner> = [.topLeft]
    _ = r.process([corner], at: 0, enabledCorners: corners)
    _ = r.process([corner], at: 0.26, enabledCorners: corners)
    _ = r.process([corner] + fingers(3), at: 0.3, enabledCorners: corners)
    #expect(r.process(fingers(3), at: 0.36, enabledCorners: corners).isEmpty)
    #expect(r.process([], at: 0.4, enabledCorners: corners).isEmpty)
}

@Test func unusedCornersDoNotStealOrdinaryGestures() {
    var r = GestureRecognizer()
    let corner = Contact(id: 9, x: 0.07, y: 0.94)
    _ = r.process([corner], at: 0)
    _ = r.process([corner], at: 0.28)
    #expect(r.modifier == .none)
}

@Test func swipeFiresOnceAndDoesNotTapOnRelease() {
    var r = GestureRecognizer()
    _ = r.process(fingers(3), at: 0)
    #expect(r.process(fingers(3, dx: 0.15), at: 0.1) == [.init(kind: .swipeRight, fingers: 3)])
    #expect(r.process(fingers(3, dx: 0.2), at: 0.15).isEmpty)
    #expect(r.process([], at: 0.2).isEmpty)
}

@Test func liftingFingerAndPinchingDoNotLookLikeSwipes() {
    var r = GestureRecognizer()
    _ = r.process(fingers(3), at: 0)
    #expect(r.process(Array(fingers(3).dropFirst()), at: 0.1).isEmpty)
    var pinch = GestureRecognizer()
    _ = pinch.process([.init(id: 1, x: 0.3, y: 0.5), .init(id: 2, x: 0.7, y: 0.5)], at: 0)
    #expect(pinch.process([.init(id: 1, x: 0.1, y: 0.5), .init(id: 2, x: 0.9, y: 0.5)], at: 0.1).isEmpty)
    #expect(pinch.process([], at: 0.2).isEmpty)
}

@Test func lateFingerAndStaleFramesAreRejected() {
    var r = GestureRecognizer()
    _ = r.process(fingers(2), at: 0)
    _ = r.process(fingers(3), at: 0.2)
    #expect(r.process([], at: 0.27).isEmpty)
    _ = r.process(fingers(3), at: 1)
    #expect(r.process([], at: 3).isEmpty)
}

@Test func invalidCoordinatesAndDuplicateIDsDoNotEmit() {
    var r = GestureRecognizer()
    #expect(r.process([.init(id: 1, x: .nan, y: 0)], at: 0).isEmpty)
    #expect(r.process([.init(id: 1, x: 0.5, y: 0.5), .init(id: 1, x: 0.6, y: 0.5)], at: 0.1).isEmpty)
    #expect(r.process([], at: 0.2).isEmpty)
}

@Test func duplicateMappingsFailClosedAndPersist() throws {
    var config = AppConfiguration()
    let original = config.bindings[2]
    #expect(config.match(device: .trackpad, gesture: original.gesture)?.id == original.id)
    config.bindings.append(.init(gesture: original.gesture, action: .init(system: .mute)))
    #expect(config.hasConflict(original))
    #expect(config.match(device: .trackpad, gesture: original.gesture) == nil)
    config.bindings[config.bindings.count - 1].isEnabled = false
    #expect(config.match(device: .trackpad, gesture: original.gesture)?.id == original.id)
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.bindings == config.bindings)
    #expect(!restored.trackpadModuleEnabled)
}

@Test func incompleteDuplicateStillBlocksDispatch() {
    var config = AppConfiguration()
    let original = config.bindings[2]
    config.bindings.append(.init(gesture: original.gesture, action: .init(kind: .shortcut)))
    #expect(config.hasConflict(original))
    #expect(config.match(device: .trackpad, gesture: original.gesture) == nil)
}

@Test func tipTapWithCornerModifier() {
    var r = GestureRecognizer()
    let corner = Contact(id: 9, x: 0.06, y: 0.94)
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    let corners: Set<Corner> = [.topLeft]
    _ = r.process([corner], at: 0, enabledCorners: corners)
    _ = r.process([corner], at: 0.26, enabledCorners: corners)
    _ = r.process([corner, anchor], at: 0.3, enabledCorners: corners)
    _ = r.process([corner, anchor, .init(id: 2, x: 0.7, y: 0.5)], at: 0.5, enabledCorners: corners)
    #expect(r.process([corner, anchor], at: 0.61, enabledCorners: corners) == [.init(kind: .tipTapRight, corner: .topLeft)])
}

@Test func cornerClickCountsOnlyFreeFingers() {
    var r = GestureRecognizer()
    let corner = Contact(id: 9, x: 0.06, y: 0.94)
    let corners: Set<Corner> = [.topLeft]
    _ = r.process([corner], at: 0, enabledCorners: corners)
    _ = r.process([corner], at: 0.26, enabledCorners: corners)
    _ = r.process([corner] + fingers(3), at: 0.3, enabledCorners: corners)
    #expect(r.physicalClick(at: 0.32) == .init(kind: .click, fingers: 3, corner: .topLeft))
    #expect(r.process([corner], at: 0.4, enabledCorners: corners).isEmpty)
}

@Test func invalidFrameCancelsInProgressGesture() {
    var r = GestureRecognizer()
    _ = r.process(fingers(3), at: 0)
    #expect(r.process([.init(id: 1, x: .infinity, y: 0.5)], at: 0.08).isEmpty)
    #expect(r.process([], at: 0.15).isEmpty)
}
