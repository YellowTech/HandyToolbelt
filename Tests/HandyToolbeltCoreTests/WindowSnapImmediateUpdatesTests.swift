import XCTest
@testable import HandyToolbeltCore

final class WindowSnapImmediateUpdatesTests: XCTestCase {
    private final class Lease {
        var mode: Bool? = true
        var eligible = true
        var assistiveEnabled = false
        var events: [String] = []
        var disableAccepted = true
        var disableChangesMode = true
        var restoreFailures = 0
        var restoreFailureReportsSuccess = false
        var afterDisable: (() -> Void)?
        var diagnostics: [String] = []
        func run(_ body: () -> Void) -> Bool {
            WindowSnapImmediateUpdates.perform(assistiveTechnologyEnabled: assistiveEnabled,
                isEligible: { self.eligible }, readMode: {
                    self.events.append("read")
                    return self.mode
                }, writeMode: { value in
                    self.events.append(value ? "restore" : "disable")
                    if value {
                        if self.restoreFailures > 0 { self.restoreFailures -= 1; return self.restoreFailureReportsSuccess }
                        self.mode = true
                        return true
                    }
                    if self.disableChangesMode { self.mode = false }
                    self.afterDisable?()
                    return self.disableAccepted
                }, diagnostic: { self.diagnostics.append($0) }, body: body)
        }
    }
    func testAlreadyFalseDoesNotChangeMode() {
        let lease = Lease(); lease.mode = false
        XCTAssertTrue(lease.run { lease.events.append("body") })
        XCTAssertEqual(lease.events, ["read", "body"])
        XCTAssertEqual(lease.mode, false)
    }
    func testTrueModeIsDisabledConfirmedThenRestoredAndVerified() {
        let lease = Lease()
        XCTAssertTrue(lease.run { lease.events.append("body") })
        XCTAssertEqual(lease.events, ["read", "disable", "read", "body", "restore", "read"])
        XCTAssertEqual(lease.mode, true)
        XCTAssertEqual(lease.diagnostics.last, "enhanced_ui_restore_verified")
    }
    func testUnknownAndBuiltInAssistiveTechnologyNeverMutateMode() {
        let unknown = Lease(); unknown.mode = nil
        XCTAssertFalse(unknown.run { XCTFail("Unknown mode must stay paced") })
        XCTAssertEqual(unknown.events, ["read"])
        let assistive = Lease(); assistive.assistiveEnabled = true
        XCTAssertFalse(assistive.run { XCTFail("Assistive session must stay paced") })
        XCTAssertTrue(assistive.events.isEmpty)
    }
    func testRejectedOrUnconfirmedDisableStillRestoresOriginalTrue() {
        for rejected in [false, true] {
            let lease = Lease()
            lease.disableAccepted = !rejected
            lease.disableChangesMode = rejected // Rejection can still have side effects.
            XCTAssertFalse(lease.run { XCTFail("Unconfirmed mode must stay paced") })
            XCTAssertEqual(lease.mode, true)
            XCTAssertTrue(lease.events.contains("restore"))
            XCTAssertEqual(lease.events.suffix(2), ["restore", "read"])
        }
    }
    func testUnreadableDisableReadbackStillRestoresOriginalTrue() {
        let lease = Lease()
        lease.afterDisable = { lease.mode = nil }
        XCTAssertFalse(lease.run { XCTFail("Unknown readback must stay paced") })
        XCTAssertEqual(lease.mode, true)
        XCTAssertEqual(lease.events.suffix(2), ["restore", "read"])
    }
    func testCancellationDuringDisableAndBodyCannotPreventCleanup() {
        for duringBody in [false, true] {
            let lease = Lease()
            if !duringBody { lease.afterDisable = { lease.eligible = false } }
            let ran = lease.run { lease.events.append("body"); lease.eligible = false }
            XCTAssertEqual(ran, duringBody)
            XCTAssertEqual(lease.mode, true)
            XCTAssertEqual(lease.events.suffix(2), ["restore", "read"])
        }
    }
    func testRestorationReadbackIsVerifiedWithOnlyOneBoundedRetry() {
        let recovered = Lease(); recovered.restoreFailures = 1; recovered.restoreFailureReportsSuccess = true
        XCTAssertTrue(recovered.run {})
        XCTAssertEqual(recovered.events.filter { $0 == "restore" }.count, 2)
        XCTAssertEqual(recovered.mode, true)
        XCTAssertEqual(recovered.diagnostics.last, "enhanced_ui_restore_verified")
        let denied = Lease(); denied.restoreFailures = 100
        XCTAssertTrue(denied.run {})
        XCTAssertEqual(denied.events.filter { $0 == "restore" }.count, 2)
        XCTAssertEqual(denied.diagnostics.last, "enhanced_ui_restore_failed")
    }

    private final class Window: WindowSnapWindowAccess {
        let processID: Int32 = 42
        var frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        var mode: Bool? = true
        var eligible = true
        var writes: [String] = []
        var modeWrites: [Bool] = []
        var leases = 0
        var onEffect: ((String) -> Void)?
        var maximumWidth: CGFloat?
        var rejectSizeOnce = false
        var failReadAfterWriteOnce = false
        var clampPosition = false
        func isEligibleAndActive() -> Bool { eligible }
        func readFrame() -> CGRect? {
            onEffect?("read")
            if failReadAfterWriteOnce, !writes.isEmpty { failReadAfterWriteOnce = false; return nil }
            return frame
        }
        func setPosition(_ point: CGPoint) -> Bool {
            writes.append("position")
            frame.origin = point
            if clampPosition {
                frame.origin.x = min(point.x, 1200 - frame.width)
                frame.origin.y = min(point.y, 800 - frame.height)
            }
            onEffect?("position")
            return true
        }
        func setSize(_ size: CGSize) -> Bool {
            writes.append("size")
            if rejectSizeOnce { rejectSizeOnce = false; return false }
            frame.size = size
            if let maximumWidth { frame.size.width = min(frame.width, maximumWidth) }
            onEffect?("size")
            return true
        }
        func withImmediateUpdates(isCurrent: () -> Bool, _ body: () -> Void) -> Bool {
            leases += 1
            return WindowSnapImmediateUpdates.perform(assistiveTechnologyEnabled: false,
                isEligible: { isCurrent() && self.eligible }, readMode: { self.mode }, writeMode: { value in
                    self.modeWrites.append(value)
                    self.mode = value
                    self.onEffect?(value ? "restore" : "disable")
                    return true
                }, body: body)
        }
    }
    private let target = CGRect(x: 0, y: 25, width: 1200, height: 725)
    func testFastBatchChangesFrameImmediatelyButWaitsThreeScheduledReadbacks() {
        let window = Window()
        var application = WindowSnapApplication(target: target)
        var stages: [String] = []
        for observation in 0..<4 {
            let result = application.advance(window: window, diagnostic: { stage, _ in stages.append(stage) }, isCurrent: { true })
            if observation < 3 { if case .pending = result {} else { XCTFail() } }
            else { if case .succeeded = result {} else { XCTFail() } }
            XCTAssertEqual(window.frame, target)
            XCTAssertEqual(window.mode, true)
        }
        XCTAssertEqual(window.writes, ["position", "size"])
        XCTAssertEqual(window.modeWrites, [false, true])
        XCTAssertEqual(window.leases, 1)
        XCTAssertEqual(application.attempts, 1)
        XCTAssertTrue(stages.contains("fast_verified"))
    }
    func testLeaseModeChangeCannotMakeFastBatchUseStaleGeometry() {
        let window = Window()
        window.frame.size = target.size
        window.onEffect = { effect in
            if effect == "disable" { window.frame.size = CGSize(width: 600, height: 400) }
        }
        var application = WindowSnapApplication(target: target)
        if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
        XCTAssertEqual(window.frame, target)
        XCTAssertEqual(window.writes, ["position", "size"])
        XCTAssertEqual(application.attempts, 1)
    }
    func testAlreadySatisfiedComponentsAreSkippedWithinFreshFastFrame() {
        for positionCorrect in [false, true] {
            let window = Window(); window.mode = false
            if positionCorrect { window.frame.origin = target.origin }
            else { window.frame.size = target.size }
            var application = WindowSnapApplication(target: target)
            if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
            XCTAssertEqual(window.frame, target)
            XCTAssertEqual(window.writes, positionCorrect ? ["size"] : ["position"])
            XCTAssertTrue(window.modeWrites.isEmpty)
        }
    }
    func testCancellationAtEachFastEffectRestoresModeAndStopsLaterGeometry() {
        for eligibilityLoss in [false, true] {
            for effect in ["disable", "position", "size", "correction", "read"] {
                let window = Window()
                if effect == "correction" { window.frame = CGRect(x: 0, y: 0, width: 1200, height: 800); window.clampPosition = true }
                var current = true
                let invalidate = { if eligibilityLoss { window.eligible = false } else { current = false } }
                window.onEffect = { operation in
                    if effect == "correction" {
                        if operation == "position", window.writes.count == 3 { invalidate() }
                    } else if operation == effect, operation != "read" || !window.writes.isEmpty { invalidate() }
                }
                var application = WindowSnapApplication(target: effect == "correction" ? CGRect(x: 600, y: 400, width: 600, height: 400) : target)
                if case .failed = application.advance(window: window, isCurrent: { current }) {} else { XCTFail() }
                XCTAssertEqual(window.mode, true)
                XCTAssertEqual(window.modeWrites, [false, true])
                let writes = window.writes
                if case .failed = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
                XCTAssertEqual(window.writes, writes)
                XCTAssertEqual(writes.count, effect == "disable" ? 0 : effect == "size" ? 2 : effect == "correction" ? 3 : 1)
            }
        }
    }
    func testFastSetterErrorCleansUpThenPacedFallbackCanSucceed() {
        for readFailure in [false, true] {
            let window = Window()
            window.rejectSizeOnce = !readFailure
            window.failReadAfterWriteOnce = readFailure
            var application = WindowSnapApplication(target: target)
            var succeeded = false
            var stages: [String] = []
            for _ in 0..<50 {
                let result = application.advance(window: window, diagnostic: { stage, _ in stages.append(stage) }, isCurrent: { true })
                if case .succeeded = result { succeeded = true; break }
            }
            XCTAssertTrue(succeeded)
            XCTAssertEqual(window.mode, true)
            XCTAssertEqual(window.leases, 1)
            XCTAssertTrue(stages.contains("fast_batch_failed"))
            XCTAssertTrue(stages.contains("fast_fallback"))
            XCTAssertEqual(application.attempts, 2)
        }
    }
    func testPersistentConstraintRetainsPartialAfterOneFastAndThreePacedPasses() {
        let window = Window(); window.maximumWidth = 1000
        var application = WindowSnapApplication(target: target)
        var limited = false
        for _ in 0..<50 {
            let result = application.advance(window: window, isCurrent: { true })
            if case .limited = result { limited = true; break }
            if case .failed = result { break }
        }
        XCTAssertTrue(limited)
        XCTAssertEqual(window.leases, 1)
        XCTAssertEqual(application.attempts, 4)
        XCTAssertEqual(window.frame.width, 1000)
        XCTAssertEqual(window.mode, true)
    }
}
