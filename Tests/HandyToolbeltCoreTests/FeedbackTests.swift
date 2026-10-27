import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func pressureSizeSeparatesHighLevelsAndBoundsBadSamples() {
    // Equal steps in the bounded device signal grow progressively more in size.
    let levels = [0.0, 0.25, 0.5, 0.75, 0.95]
    let sizes = levels.map { level in
        Contact(id: 1, x: 0.5, y: 0.5, pressure: level / (1 - level)).pressureSize
    }
    #expect(sizes[3] - sizes[2] > sizes[2] - sizes[1])
    #expect(sizes[2] - sizes[1] > sizes[1] - sizes[0])
    for pressure: Double? in [nil, .nan, .infinity, -.infinity, -1, 0, Double.greatestFiniteMagnitude] {
        let size = Contact(id: 1, x: 0, y: 0, pressure: pressure).pressureSize
        #expect(size.isFinite && (0...1).contains(size))
    }
}

@Test func pressFeedbackPulsesOnUpwardTransitionsAndExpiresAfterRelease() {
    var feedback = PressFeedback()
    feedback.update(stage: 1, at: 1)
    #expect(feedback.display(at: 1).kind == .click)
    #expect(feedback.display(at: 1).pulseProgress == 0)
    feedback.update(stage: 1, at: 1.1)
    #expect(feedback.display(at: 1.1).pulseProgress > 0) // repeated pressure frames never retrigger
    feedback.update(stage: 2, at: 1.2)
    #expect(feedback.display(at: 1.2).kind == .forceClick)
    #expect(feedback.display(at: 1.2).pulseProgress == 0)
    feedback.update(stage: 1, at: 1.3)
    #expect(feedback.display(at: 1.3).pulseProgress > 0) // no click pulse while releasing force
    feedback.update(stage: 0, at: 1.4)
    #expect(feedback.display(at: 1.4).kind == .forceClick)
    #expect(!feedback.display(at: 1.4).isHeld)
    #expect(feedback.display(at: 1.9).kind == .touch)
    #expect(!feedback.display(at: 1.9).needsAnimation)
    feedback.update(stage: 1, at: 2)
    #expect(feedback.display(at: 2).pulseProgress == 0)
}

@Test func invalidStagesNeverInventAForceClick() {
    var feedback = PressFeedback()
    feedback.update(stage: 9, at: 0)
    feedback.update(stage: 2, at: .nan)
    feedback.update(stage: -1, at: 0)
    #expect(feedback.stage == .touch)
    #expect(!feedback.display(at: 0).needsAnimation)
    feedback.update(stage: 1, at: 1)
    #expect(feedback.display(at: 50).kind == .click)
    #expect(!feedback.display(at: 50).needsAnimation) // held press doesn't need a permanent pulse animation
}

@Test func hapticPreferencesMigrateWithoutChangingActionsAndRoundTrip() throws {
    var config = AppConfiguration()
    config.trackpadModuleEnabled = false
    let before = config.bindings
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    old.removeValue(forKey: "hapticPattern")
    old.removeValue(forKey: "hapticsInPractice")
    config = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(config.bindings == before && !config.trackpadModuleEnabled)
    #expect(config.hapticPattern == .light && config.hapticsInPractice)
    #expect(config.bindings.allSatisfy { $0.hapticPattern == nil })
    config.hapticPattern = .doubleClick
    config.hapticsInPractice = false
    config.bindings[0].hapticPattern = .off
    config.bindings[1].hapticPattern = .strongDouble
    let copy = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(copy.hapticPattern == .doubleClick && !copy.hapticsInPractice)
    #expect(copy.bindings == config.bindings)
}

@Test func hapticPatternsAreShortAndBounded() {
    #expect(HapticPattern.off.pulses.isEmpty)
    for pattern in HapticPattern.allCases where pattern != .off {
        #expect(pattern.pulses.count <= 2)
        #expect(pattern.pulses.first?.delay == 0)
        #expect(pattern.pulses.allSatisfy { $0.delay >= 0 && $0.delay <= 0.15 })
    }
    #expect(HapticPattern.doubleClick.pulses.count == 2)
    #expect(HapticPattern.strongDouble.pulses.count == 2)
}
