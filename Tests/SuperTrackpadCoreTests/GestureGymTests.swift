import Foundation
import Testing
@testable import SuperTrackpadCore

private func calibrated(angle: Double = 25) -> TipTapCalibration {
    var trainer = TipTapCalibration()
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    _ = trainer.process([anchor], at: 0, aspectRatio: 1.6)
    for index in 0..<6 {
        let sign = index < 3 ? -1.0 : 1.0
        let radians = angle * .pi / 180
        let tapper = Contact(id: index + 2, x: 0.5 + sign * 0.18 * cos(radians), y: 0.5 + sign * 0.18 * sin(radians) * 1.6)
        let time = 0.2 + Double(index) * 0.28
        _ = trainer.process([anchor, tapper], at: time, aspectRatio: 1.6)
        _ = trainer.process([anchor], at: time + 0.09, aspectRatio: 1.6)
    }
    return trainer
}

@Test func tiltedAxisAllowsCloseHorizontalTipTaps() {
    let anchor = Contact(id: 1, x: 0.5, y: 0.4)
    let tap = Contact(id: 2, x: 0.52, y: 0.6)
    var flat = GestureRecognizer()
    _ = flat.process([anchor], at: 0)
    _ = flat.process([anchor, tap], at: 0.2)
    #expect(flat.process([anchor], at: 0.3).isEmpty)
    #expect(flat.feedback.phase == .rejected)
    #expect(flat.feedback.message.contains("too close"))
    var tilted = GestureRecognizer()
    tilted.tuning.handAngleDegrees = 30
    _ = tilted.process([anchor], at: 0)
    _ = tilted.process([anchor, tap], at: 0.2)
    #expect(tilted.process([anchor], at: 0.3) == [.init(kind: .tipTapRight)])
    #expect(tilted.feedback.gesture?.kind == .tipTapRight)
}

@Test func projectedAxisUsesPhysicalAspectAndCorrectSign() {
    var tuning = GestureTuning()
    tuning.handAngleDegrees = 30
    let radians = Double.pi / 6
    let anchor = TouchPoint(x: 0.5, y: 0.5)
    let right = TouchPoint(x: 0.5 + 0.2 * cos(radians), y: 0.5 + 0.2 * sin(radians) * 1.6)
    let left = TouchPoint(x: 0.5 - 0.2 * cos(radians), y: 0.5 - 0.2 * sin(radians) * 1.6)
    #expect(abs(tuning.projectedSeparation(from: anchor, to: right, aspectRatio: 1.6) - 0.2) < 0.0001)
    #expect(abs(tuning.projectedSeparation(from: anchor, to: left, aspectRatio: 1.6) + 0.2) < 0.0001)
}

@Test func gymCalibrationLearnsBothHandTilts() throws {
    for angle in [-35.0, 25.0] {
        let trainer = calibrated(angle: angle)
        #expect(trainer.leftCount == 3)
        #expect(trainer.rightCount == 3)
        #expect(trainer.isComplete)
        let settings = try #require(trainer.suggestion(from: GestureTuning()))
        #expect(abs(settings.handAngleDegrees - angle) < 1)
        #expect(settings.tapDuration >= 0.15)
        #expect(settings.tipSeparation > 0.02)
        #expect(settings.cornerHold == GestureTuning().cornerHold)
        #expect(settings.swipeTravel == GestureTuning().swipeTravel)
    }
}

@Test func learnedTuningRecognizesTrainingStyle() throws {
    let trainer = calibrated(angle: 30)
    var recognizer = GestureRecognizer()
    recognizer.tuning = try #require(trainer.suggestion(from: GestureTuning()))
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    _ = recognizer.process([anchor], at: 0)
    let tapper = Contact(id: 2, x: 0.5 - 0.18 * cos(.pi / 6), y: 0.5 - 0.18 * sin(.pi / 6) * 1.6)
    _ = recognizer.process([anchor, tapper], at: 0.2)
    #expect(recognizer.process([anchor], at: 0.29) == [.init(kind: .tipTapLeft)])
}

@Test func calibrationRejectsWrongSideAndAnchorLift() {
    var trainer = TipTapCalibration()
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    _ = trainer.process([anchor], at: 0, aspectRatio: 1.6)
    _ = trainer.process([anchor, .init(id: 2, x: 0.7, y: 0.5)], at: 0.2, aspectRatio: 1.6)
    let wrong = trainer.process([anchor], at: 0.3, aspectRatio: 1.6)
    #expect(wrong == .rejected("Tap on the requested side of your resting finger."))
    #expect(trainer.samples.isEmpty)
    _ = trainer.process([anchor, .init(id: 3, x: 0.3, y: 0.5)], at: 0.4, aspectRatio: 1.6)
    let lifted = trainer.process([], at: 0.5, aspectRatio: 1.6)
    #expect(lifted == .rejected("Keep the resting finger down when the tapping finger lifts."))
    #expect(trainer.suggestion(from: GestureTuning()) == nil)
}

@Test func calibrationRejectsPhysicalClickAndAdditionalFingers() {
    var trainer = TipTapCalibration()
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    let tapper = Contact(id: 2, x: 0.3, y: 0.5)
    _ = trainer.process([anchor], at: 0, aspectRatio: 1.6)
    let click = trainer.process([anchor, tapper], at: 0.2, aspectRatio: 1.6, physicalButtonDown: true)
    #expect(click == .rejected("That was a click. Tap lightly without pressing."))
    _ = trainer.process([anchor], at: 0.3, aspectRatio: 1.6)
    _ = trainer.process([anchor, tapper], at: 0.4, aspectRatio: 1.6)
    let extra = trainer.process([anchor, tapper, .init(id: 3, x: 0.8, y: 0.5)], at: 0.5, aspectRatio: 1.6)
    #expect(extra == .rejected("Use just the resting finger and one tapping finger."))
    #expect(trainer.samples.isEmpty)
}

@Test func inconsistentTrainingDoesNotSuggestAnAxis() {
    var trainer = TipTapCalibration()
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    _ = trainer.process([anchor], at: 0, aspectRatio: 1.6)
    for index in 0..<6 {
        let sign = index < 3 ? -1.0 : 1.0
        let angle = (index < 3 ? 40.0 : -40.0) * .pi / 180
        let tap = Contact(id: index + 2, x: 0.5 + sign * 0.15 * cos(angle), y: 0.5 + sign * 0.15 * sin(angle) * 1.6)
        let time = 0.2 + Double(index) * 0.3
        _ = trainer.process([anchor, tap], at: time, aspectRatio: 1.6)
        _ = trainer.process([anchor], at: time + 0.1, aspectRatio: 1.6)
    }
    #expect(trainer.isComplete)
    #expect(trainer.suggestion(from: GestureTuning()) == nil)
}

@Test func oldSettingsLoadWithDefaultTuning() throws {
    let original = AppConfiguration()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "trackpadTuning")
    object.removeValue(forKey: "mouseTuning")
    let data = try JSONSerialization.data(withJSONObject: object)
    let loaded = try JSONDecoder().decode(AppConfiguration.self, from: data)
    #expect(loaded.bindings == original.bindings)
    #expect(loaded.trackpadTuning == GestureTuning())
    #expect(!loaded.trackpadModuleEnabled)
}

@Test func tunedSettingsRoundTripAndStaySeparatePerDevice() throws {
    var config = AppConfiguration()
    var tuning = GestureTuning(); tuning.handAngleDegrees = 24; tuning.anchorHold = 0.12
    config.setTuning(tuning, for: .trackpad)
    let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.tuning(for: .trackpad) == tuning)
    #expect(restored.tuning(for: .magicMouse) == GestureTuning())
}

@Test func invalidTuningIsBounded() {
    var tuning = GestureTuning()
    tuning.tapDuration = -100; tuning.handAngleDegrees = .nan; tuning.tipSeparation = 10
    let safe = tuning.validated
    #expect(safe.tapDuration == 0.1)
    #expect(safe.handAngleDegrees == 0)
    #expect(safe.tipSeparation == 0.2)
    #expect(GestureTuning.safeAspect(.infinity) == 1.6)
}

@Test func feedbackExplainsLongTipAndRetainsMeasurements() {
    var r = GestureRecognizer()
    let anchor = Contact(id: 1, x: 0.5, y: 0.5)
    let tapper = Contact(id: 2, x: 0.7, y: 0.5)
    _ = r.process([anchor], at: 0)
    _ = r.process([anchor], at: 0.17)
    #expect(r.feedback.phase == .holding)
    _ = r.process([anchor, tapper], at: 0.2)
    #expect(r.feedback.phase == .candidate)
    _ = r.process([anchor, tapper], at: 0.6)
    #expect(r.feedback.phase == .candidate)
    #expect(r.feedback.message.contains("too long"))
    #expect(abs(r.feedback.tapTime - 0.4) < 0.0001)
    #expect(r.feedbackSequence == 0)
    #expect(r.process([anchor], at: 0.61).isEmpty)
    #expect(r.feedback.phase == .rejected)
    #expect(r.feedbackSequence == 1)
}

@Test func configurableCornerSizeChangesAcquisition() {
    var r = GestureRecognizer()
    r.tuning.cornerSize = 0.30
    let point = Contact(id: 1, x: 0.27, y: 0.73)
    _ = r.process([point], at: 0, enabledCorners: [.topLeft])
    _ = r.process([point], at: 0.3, enabledCorners: [.topLeft])
    #expect(r.modifier == .topLeft)
}
