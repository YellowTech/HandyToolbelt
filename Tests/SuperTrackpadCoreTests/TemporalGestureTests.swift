import Foundation
import Testing
@testable import SuperTrackpadCore

private func temporalContacts(_ start: Int = 1, x: Double = 0.4) -> [Contact] {
    [Contact(id: start, x: x, y: 0.5), Contact(id: start + 1, x: x + 0.1, y: 0.5)]
}
private let doubleSpec = GestureSpec(kind: .doubleTap, fingers: 2)
private let longSpec = GestureSpec(kind: .longTouch, fingers: 2)

@Test func temporalLongThresholdOnceAndRearm() {
    var r = GestureRecognizer(); let c = temporalContacts()
    #expect(r.process(c, at: 0, eligibleTemporalSpecs: [longSpec]).isEmpty)
    #expect(r.process(c, at: 0.54, eligibleTemporalSpecs: [longSpec]).isEmpty)
    #expect(r.advanceTime(to: 0.55).isEmpty) // no synthetic hold frames
    #expect(r.process(c, at: 0.55, eligibleTemporalSpecs: [longSpec]) == [longSpec])
    #expect(r.process(c, at: 0.7, eligibleTemporalSpecs: [longSpec]).isEmpty)
    #expect(r.beginPhysicalPress(at: 0.71, allowSingleFinger: false) == nil)
    #expect(r.process([], at: 0.75, eligibleTemporalSpecs: [longSpec]).isEmpty)
    #expect(r.process(c, at: 0.8, eligibleTemporalSpecs: [longSpec]).isEmpty)
    #expect(r.process(c, at: 1.36, eligibleTemporalSpecs: [longSpec]) == [longSpec])
}

@Test func temporalLongMovementMembershipAndClickCancel() {
    for failure in 0..<4 {
        var r = GestureRecognizer(); let c = temporalContacts()
        _ = r.process(c, at: 0, eligibleTemporalSpecs: [longSpec])
        var invalid = c
        if failure == 0 { invalid[0].position.x += 0.04 }
        if failure == 1 { invalid[0].id = 9 }
        if failure == 2 { invalid.append(Contact(id: 9, x: 0.7, y: 0.5)) }
        _ = r.process(invalid, at: 0.2, physicalButtonDown: failure == 3, eligibleTemporalSpecs: [longSpec])
        #expect(r.process(c, at: 0.56, eligibleTemporalSpecs: [longSpec]).isEmpty)
    }
    var unbound = GestureRecognizer(); let c = temporalContacts()
    _ = unbound.process(c, at: 0)
    #expect(unbound.process(c, at: 0.56).isEmpty)
    #expect(unbound.beginPhysicalPress(at: 0.57, allowSingleFinger: false)?.kind == .click)
}

@Test func temporalImmediateAndDeferredSingles() {
    let c = temporalContacts()
    var immediate = GestureRecognizer()
    _ = immediate.process(c, at: 0); _ = immediate.process(c, at: 0.05)
    #expect(immediate.process([], at: 0.1).map(\.kind) == [.tap])
    var r = GestureRecognizer()
    _ = r.process(c, at: 0, eligibleTemporalSpecs: [doubleSpec])
    _ = r.process(c, at: 0.05, eligibleTemporalSpecs: [doubleSpec])
    #expect(r.process([], at: 0.1, eligibleTemporalSpecs: [doubleSpec]).isEmpty)
    #expect(r.nextDeadline == 0.38)
    #expect(r.advanceTime(to: 0.379).isEmpty)
    #expect(r.advanceTime(to: 0.38).map(\.kind) == [.tap])
    #expect(r.advanceTime(to: 0.5).isEmpty)
}

@Test func temporalDoubleNearBoundaryDifferentIDsAndTriple() {
    var r = GestureRecognizer(); let c = temporalContacts()
    _ = r.process(c, at: 0, eligibleTemporalSpecs: [doubleSpec])
    _ = r.process(c, at: 0.05, eligibleTemporalSpecs: [doubleSpec])
    _ = r.process([], at: 0.1, eligibleTemporalSpecs: [doubleSpec])
    let next = temporalContacts(7, x: 0.42)
    _ = r.process(next, at: 0.379, eligibleTemporalSpecs: [doubleSpec])
    #expect(r.nextDeadline == nil)
    #expect(r.advanceTime(to: 0.5).isEmpty)
    _ = r.process(next, at: 0.5, eligibleTemporalSpecs: [doubleSpec])
    #expect(r.process([], at: 0.6, eligibleTemporalSpecs: [doubleSpec]) == [doubleSpec])
    _ = r.process(c, at: 0.7, eligibleTemporalSpecs: [doubleSpec])
    _ = r.process(c, at: 0.75, eligibleTemporalSpecs: [doubleSpec])
    #expect(r.process([], at: 0.8, eligibleTemporalSpecs: [doubleSpec]).isEmpty)
    #expect(r.advanceTime(to: 1.081).map(\.kind) == [.tap])
}

@Test func temporalInvalidSecondCancelsRatherThanDeliveringFirst() {
    for invalid in 0..<5 {
        var r = GestureRecognizer(); let c = temporalContacts()
        _ = r.process(c, at: 0, eligibleTemporalSpecs: [doubleSpec])
        _ = r.process(c, at: 0.05, eligibleTemporalSpecs: [doubleSpec])
        _ = r.process([], at: 0.1, eligibleTemporalSpecs: [doubleSpec])
        var second = temporalContacts(5, x: invalid == 4 ? 0.65 : 0.4)
        _ = r.process(second, at: 0.2, eligibleTemporalSpecs: [doubleSpec])
        if invalid == 0 { second[0].position.x += 0.05 }
        if invalid == 1 { second[0].id = 9 }
        _ = r.process(second, at: invalid == 2 ? 0.51 : 0.25, physicalButtonDown: invalid == 3, eligibleTemporalSpecs: [doubleSpec])
        #expect(r.process([], at: 0.52, eligibleTemporalSpecs: [doubleSpec]).isEmpty)
        #expect(r.advanceTime(to: 0.9).isEmpty)
    }
}

@Test func temporalCancelAndCornerRearm() {
    var r = GestureRecognizer(); let c = temporalContacts()
    _ = r.process(c, at: 0, eligibleTemporalSpecs: [doubleSpec])
    _ = r.process(c, at: 0.05, eligibleTemporalSpecs: [doubleSpec])
    _ = r.process([], at: 0.1, eligibleTemporalSpecs: [doubleSpec])
    r.cancelTemporalGestures()
    #expect(r.advanceTime(to: 0.4).isEmpty)
    let owner = Contact(id: 10, x: 0.05, y: 0.95)
    let spec = GestureSpec(kind: .longTouch, fingers: 2, corner: .topLeft)
    _ = r.process([owner], at: 0.5, enabledCorners: [.topLeft], eligibleTemporalSpecs: [spec])
    _ = r.process([owner], at: 0.76, enabledCorners: [.topLeft], eligibleTemporalSpecs: [spec])
    for start in [0.8, 1.5] {
        _ = r.process([owner] + c, at: start, enabledCorners: [.topLeft], eligibleTemporalSpecs: [spec])
        #expect(r.process([owner] + c, at: start + 0.56, enabledCorners: [.topLeft], eligibleTemporalSpecs: [spec]) == [spec])
        #expect(r.beginPhysicalPress(at: start + 0.57, allowSingleFinger: false) == nil)
        #expect(r.process([owner], at: start + 0.6, enabledCorners: [.topLeft], eligibleTemporalSpecs: [spec]).isEmpty)
    }
}

@Test func temporalTuningLegacyDefaultsAndLimits() throws {
    let encoder = JSONEncoder()
    var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(GestureTuning())) as? [String: Any])
    object.removeValue(forKey: "longTouchDuration"); object.removeValue(forKey: "doubleTapInterval")
    let legacy = try JSONDecoder().decode(GestureTuning.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.longTouchDuration == 0.55 && legacy.doubleTapInterval == 0.28)
    #expect(try JSONDecoder().decode(GestureTuning.self, from: encoder.encode(legacy)) == legacy)
    var limits = legacy; limits.longTouchDuration = 20; limits.doubleTapInterval = .nan
    #expect(limits.validated.longTouchDuration == 1.5 && limits.validated.doubleTapInterval == 0.28)
}
