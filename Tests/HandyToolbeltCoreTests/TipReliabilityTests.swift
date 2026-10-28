import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func movedAnchorsSettleBeforeTip() {
    var r = GestureRecognizer()
    _ = r.process([.init(id: 1, x: 0.2, y: 0.5)], at: 0)
    let held = [Contact(id: 1, x: 0.5, y: 0.5)]
    _ = r.process(held, at: 0.1)
    _ = r.process(held, at: 0.3)
    _ = r.process(held + [.init(id: 2, x: 0.7, y: 0.5)], at: 0.31)
    #expect(r.process(held, at: 0.4) == [.init(kind: .tipTapRight)])
}

@Test func distantAndRimAnchorsCannotArmTips() {
    for (anchorX, tapX) in [(0.2, 0.9), (0.02, 0.25), (0.98, 0.7)] {
        var r = GestureRecognizer()
        let held = [Contact(id: 1, x: anchorX, y: 0.5)]
        _ = r.process(held, at: 0)
        _ = r.process(held + [.init(id: 2, x: tapX, y: 0.5)], at: 0.2)
        #expect(r.process(held, at: 0.28).isEmpty)
    }
}

@Test func nearRimPalmContactCannotArmTipWithDefaultDeadzone() {
    // Rounded contact geometry from a reported accidental tip-tap. The anchor
    // sits just beyond the old 4% rim; an intentional inset anchor still works.
    func tip(anchorX: Double, tuning: GestureTuning) -> [GestureSpec] {
        var r = GestureRecognizer()
        r.tuning = tuning
        r.surfaceAspectRatio = 1.625
        let held = [Contact(id: 1, x: anchorX, y: 0.343)]
        _ = r.process(held, at: 0)
        _ = r.process(held, at: 0.2)
        _ = r.process(held + [.init(id: 2, x: 0.549, y: 0.638)], at: 0.3)
        return r.process(held, at: 0.43)
    }
    var previous = GestureTuning()
    previous.tipEdgeDeadzone = 0.04
    #expect(tip(anchorX: 0.952, tuning: previous) == [.init(kind: .tipTapLeft)])
    #expect(tip(anchorX: 0.952, tuning: .init()).isEmpty)
    #expect(tip(anchorX: 0.93, tuning: .init()) == [.init(kind: .tipTapLeft)])
}

@Test func enabledDoubleTipDisambiguatesAndFlushesSingle() {
    for count in 1...3 {
        for left in [false, true] {
            var r = GestureRecognizer()
            let held = (1...count).map { Contact(id: $0, x: 0.4 + Double($0 - 1) * 0.06, y: 0.5) }
            let single = GestureSpec(kind: left ? .tipTapLeft : .tipTapRight, fingers: count + 1)
            let double = GestureSpec(kind: left ? .doubleTipTapLeft : .doubleTipTapRight, fingers: count + 1)
            let active = Contact(id: 8, x: left ? 0.25 : 0.75, y: 0.5)
            let enabled: Set<GestureSpec> = [double]
            _ = r.process(held, at: 0, eligibleTemporalSpecs: enabled)
            _ = r.process(held + [active], at: 0.2, eligibleTemporalSpecs: enabled)
            #expect(r.process(held, at: 0.26, eligibleTemporalSpecs: enabled).isEmpty)
            #expect(r.nextDeadline != nil)
            _ = r.process(held + [active], at: 0.36, eligibleTemporalSpecs: enabled)
            #expect(r.process(held, at: 0.43, eligibleTemporalSpecs: enabled) == [double])
            #expect(r.advanceTime(to: 0.8).isEmpty)
            _ = r.process(held + [active], at: 0.9, eligibleTemporalSpecs: enabled)
            #expect(r.process(held, at: 0.96, eligibleTemporalSpecs: enabled).isEmpty)
            #expect(r.advanceTime(to: 1.25) == [single])
        }
    }
}

@Test func pendingTipCancelsOnAnchorLossMovementContextAndClick() {
    for mutation in 0...4 {
        var r = GestureRecognizer()
        let held = [Contact(id: 1, x: 0.5, y: 0.5)]
        let enabled: Set<GestureSpec> = [.init(kind: .doubleTipTapRight)]
        _ = r.process(held, at: 0, eligibleTemporalSpecs: enabled)
        _ = r.process(held + [.init(id: 2, x: 0.7, y: 0.5)], at: 0.2, eligibleTemporalSpecs: enabled)
        _ = r.process(held, at: 0.26, eligibleTemporalSpecs: enabled)
        if mutation == 0 { _ = r.process([], at: 0.3, eligibleTemporalSpecs: enabled) }
        if mutation == 1 { _ = r.process([.init(id: 1, x: 0.6, y: 0.5)], at: 0.3, eligibleTemporalSpecs: enabled) }
        if mutation == 2 { r.cancelTemporalGestures() }
        if mutation == 3 { _ = r.physicalClick(at: 0.3) }
        if mutation == 4 { _ = r.process(held, at: 0.3) }
        #expect(r.advanceTime(to: 0.6).isEmpty)
    }
}

@Test func doubleMiddleTipAllowsSmallJitterAndRequiresSameAnchors() {
    var r = GestureRecognizer()
    var held = [Contact(id: 1, x: 0.35, y: 0.5), Contact(id: 2, x: 0.65, y: 0.5)]
    let enabled: Set<GestureSpec> = [.init(kind: .doubleTipTapMiddle)]
    _ = r.process(held, at: 0, eligibleTemporalSpecs: enabled)
    _ = r.process(held + [.init(id: 3, x: 0.5, y: 0.5)], at: 0.2, eligibleTemporalSpecs: enabled)
    _ = r.process(held, at: 0.26, eligibleTemporalSpecs: enabled)
    held[0].position.x += 0.005
    _ = r.process(held + [.init(id: 4, x: 0.505, y: 0.5)], at: 0.36, eligibleTemporalSpecs: enabled)
    #expect(r.process(held, at: 0.43, eligibleTemporalSpecs: enabled) == [.init(kind: .doubleTipTapMiddle)])
}

@Test func doubleTipSupportsCornerAndStackCounts() throws {
    let spec = GestureSpec(kind: .doubleTipTapRight, fingers: 4, corner: .topLeft)
    var r = GestureRecognizer()
    let corner = Contact(id: 90, x: 0.02, y: 0.98)
    let held = [Contact(id: 1, x: 0.4, y: 0.5), Contact(id: 2, x: 0.46, y: 0.5), Contact(id: 3, x: 0.52, y: 0.5)]
    let corners: Set<Corner> = [.topLeft], enabled: Set<GestureSpec> = [spec]
    _ = r.process([corner], at: 0, enabledCorners: corners, eligibleTemporalSpecs: enabled)
    _ = r.process([corner], at: 0.3, enabledCorners: corners, eligibleTemporalSpecs: enabled)
    _ = r.process([corner] + held, at: 0.31, enabledCorners: corners, eligibleTemporalSpecs: enabled)
    for start in [0.51, 0.71] {
        _ = r.process([corner] + held + [.init(id: 8, x: 0.7, y: 0.5)], at: start, enabledCorners: corners, eligibleTemporalSpecs: enabled)
        let result = r.process([corner] + held, at: start + 0.06, enabledCorners: corners, eligibleTemporalSpecs: enabled)
        #expect(result == (start == 0.71 ? [spec] : []))
    }
    var configuration = AppConfiguration()
    configuration.stacks = [.init(name: "Double tip", isEnabled: true, bindings: [.init(gesture: .init(kind: .doubleTipTapRight, fingers: 4), actions: [.init(system: .nextTab)])])]
    #expect(configuration.validation().errors.isEmpty)
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(restored.stacks.first?.bindings.first?.gesture.kind == .doubleTipTapRight)
}

@Test func incompatibleSecondTipPreservesCompletedSingle() {
    for secondX in [0.3, 0.82] {
        var r = GestureRecognizer()
        let held = [Contact(id: 1, x: 0.5, y: 0.5)]
        let enabled: Set<GestureSpec> = [.init(kind: .doubleTipTapRight), .init(kind: .doubleTipTapLeft)]
        _ = r.process(held, at: 0, eligibleTemporalSpecs: enabled)
        _ = r.process(held + [.init(id: 2, x: 0.7, y: 0.5)], at: 0.2, eligibleTemporalSpecs: enabled)
        #expect(r.process(held, at: 0.26, eligibleTemporalSpecs: enabled).isEmpty)
        #expect(r.process(held + [.init(id: 3, x: secondX, y: 0.5)], at: 0.36, eligibleTemporalSpecs: enabled) == [.init(kind: .tipTapRight)])
        #expect(r.process(held, at: 0.43, eligibleTemporalSpecs: enabled).isEmpty)
        #expect(r.advanceTime(to: 0.8) == [.init(kind: secondX < 0.5 ? .tipTapLeft : .tipTapRight)])
    }
}

@Test func movedAnchorRearmsAfterSettlingAtHardwareCadence() {
    var r = GestureRecognizer()
    for frame in 0...60 {
        let time = Double(frame) / 120
        let x = frame < 24 ? 0.2 + Double(frame) / 24 * 0.3 : 0.5 + (frame.isMultiple(of: 2) ? 0.002 : -0.002)
        _ = r.process([.init(id: 1, x: x, y: 0.5)], at: time)
    }
    let held = [Contact(id: 1, x: 0.5, y: 0.5)]
    _ = r.process(held + [.init(id: 2, x: 0.7, y: 0.5)], at: 0.51)
    #expect(r.process(held, at: 0.58) == [.init(kind: .tipTapRight)])
}
