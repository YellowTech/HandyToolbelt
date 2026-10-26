import XCTest
@testable import SuperTrackpadCore

final class NativePressArbiterTests: XCTestCase {
    func testForceIsLatchedWithoutStageOne() {
        var policy = NativePressArbiter<String>()
        policy.begin("first", at: 1)
        XCTAssertEqual(policy.stage(2, at: 1.01), "first")
        XCTAssertNil(policy.stage(1, at: 1.02))
        XCTAssertNil(policy.stage(2, at: 1.03))
        policy.release(at: 1.04)
        XCTAssertTrue(policy.finish(at: 1.1).isEmpty)
    }
    func testReleaseOrderingAndRapidPresses() {
        var policy = NativePressArbiter<String>()
        policy.begin("first", at: 1); policy.release(at: 1.01)
        XCTAssertTrue(policy.finish(at: 1.02).isEmpty)
        policy.begin("second", at: 1.02)
        XCTAssertEqual(policy.stage(2, at: 1.005), "first", "Late stage belongs to the released first press")
        XCTAssertEqual(policy.stage(2, at: 1.025), "second")
        policy.release(at: 1.03)
        XCTAssertTrue(policy.finish(at: 1.1).isEmpty)
        policy.begin("third", at: 2); policy.release(at: 2.01)
        policy.begin("fourth", at: 2.02); policy.release(at: 2.03)
        XCTAssertEqual(policy.finish(at: 2.1), ["third", "fourth"])
    }
    func testCancelAndInvalidStageNeverEmitFallback() {
        var policy = NativePressArbiter<Int>()
        policy.begin(1, at: 1)
        XCTAssertNil(policy.stage(2, at: 0.99))
        XCTAssertNil(policy.stage(2, at: .nan))
        policy.cancel(); policy.release(at: 1.1)
        XCTAssertTrue(policy.finish(at: 2).isEmpty)
        policy.begin(2, at: 2); policy.invalidate { $0 == 2 }
        XCTAssertNil(policy.stage(2, at: 2.01))
    }
    func testSnapshotMembershipAllowsLiftButNeverTransfer() {
        let points = [Contact(id: 1, x: 0.05, y: 0.95), Contact(id: 2, x: 0.5, y: 0.5)]
        func snapshot() -> NativePressContacts { NativePressContacts(deviceID: 1, contacts: points, corner: .topLeft, cornerFinger: 1, cornerSize: 0.22, time: 1) }
        var value = snapshot()
        XCTAssertTrue(value.accepts(deviceID: 1, contacts: [points[0]], at: 1.01))
        XCTAssertTrue(value.accepts(deviceID: 1, contacts: [], at: 1.02))
        XCTAssertFalse(value.accepts(deviceID: 1, contacts: points, at: 1.03), "Lifted IDs cannot rejoin")
        value = snapshot()
        XCTAssertFalse(value.accepts(deviceID: 1, contacts: [points[1]], at: 1.01), "A corner hold cannot end while free fingers remain")
        value = snapshot()
        XCTAssertFalse(value.accepts(deviceID: 2, contacts: [points[0]], at: 1.01))
        value = snapshot()
        XCTAssertFalse(value.accepts(deviceID: 1, contacts: [.init(id: 1, x: 0.5, y: 0.5)], at: 1.01))
        value = snapshot()
        XCTAssertFalse(value.accepts(deviceID: 1, contacts: [.init(id: 1, x: 0.12, y: 0.95), points[1]], at: 1.01), "Corner movement inside the boundary still cancels")
        value = snapshot()
        XCTAssertFalse(value.accepts(deviceID: 1, contacts: points, at: 1.2))
    }
    func testForceFingerLimitsAndNativePressCancelsTap() {
        XCTAssertEqual(GestureSpec(kind: .forceClick).allowedFingerCounts(), [1, 2, 3, 4, 5])
        XCTAssertEqual(GestureSpec(kind: .forceClick, corner: .topLeft).allowedFingerCounts(), [1, 2, 3, 4])
        XCTAssertEqual(GestureSpec(kind: .forceClick).allowedFingerCounts(isStackChild: true), [1, 2, 3, 4])
        for count in [1, 5] {
            var recognizer = GestureRecognizer()
            let points = (0..<count).map { Contact(id: $0, x: 0.3 + Double($0) * 0.08, y: 0.5) }
            _ = recognizer.process(points, at: 1)
            _ = recognizer.process(points, at: 1.05)
            XCTAssertEqual(recognizer.beginPhysicalPress(at: 1.06, allowSingleFinger: true)?.fingers, count)
            XCTAssertTrue(recognizer.process([], at: 1.1).isEmpty)
        }
    }
    func testUnsupportedDeviceConfiguration() {
        var configuration = AppConfiguration()
        configuration.bindings = [GestureBinding(device: .magicMouse, gesture: .init(kind: .forceClick, fingers: 1), action: .init(kind: .showText, text: "Force"))]
        XCTAssertTrue(configuration.validation().errors.contains { $0.contains("Force Touch") })
        configuration.bindings = []
        configuration.stacks = [GestureStack(name: "Mouse", device: .magicMouse, corner: .topLeft, isEnabled: true, bindings: [
            GestureStackBinding(gesture: .init(kind: .forceClick, fingers: 1), actions: [.init(kind: .showText, text: "Draft")], isEnabled: false)])]
        XCTAssertTrue(configuration.validation().errors.isEmpty)
        XCTAssertTrue(configuration.validation().warnings.contains { $0.contains("Force Touch") })
    }
}
