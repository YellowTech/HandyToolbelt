import XCTest
@testable import HandyToolbeltCore

final class TypingAndDebugTests: XCTestCase {
    func testTypingCooldownAndLiftBarrier() {
        var policy = TypingSuppression()
        policy.keyDown(at: 10, synthetic: true)
        policy.keyDown(at: 10, modifier: true)
        XCTAssertFalse(policy.coolingDown(at: 10))
        policy.keyDown(at: 10)
        XCTAssertTrue(policy.coolingDown(at: 10.49))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: true, at: 10.1))
        policy.keyDown(at: 10.4) // autorepeat extends the deadline
        XCTAssertTrue(policy.coolingDown(at: 10.8))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: true, at: 11))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: false, at: 11.1))
        XCTAssertFalse(policy.suppresses(deviceID: 1, hasContacts: true, at: 11.2))
        XCTAssertFalse(policy.suppresses(deviceID: 2, hasContacts: true, at: 11.2))
    }
    func testInvalidAndStaleLiftsPreserveTypingBarrier() {
        var policy = TypingSuppression()
        policy.keyDown(at: 10)
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: true, at: 10.2))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: false, at: 10.1))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: false, at: .nan))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: false, at: .infinity))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: true, at: 10.6))
        XCTAssertTrue(policy.suppresses(deviceID: 1, hasContacts: false, at: 10.7))
        XCTAssertFalse(policy.suppresses(deviceID: 1, hasContacts: true, at: 10.8))
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
