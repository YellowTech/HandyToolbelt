import XCTest
@testable import HandyToolbeltCore

final class TypingAndDebugTests: XCTestCase {
    func testTypingCooldownExpiresAndAutorepeatExtendsIt() {
        var policy = TypingSuppression()
        policy.keyDown(at: 10, synthetic: true)
        policy.keyDown(at: 10, modifier: true)
        XCTAssertFalse(policy.coolingDown(at: 10))
        policy.keyDown(at: 10)
        XCTAssertTrue(policy.coolingDown(at: 10.49))
        policy.keyDown(at: 10.4) // autorepeat extends the deadline
        XCTAssertTrue(policy.coolingDown(at: 10.8))
        policy.keyDown(at: 10.1)
        policy.keyDown(at: .infinity)
        XCTAssertEqual(policy.deadline, 10.9)
        XCTAssertFalse(policy.coolingDown(at: 10.9))
    }

    func testTypingCancelsPendingAndActiveTipsWithSameRestingFinger() {
        var recognizer = GestureRecognizer()
        let anchor = Contact(id: 3, x: 0.4, y: 0.5)
        let tapper = Contact(id: 4, x: 0.6, y: 0.5)
        let double = GestureSpec(kind: .doubleTipTapRight, fingers: 2)
        _ = recognizer.process([anchor], at: 9.0)
        _ = recognizer.process([anchor], at: 9.18)
        _ = recognizer.process([anchor, tapper], at: 9.19, eligibleTemporalSpecs: [double])
        XCTAssertTrue(recognizer.process([anchor], at: 9.23, eligibleTemporalSpecs: [double]).isEmpty)
        XCTAssertNotNil(recognizer.nextDeadline)
        _ = recognizer.process([anchor, tapper], at: 9.25, eligibleTemporalSpecs: [double])
        recognizer.suppressRecognitionForTyping()
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(recognizer.feedback.phase, .idle)
        XCTAssertEqual(recognizer.contacts, [anchor, tapper])
        XCTAssertTrue(recognizer.process([anchor, tapper], at: 9.5, typingSuppressed: true).isEmpty)
        XCTAssertTrue(recognizer.process([anchor], at: 9.77).isEmpty)
        XCTAssertTrue(recognizer.process([anchor, tapper], at: 9.78).isEmpty)
        XCTAssertEqual(recognizer.process([anchor], at: 9.83), [.init(kind: .tipTapRight, fingers: 2)])
    }
    func testRingCapacityTimeAndPayloadBounds() throws {
        var buffer = DebugEventBuffer(capacity: 3)
        for time in 0..<5 { buffer.append(category: .keyboard, event: "physical_key_down", fields: [:], at: Double(time)) }
        XCTAssertEqual(buffer.events.map(\.time), [2, 3, 4])
        buffer.append(category: .keyboard, event: "stale", fields: [:], at: 1)
        XCTAssertEqual(buffer.events.map(\.time), [2, 3, 4])
        XCTAssertEqual(buffer.snapshot(at: 18.5).map(\.time), [4])
        XCTAssertTrue(buffer.snapshot(at: 20).isEmpty)
        buffer.append(category: .recognition, event: String(repeating: "x", count: 100), fields: ["state": String(repeating: "y", count: 1000)], at: 21)
        XCTAssertEqual(buffer.events[0].event.count, 64)
        XCTAssertEqual(buffer.events[0].fields["state"]?.count, 256)
        let data = try JSONEncoder().encode(buffer.events)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(object[0].keys), ["time", "category", "event", "fields"])
    }
}
