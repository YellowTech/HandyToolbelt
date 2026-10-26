import XCTest
import CoreGraphics
@testable import SuperTrackpadCore

final class VisualFeedbackTests: XCTestCase {
    func testOldActionAndConfigurationDefaults() throws {
        let old = Data(#"{"kind":"system","system":"nextTab","script":""}"#.utf8)
        let action = try JSONDecoder().decode(GestureAction.self, from: old)
        XCTAssertEqual(action.text, "")
        XCTAssertEqual(action.textDuration, 0.5)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfiguration())) as? [String: Any])
        object.removeValue(forKey: "visualFeedbackEnabled")
        let config = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(config.visualFeedbackEnabled)
        object["version"] = 7
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try JSONDecoder().decode(GestureAction.self, from: Data(#"{"kind":"system","script":""}"#.utf8)))
    }
    func testTextValidationBoundsAndRoundTrip() throws {
        var action = GestureAction(kind: .showText, text: " \n ")
        XCTAssertFalse(action.isValid)
        action.text = "  Hello\nworld  "
        XCTAssertEqual(action.displayText, "Hello\nworld")
        action.textDuration = -2
        XCTAssertEqual(action.displayDuration, 0.2)
        action.textDuration = 90
        XCTAssertEqual(action.displayDuration, 5)
        action.textDuration = .nan
        XCTAssertEqual(action.displayDuration, 0.5)
        action.textDuration = 1
        XCTAssertEqual(try JSONDecoder().decode(GestureAction.self, from: JSONEncoder().encode(action)), action)
        action.text = String(repeating: "x", count: 500)
        XCTAssertEqual(action.displayText.count, 280)
        var configuration = AppConfiguration()
        configuration.visualFeedbackEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration)).visualFeedbackEnabled)
    }
    func testStaleExpirationAndCancel() {
        var lifetime = FeedbackLifetime()
        let old = lifetime.replace()
        let replacement = lifetime.replace()
        XCTAssertFalse(lifetime.expire(old))
        XCTAssertEqual(lifetime.current, replacement)
        lifetime.cancel()
        XCTAssertFalse(lifetime.expire(replacement))
        let latest = lifetime.replace()
        XCTAssertTrue(lifetime.expire(latest))
        XCTAssertNil(lifetime.current)
    }
    func testGeometryOnNegativeOriginAndSmallDisplay() {
        let display = CGRect(x: -1600, y: -300, width: 1400, height: 900)
        let center = FeedbackGeometry.frame(size: CGSize(width: 520, height: 150), visibleFrame: display, top: false)
        XCTAssertEqual(center.midX, display.midX)
        XCTAssertEqual(center.midY, display.midY)
        let top = FeedbackGeometry.frame(size: CGSize(width: 2000, height: 2000), visibleFrame: display, top: true)
        XCTAssertTrue(display.contains(top))
        XCTAssertEqual(top.maxY, display.maxY - 16)
    }
    func testFeedbackCentersOnScreenWithSideDockAndOffOriginDisplay() {
        let screen = CGRect(x: -1920, y: 150, width: 1920, height: 1080)
        let visible = CGRect(x: -1820, y: 180, width: 1820, height: 1026)
        let top = FeedbackGeometry.frame(size: CGSize(width: 440, height: 230), visibleFrame: visible, top: true, screenFrame: screen)
        XCTAssertEqual(top.midX, screen.midX)
        XCTAssertEqual(top.maxY, visible.maxY - 16)
        XCTAssertTrue(visible.contains(top))
        let center = FeedbackGeometry.frame(size: CGSize(width: 520, height: 150), visibleFrame: visible, top: false, screenFrame: screen)
        XCTAssertEqual(center.midX, screen.midX)
        XCTAssertEqual(center.midY, screen.midY)
    }
    func testScreenCenterClampsInsideNarrowVisibleArea() {
        let screen = CGRect(x: 200, y: -1200, width: 1440, height: 900)
        let visible = CGRect(x: 900, y: -1180, width: 740, height: 850)
        let frame = FeedbackGeometry.frame(size: CGSize(width: 440, height: 150), visibleFrame: visible, top: true, screenFrame: screen)
        XCTAssertEqual(frame.minX, visible.minX + 16)
        XCTAssertTrue(visible.insetBy(dx: 16, dy: 16).contains(frame))
    }
    func testOversizedFeedbackFitsTinyOffsetScreen() {
        let screen = CGRect(x: 1200, y: -900, width: 320, height: 180)
        let visible = CGRect(x: 1240, y: -900, width: 280, height: 155)
        for top in [true, false] {
            let frame = FeedbackGeometry.frame(size: CGSize(width: 500, height: 400), visibleFrame: visible, top: top, screenFrame: screen)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.width, 248)
            XCTAssertEqual(frame.height, 123)
        }
    }

}
