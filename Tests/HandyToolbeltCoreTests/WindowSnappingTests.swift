import XCTest
@testable import HandyToolbeltCore

final class WindowSnappingTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let visible = CGRect(x: 0, y: 25, width: 1200, height: 725)
    func testWindowServerSelectionRejectsSelfBeforeAXResolution() {
        let own = WindowSnapCandidate(processID: 7, frame: screen)
        let foreign = WindowSnapCandidate(processID: 42, frame: screen)
        var axRequests: [Int32] = []
        if let pid = WindowSnapping.hitProcess(at: CGPoint(x: 50, y: 50), candidates: [own, foreign], ownPID: 7) {
            axRequests.append(pid)
        }
        XCTAssertTrue(axRequests.isEmpty, "Own UI must be excluded before requesting any AX element or attribute")
        XCTAssertEqual(WindowSnapping.hitProcess(at: CGPoint(x: 50, y: 50), candidates: [foreign, own], ownPID: 7), 42)
    }
    func testWindowServerSelectionDoesNotLookThroughUnknownClickThroughOverlays() {
        let foreign = WindowSnapCandidate(processID: 42, frame: screen)
        let overlay = WindowSnapCandidate(processID: 99, frame: screen, layer: 3)
        XCTAssertNil(WindowSnapping.hitProcess(at: CGPoint(x: 50, y: 50), candidates: [overlay, foreign], ownPID: 7))
        let invisible = WindowSnapCandidate(processID: 99, frame: screen, layer: 3, alpha: 0)
        XCTAssertEqual(WindowSnapping.hitProcess(at: CGPoint(x: 50, y: 50), candidates: [invisible, foreign], ownPID: 7), 42)
        XCTAssertNil(WindowSnapping.hitProcess(at: CGPoint(x: -1, y: -1), candidates: [foreign], ownPID: 7))
    }
    func testEventHandlingWindowRoutesPastCursorWithoutSkippingUnknownOverlays() {
        let cursor = WindowSnapCandidate(processID: 99, frame: screen, layer: 2147483630, windowID: 1)
        let browser = WindowSnapCandidate(processID: 42, frame: screen, windowID: 2)
        let chosen = WindowSnapping.selectWindow(at: CGPoint(x: 50, y: 50), candidates: [cursor, browser],
            ownPID: 7, handlingWindowID: 2, eventTargetPID: 42)
        XCTAssertEqual(chosen.candidate?.processID, 42)
        XCTAssertEqual(chosen.method, "event_handling_window")
        XCTAssertNil(chosen.rejection)
        let absent = WindowSnapping.selectWindow(at: CGPoint(x: 50, y: 50), candidates: [cursor, browser], ownPID: 7)
        XCTAssertNil(absent.candidate)
        XCTAssertEqual(absent.rejection, "nonstandard_surface")
        let zero = WindowSnapping.selectWindow(at: CGPoint(x: 50, y: 50), candidates: [browser], ownPID: 7, handlingWindowID: 0)
        XCTAssertEqual(zero.candidate?.processID, 42)
        XCTAssertEqual(zero.method, "first_containing_surface")
    }
    func testEventHandlerCannotResolveOwnUnknownFloatingOrContradictoryWindow() {
        let overlay = WindowSnapCandidate(processID: 99, frame: screen, layer: 3, windowID: 1)
        let own = WindowSnapCandidate(processID: 7, frame: screen, windowID: 2)
        let browser = WindowSnapCandidate(processID: 42, frame: screen, windowID: 3)
        let candidates = [overlay, own, browser]
        let ownSelection = WindowSnapping.selectWindow(at: .zero, candidates: candidates, ownPID: 7, handlingWindowID: 2)
        XCTAssertNil(ownSelection.candidate, "Own PID is never admitted to AX even beneath a foreign overlay")
        XCTAssertEqual(ownSelection.rejection, "own_process")
        let unknown = WindowSnapping.selectWindow(at: .zero, candidates: candidates, ownPID: 7, handlingWindowID: 444)
        XCTAssertNil(unknown.candidate)
        XCTAssertEqual(unknown.rejection, "event_handler_metadata_unavailable")
        let floating = WindowSnapping.selectWindow(at: .zero, candidates: candidates, ownPID: 7, handlingWindowID: 1)
        XCTAssertNil(floating.candidate)
        XCTAssertEqual(floating.rejection, "nonstandard_surface")
        let mismatch = WindowSnapping.selectWindow(at: .zero, candidates: candidates, ownPID: 7, handlingWindowID: 3, eventTargetPID: 99)
        XCTAssertNil(mismatch.candidate)
        XCTAssertEqual(mismatch.rejection, "event_target_pid_mismatch")
    }
    func testDiagnosticHistoryPreservesOnlyEightCompletedDragsAcrossClicks() throws {
        var snapshot = WindowSnapDiagnosticsSnapshot()
        for generation in 1...12 {
            var interaction = WindowSnapDiagnostics()
            interaction.generation = UInt64(generation)
            interaction.mouseDownCount = 1
            interaction.mouseDragCount = 2
            interaction.completed = true
            interaction.stage = "finished"
            snapshot.recordCompletedDrag(interaction)
        }
        var click = WindowSnapDiagnostics()
        click.mouseDownCount = 1; click.completed = true
        snapshot.recordCompletedDrag(click)
        var incomplete = click; incomplete.mouseDragCount = 1; incomplete.completed = false
        snapshot.recordCompletedDrag(incomplete)
        XCTAssertEqual(snapshot.completedDrags.count, 8)
        XCTAssertEqual(snapshot.completedDrags.map(\.generation), Array(UInt64(5)...UInt64(12)))
        XCTAssertEqual(try JSONDecoder().decode(WindowSnapDiagnosticsSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func testSessionRejectsStaleDownUpAndAllowsActivatingClickedApp() {
        var session = WindowSnapSession()
        let first = session.generation
        XCTAssertFalse(session.activated(pid: 42), "An unresolved click may activate its app")
        XCTAssertTrue(session.resolve(pid: 42, token: first))
        XCTAssertFalse(session.activated(pid: 42))
        XCTAssertTrue(session.activated(pid: 99), "Changing established app cancels")
        XCTAssertFalse(session.isCurrent(first), "Stale mouse-up and preview must fail")
        XCTAssertFalse(session.resolve(pid: 42, token: first), "Late AX down cannot resurrect")
        let second = session.generation
        XCTAssertTrue(session.resolve(pid: 99, token: second))
        session.invalidate() // Escape, disable, permission loss, Space/screen change, sleep or new down.
        XCTAssertFalse(session.isCurrent(second))
        XCTAssertNil(session.targetPID)
    }
    private final class FakeWindow: WindowSnapWindowAccess {
        let processID: Int32 = 42
        var eligible = true
        var rect = CGRect(x: 100, y: 100, width: 600, height: 400)
        var writes: [String] = []
        var requestedSizes: [CGSize] = []
        var duringReadback: (() -> Void)?
        var duringEveryRead: (() -> Void)?
        var duringSize: (() -> Void)?
        var clampsSize = false
        var minimumSize: CGSize?
        var bounds: CGRect?
        var positionBounds: CGRect?
        var duringPosition: (() -> Void)?
        var rejectsFirstPosition = false
        var sizeAllowed = true
        var positionAllowed = true
        var requestedPositions: [CGPoint] = []
        func isEligibleAndActive() -> Bool { eligible }
        func readFrame() -> CGRect? {
            duringEveryRead?()
            if !writes.isEmpty { duringReadback?() }
            return eligible ? rect : nil
        }
        func setSize(_ size: CGSize) -> Bool {
            writes.append("size")
            requestedSizes.append(size)
            guard sizeAllowed else { return false }
            rect.size = size
            if let minimumSize {
                rect.size.width = max(rect.width, minimumSize.width)
                rect.size.height = max(rect.height, minimumSize.height)
            }
            if clampsSize { rect.size.width = min(size.width, 1000) }
            if let bounds {
                rect.size.width = min(rect.width, bounds.maxX - rect.minX)
                rect.size.height = min(rect.height, bounds.maxY - rect.minY)
            }
            duringSize?()
            return true
        }
        func setPosition(_ point: CGPoint) -> Bool {
            writes.append("position")
            requestedPositions.append(point)
            guard positionAllowed else { return false }
            if rejectsFirstPosition {
                rejectsFirstPosition = false
                return false
            }
            rect.origin = point
            if let positionBounds {
                rect.origin.x = min(point.x, positionBounds.maxX - rect.width)
                rect.origin.y = min(point.y, positionBounds.maxY - rect.height)
            }
            duringPosition?()
            return true
        }
    }
    /// AX exposes the requested attribute immediately, but commits a complete
    /// owner frame later. A second attribute before that commit uses stale peers.
    private final class CoupledAsyncWindow: WindowSnapWindowAccess {
        let processID: Int32 = 42
        var committed = CGRect(x: 1695, y: 309, width: 1747, height: 1130)
        var reported = CGRect(x: 1695, y: 309, width: 1747, height: 1130)
        var pending: CGRect?
        var writes: [String] = []
        private var ticksUntilCommit = 0
        var commitDelay = 3
        var eligible = true
        var fastEnabled = false
        var fastLeases = 0
        func withImmediateUpdates(isCurrent: () -> Bool, _ body: () -> Void) -> Bool {
            guard fastEnabled, isCurrent(), eligible else { return false }
            fastLeases += 1
            body()
            return true
        }
        func isEligibleAndActive() -> Bool { eligible }
        func readFrame() -> CGRect? { reported }
        func setPosition(_ point: CGPoint) -> Bool {
            writes.append("position")
            var next = committed
            next.origin = point
            reported = next
            pending = next
            ticksUntilCommit = commitDelay
            return true
        }
        func setSize(_ size: CGSize) -> Bool {
            writes.append("size")
            var next = committed
            next.size = CGSize(width: size.width.rounded(), height: size.height.rounded())
            reported = next
            pending = next
            ticksUntilCommit = commitDelay
            return true
        }
        func tick() {
            guard let pending else { return }
            ticksUntilCommit -= 1
            if ticksUntilCommit == 0 {
                committed = pending
                reported = pending
                self.pending = nil
            }
        }
    }
    func testLoggedRightHalfWithCoupledAsyncOwnerSettlesBetweenAttributes() {
        for delay in [2, 3] {
            let window = CoupledAsyncWindow()
            window.commitDelay = delay
            let target = CGRect(x: 926.5, y: 39, width: 873.5, height: 1130)
            var application = WindowSnapApplication(target: target)
            var succeeded = false
            for _ in 0..<45 {
                window.tick()
                let result = application.advance(window: window, isCurrent: { true })
                if case .succeeded = result { succeeded = true; break }
                if case .limited = result { break }
                if case .failed = result { break }
            }
            XCTAssertTrue(succeeded)
            XCTAssertTrue(WindowSnapApplication.matches(window.committed, target))
            XCTAssertEqual(window.writes, ["position", "size"])
            XCTAssertNil(window.pending, "Success must follow the actual native commit")
        }
    }
    func testSingleFastBatchFallsBackWhenCoupledAsyncOwnerIgnoresImmediateMode() {
        for delay in [2, 3] {
            let window = CoupledAsyncWindow(); window.fastEnabled = true; window.commitDelay = delay
            let target = CGRect(x: 926.5, y: 39, width: 873.5, height: 1130)
            var application = WindowSnapApplication(target: target)
            var stages: [String] = []
            var succeeded = false
            for _ in 0..<50 {
                window.tick()
                let result = application.advance(window: window, diagnostic: { stage, _ in stages.append(stage) }, isCurrent: { true })
                if case .succeeded = result { succeeded = true; break }
                if case .failed = result { break }
                if case .limited = result { break }
            }
            XCTAssertTrue(succeeded)
            XCTAssertEqual(window.fastLeases, 1)
            XCTAssertEqual(stages.filter { $0 == "fast_fallback" }.count, 1)
            XCTAssertTrue(WindowSnapApplication.matches(window.committed, target))
            XCTAssertNil(window.pending)
            XCTAssertEqual(application.attempts, 2)
        }
    }
    func testAlreadyExactInitialFrameNeedsOnlySpacedObservations() {
        let window = FakeWindow(); window.rect = visible
        var application = WindowSnapApplication(target: visible)
        if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
        XCTAssertTrue(window.writes.isEmpty)
        if case .succeeded = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
        XCTAssertTrue(window.writes.isEmpty)
        XCTAssertEqual(application.attempts, 0)
    }
    func testCancellationLeavesPendingNativeCommitButPreventsFollowingToolWrites() {
        for cancelAfterSize in [false, true] {
            let window = CoupledAsyncWindow()
            let target = CGRect(x: 926.5, y: 39, width: 873.5, height: 1130)
            var application = WindowSnapApplication(target: target)
            while window.writes.count < (cancelAfterSize ? 2 : 1) {
                window.tick()
                if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail(); return }
            }
            XCTAssertNotNil(window.pending)
            let writes = window.writes
            if case .failed = application.advance(window: window, isCurrent: { false }) {} else { XCTFail() }
            // The owner still completes already accepted native work after cancel.
            for _ in 0..<3 { window.tick() }
            XCTAssertNil(window.pending)
            if case .failed = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
            XCTAssertEqual(window.writes, writes)
        }
    }
    /// Drives the production transaction through its bounded scheduled observations.
    private func apply(target: CGRect, window: WindowSnapWindowAccess, isCurrent: () -> Bool) -> Bool {
        var application = WindowSnapApplication(target: target)
        for _ in 0..<45 {
            switch application.advance(window: window, isCurrent: isCurrent) {
            case .pending: continue
            case .succeeded: return true
            case .limited, .failed: return false
            }
        }
        XCTFail("Application did not terminate within its bounded observations")
        return false
    }
    func testLoggedMenuBarDragQualifiesDespiteRepeatedAndLaggingAXFrames() {
        let initial = CGRect(x: 926, y: 39, width: 874, height: 1130)
        let down = CGPoint(x: 1020.7617, y: 61.9063)
        var drag = WindowSnapDrag(initial: initial, down: down, earlierFrame: initial)
        let samples: [(Double, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.1167, 926, 39, 1020.7617, 62.0156),
            (0.1505, 926, 39, 1020.7617, 66.9922),
            (0.1853, 926, 39, 997.8438, 111.8789),
            (0.2227, 926, 39, 965.7188, 134.75),
            (0.2564, 860, 112, 931.7344, 126.7852),
            (0.2900, 860, 112, 881.3438, 46.6875),
            (0.3238, 860, 112, 844.3672, 0),
            (0.3635, 722, 39, 818.4805, 0),
            (0.3937, 722, 39, 815.4531, 0),
            (0.4162, 715, 39, 815.4531, 0)]
        for (time, x, y, px, py) in samples {
            _ = drag.observe(frame: CGRect(x: x, y: y, width: 874, height: 1130),
                pointer: CGPoint(x: px, y: py), topBoundary: 39, time: time)
        }
        XCTAssertTrue(drag.confirmed)
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let visible = CGRect(x: 53, y: 39, width: 1747, height: 1130)
        XCTAssertEqual(drag.target(pointer: CGPoint(x: 815.4531, y: 0), screen: screen, visible: visible), visible)
    }
    func testUpwardExcursionBeforeDelayedQualificationPreservesTitlebarTopIntent() {
        let initial = CGRect(x: 100, y: 39, width: 600, height: 400)
        var drag = WindowSnapDrag(initial: initial, down: CGPoint(x: 200, y: 59))
        XCTAssertFalse(drag.observe(frame: CGRect(x: 100, y: 139, width: 600, height: 400),
            pointer: CGPoint(x: 400, y: 159), topBoundary: 39, time: 0.05))
        XCTAssertFalse(drag.observe(frame: CGRect(x: 110, y: 39, width: 600, height: 400),
            pointer: CGPoint(x: 600, y: 159), topBoundary: 39, time: 0.10))
        XCTAssertTrue(drag.observe(frame: CGRect(x: 130, y: 39, width: 600, height: 400),
            pointer: CGPoint(x: 230, y: 59), topBoundary: 39, time: 0.15))
        let visible = CGRect(x: 0, y: 39, width: 1200, height: 761)
        XCTAssertEqual(drag.target(pointer: CGPoint(x: 230, y: 59),
            screen: CGRect(x: 0, y: 0, width: 1200, height: 800), visible: visible), visible)
    }
    func testLagHistoryExpiresAndClockResetCannotReusePointerEvidence() {
        let initial = CGRect(x: 926, y: 39, width: 874, height: 1130)
        for invalidTime in [1.0, 0.20, Double.nan] {
            var drag = WindowSnapDrag(initial: initial, down: CGPoint(x: 1020.7617, y: 61.9063))
            for (time, x, y) in [(0.1167, 1020.7617, 62.0156), (0.1505, 1020.7617, 66.9922),
                                  (0.1853, 997.8438, 111.8789), (0.2227, 965.7188, 134.75)] {
                XCTAssertFalse(drag.observe(frame: initial, pointer: CGPoint(x: x, y: y), topBoundary: 39, time: time))
            }
            XCTAssertFalse(drag.observe(frame: CGRect(x: 860, y: 112, width: 874, height: 1130),
                pointer: CGPoint(x: 931.7344, y: 126.7852), topBoundary: 39, time: invalidTime))
        }
    }
    func testLagHistoryNeverQualifiesStationaryContentOrResizedWindow() {
        let initial = CGRect(x: 926, y: 39, width: 874, height: 1130)
        let down = CGPoint(x: 1020.7617, y: 61.9063)
        var stationary = WindowSnapDrag(initial: initial, down: down)
        var resized = WindowSnapDrag(initial: initial, down: down)
        for index in 0..<100 {
            let pointer = CGPoint(x: down.x - CGFloat(index) * 10, y: down.y + CGFloat(index % 7) * 20)
            let time = Double(index) * 0.01
            XCTAssertFalse(stationary.observe(frame: initial, pointer: pointer, topBoundary: 39, time: time))
            var frame = initial
            if index == 3 { frame.size.width += 20 }
            if index > 3 { frame.origin.x -= CGFloat(index) * 10 }
            XCTAssertFalse(resized.observe(frame: frame, pointer: pointer, topBoundary: 39, time: time))
        }
        XCTAssertTrue(resized.invalidated)
    }
    func testLaggedHorizontalMovementAtTopDoesNotMaximizeWithoutUpwardIntent() {
        let initial = CGRect(x: 926, y: 39, width: 874, height: 1130)
        var drag = WindowSnapDrag(initial: initial, down: CGPoint(x: 1020, y: 45))
        XCTAssertFalse(drag.observe(frame: initial, pointer: CGPoint(x: 1020, y: 45), topBoundary: 39, time: 0.1))
        XCTAssertFalse(drag.observe(frame: initial, pointer: CGPoint(x: 970, y: 45), topBoundary: 39, time: 0.15))
        XCTAssertTrue(drag.observe(frame: initial.offsetBy(dx: -50, dy: 0), pointer: CGPoint(x: 900, y: 45), topBoundary: 39, time: 0.2))
        XCTAssertNil(drag.target(pointer: CGPoint(x: 900, y: 45), screen: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visible: CGRect(x: 53, y: 39, width: 1747, height: 1130)))
    }
    func testConfirmedMoveSurvivesTitlebarClampingAndCommits() {
        let window = FakeWindow()
        var drag = WindowSnapDrag(initial: window.rect, down: CGPoint(x: 200, y: 110))
        window.rect.origin.y = 50
        XCTAssertTrue(drag.observe(frame: window.rect, pointer: CGPoint(x: 200, y: 60)))
        window.rect.origin.y = 25 // AppKit clamps at menu bar while pointer continues to screen edge.
        XCTAssertTrue(drag.observe(frame: window.rect, pointer: CGPoint(x: 200, y: 1)))
        XCTAssertTrue(apply(target: visible, window: window, isCurrent: { true }))
        XCTAssertEqual(window.writes, ["position", "size"])
        XCTAssertEqual(window.rect, visible)
    }
    func testMenuBarReleaseCommitsButLeavingBandCancelsTarget() {
        let window = FakeWindow()
        var drag = WindowSnapDrag(initial: window.rect, down: CGPoint(x: 300, y: 110))
        window.rect.origin.y = 25
        let release = CGPoint(x: 300, y: 35)
        XCTAssertTrue(drag.observe(frame: window.rect, pointer: release))
        XCTAssertEqual(drag.target(pointer: release, screen: screen, visible: visible), visible)
        XCTAssertNil(drag.target(pointer: CGPoint(x: 300, y: 38), screen: screen, visible: visible))
        XCTAssertTrue(apply(target: drag.target(pointer: release, screen: screen, visible: visible)!, window: window, isCurrent: { true }))
        XCTAssertEqual(window.rect, visible)
    }
    func testHorizontalMoveOfAlreadyTopWindowDoesNotMaximizeButCornersRemainAvailable() {
        let initial = CGRect(x: 100, y: 25, width: 600, height: 400)
        var drag = WindowSnapDrag(initial: initial, down: CGPoint(x: 300, y: 35))
        XCTAssertTrue(drag.observe(frame: initial.offsetBy(dx: 50, dy: 0), pointer: CGPoint(x: 350, y: 35)))
        XCTAssertNil(drag.target(pointer: CGPoint(x: 350, y: 35), screen: screen, visible: visible))
        XCTAssertEqual(drag.target(pointer: CGPoint(x: 350, y: 25), screen: screen, visible: visible), visible)
        XCTAssertEqual(drag.target(pointer: CGPoint(x: 1, y: 35), screen: screen, visible: visible),
            CGRect(x: 0, y: 25, width: 600, height: 362.5))
    }
    func testFirstObservationAlreadyTopClampedRequiresRealUpwardTranslation() {
        let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
        let clamped = CGRect(x: 100, y: 25, width: 600, height: 400)
        let down = CGPoint(x: 300, y: 110)
        let pointer = CGPoint(x: 300, y: 10)
        var drag = WindowSnapDrag(initial: initial, down: down)
        XCTAssertFalse(WindowSnapping.isMove(initial: initial, current: clamped, pointerDelta: CGPoint(x: 0, y: -100)))
        XCTAssertTrue(drag.observe(frame: clamped, pointer: pointer, topBoundary: 25))
        XCTAssertEqual(drag.target(pointer: CGPoint(x: 300, y: 35), screen: screen, visible: visible), visible)
        var content = WindowSnapDrag(initial: clamped, down: CGPoint(x: 300, y: 35))
        XCTAssertFalse(content.observe(frame: clamped, pointer: pointer, topBoundary: 25))
        var wrongAxis = WindowSnapDrag(initial: initial, down: down)
        XCTAssertFalse(wrongAxis.observe(frame: clamped, pointer: CGPoint(x: 350, y: 10), topBoundary: 25))
        var wrongBoundary = WindowSnapDrag(initial: initial, down: down)
        XCTAssertFalse(wrongBoundary.observe(frame: clamped, pointer: pointer, topBoundary: 50))
        var resized = WindowSnapDrag(initial: initial, down: down)
        XCTAssertFalse(resized.observe(frame: CGRect(x: 100, y: 25, width: 650, height: 400), pointer: pointer, topBoundary: 25))
        XCTAssertTrue(resized.invalidated)
        var alreadyTop = WindowSnapDrag(initial: clamped, down: CGPoint(x: 300, y: 35))
        XCTAssertFalse(alreadyTop.observe(frame: clamped.offsetBy(dx: 50, dy: 0), pointer: CGPoint(x: 350, y: -50), topBoundary: 25),
            "Horizontal translation cannot excuse unmatched upward pointer travel from an already-top window")
    }
    func testEarlierExactWindowSnapshotRecoversFirstAttemptAfterDelayedAXBaseline() {
        let beforeAX = CGRect(x: 100, y: 100, width: 600, height: 400)
        let delayedAX = CGRect(x: 100, y: 25, width: 600, height: 400)
        let down = CGPoint(x: 300, y: 110)
        let release = CGPoint(x: 300, y: 10)
        var delayedOnly = WindowSnapDrag(initial: delayedAX, down: down)
        XCTAssertFalse(delayedOnly.observe(frame: delayedAX, pointer: release, topBoundary: 25))
        var recovered = WindowSnapDrag(initial: delayedAX, down: down, earlierFrame: beforeAX)
        XCTAssertTrue(recovered.observe(frame: delayedAX, pointer: release, topBoundary: 25),
            "Observed pre-AX to AX window translation proves the first attempt, including an already-clamped first observation")
        let window = FakeWindow(); window.rect = delayedAX
        let target = recovered.target(pointer: release, screen: screen, visible: visible)
        XCTAssertEqual(target, visible)
        XCTAssertTrue(apply(target: target!, window: window, isCurrent: { true }))
        XCTAssertEqual(window.writes, ["position", "size"])
        var stationary = WindowSnapDrag(initial: delayedAX, down: down, earlierFrame: delayedAX)
        XCTAssertFalse(stationary.observe(frame: delayedAX, pointer: release, topBoundary: 25))
        var mismatchedSize = WindowSnapDrag(initial: delayedAX, down: down,
            earlierFrame: CGRect(x: 100, y: 100, width: 700, height: 400))
        XCTAssertFalse(mismatchedSize.observe(frame: delayedAX, pointer: release, topBoundary: 25))
        var outsideDown = WindowSnapDrag(initial: delayedAX, down: down,
            earlierFrame: CGRect(x: 700, y: 100, width: 600, height: 400))
        XCTAssertFalse(outsideDown.observe(frame: delayedAX, pointer: release, topBoundary: 25))
    }
    func testProvenTopClampActivatesAtCapturedTitlebarGrabOffset() {
        for grabOffset in [15.0, 25, 44] {
            let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
            let clamped = CGRect(x: 100, y: 25, width: 600, height: 400)
            let down = CGPoint(x: 300, y: 100 + grabOffset)
            let release = CGPoint(x: 300, y: 25 + grabOffset)
            var drag = WindowSnapDrag(initial: initial, down: down)
            XCTAssertTrue(drag.observe(frame: clamped, pointer: release, topBoundary: 25))
            XCTAssertEqual(drag.target(pointer: release, screen: screen, visible: visible), visible,
                "First clamp should activate for a typical titlebar grab without requiring the pointer to cross the menu bar")
            XCTAssertNil(drag.target(pointer: CGPoint(x: 300, y: 25 + grabOffset + 3), screen: screen, visible: visible))
            XCTAssertEqual(drag.target(pointer: CGPoint(x: 1, y: release.y), screen: screen, visible: visible),
                CGRect(x: 0, y: 25, width: 600, height: 362.5))
        }
        let top = CGRect(x: 100, y: 25, width: 600, height: 400)
        var horizontal = WindowSnapDrag(initial: top, down: CGPoint(x: 300, y: 50))
        XCTAssertTrue(horizontal.observe(frame: top.offsetBy(dx: 50, dy: 0), pointer: CGPoint(x: 350, y: 50), topBoundary: 25))
        XCTAssertNil(horizontal.target(pointer: CGPoint(x: 350, y: 50), screen: screen, visible: visible))
        var deepGrab = WindowSnapDrag(initial: CGRect(x: 100, y: 100, width: 600, height: 400), down: CGPoint(x: 300, y: 200))
        XCTAssertTrue(deepGrab.observe(frame: top, pointer: CGPoint(x: 300, y: 125), topBoundary: 25))
        XCTAssertNil(deepGrab.target(pointer: CGPoint(x: 300, y: 125), screen: screen, visible: visible), "The grab-offset extension is bounded to the titlebar area")
        var delayed = WindowSnapDrag(initial: top, down: CGPoint(x: 300, y: 125),
            earlierFrame: CGRect(x: 100, y: 100, width: 600, height: 400))
        XCTAssertTrue(delayed.observe(frame: top, pointer: CGPoint(x: 300, y: 50), topBoundary: 25))
        XCTAssertEqual(delayed.target(pointer: CGPoint(x: 300, y: 50), screen: screen, visible: visible), visible)
        let otherScreen = CGRect(x: -1400, y: -900, width: 1400, height: 900)
        let otherVisible = CGRect(x: -1400, y: -875, width: 1400, height: 875)
        var offOrigin = WindowSnapDrag(initial: CGRect(x: -1000, y: -700, width: 600, height: 400), down: CGPoint(x: -800, y: -675))
        XCTAssertTrue(offOrigin.observe(frame: CGRect(x: -1000, y: -875, width: 600, height: 400), pointer: CGPoint(x: -800, y: -850), topBoundary: -875))
        XCTAssertEqual(offOrigin.target(pointer: CGPoint(x: -800, y: -850), screen: otherScreen, visible: otherVisible), otherVisible)
    }
    func testDelayedInitialAXReadConfirmsFromSuccessiveRealTranslation() {
        // Mouse down was at x=110, but the AX baseline arrived after the window moved 50pt.
        let lateBaseline = CGRect(x: 150, y: 100, width: 600, height: 400)
        var drag = WindowSnapDrag(initial: lateBaseline, down: CGPoint(x: 110, y: 110))
        XCTAssertFalse(drag.observe(frame: lateBaseline.offsetBy(dx: 10, dy: 0), pointer: CGPoint(x: 170, y: 110)))
        XCTAssertTrue(drag.observe(frame: lateBaseline.offsetBy(dx: 30, dy: 0), pointer: CGPoint(x: 190, y: 110)))
        var content = WindowSnapDrag(initial: lateBaseline, down: CGPoint(x: 110, y: 110))
        XCTAssertFalse(content.observe(frame: lateBaseline, pointer: CGPoint(x: 170, y: 110)))
        XCTAssertFalse(content.observe(frame: lateBaseline, pointer: CGPoint(x: 190, y: 110)))
        var tiny = WindowSnapDrag(initial: lateBaseline, down: CGPoint(x: 110, y: 110))
        XCTAssertFalse(tiny.observe(frame: lateBaseline, pointer: CGPoint(x: 160, y: 110)))
        XCTAssertFalse(tiny.observe(frame: lateBaseline.offsetBy(dx: 3, dy: 0), pointer: CGPoint(x: 163, y: 110)))
    }
    func testContentResizeAndUnconfirmedDragsNeverProduceTarget() {
        for mode in 0..<3 {
            let window = FakeWindow()
            var drag = WindowSnapDrag(initial: window.rect, down: CGPoint(x: 200, y: 110))
            if mode == 1 { window.rect.size.width += 100 }
            if mode == 2 { window.rect.origin.x += 3 }
            XCTAssertFalse(drag.observe(frame: window.rect, pointer: .zero))
            XCTAssertNil(drag.target(pointer: .zero, screen: screen, visible: visible))
            XCTAssertTrue(window.writes.isEmpty)
        }
        let window = FakeWindow()
        var drag = WindowSnapDrag(initial: window.rect, down: .zero)
        window.rect.size.width += 100
        XCTAssertFalse(drag.observe(frame: window.rect, pointer: .zero))
        window.rect.size.width -= 100; window.rect.origin.x += 20
        XCTAssertFalse(drag.observe(frame: window.rect, pointer: CGPoint(x: 20, y: 0)), "A resize disqualifies the entire down session")
    }
    func testCancelledAndReplacedPendingCommitsNeverWrite() {
        var session = WindowSnapSession()
        let token = session.generation
        let window = FakeWindow()
        var drag = WindowSnapDrag(initial: window.rect, down: .zero)
        window.rect.origin.x += 20
        XCTAssertTrue(drag.observe(frame: window.rect, pointer: CGPoint(x: 20, y: 0)))
        session.invalidate() // Escape/disable/Space change/new down before pending up is processed.
        XCTAssertFalse(apply(target: visible, window: window, isCurrent: { session.isCurrent(token) }))
        XCTAssertTrue(window.writes.isEmpty)
    }
    func testCancellationAndEligibilityLossStopBetweenEffects() {
        for effect in ["position", "size", "readback"] {
            for permissionLoss in [false, true] {
                let window = FakeWindow()
                var current = true
                let cancel = { if permissionLoss { window.eligible = false } else { current = false } }
                if effect == "position" { window.duringPosition = cancel }
                if effect == "size" { window.duringSize = cancel }
                if effect == "readback" { window.duringReadback = cancel }
                XCTAssertFalse(apply(target: visible, window: window, isCurrent: { current }))
                XCTAssertEqual(window.writes, effect == "size" ? ["position", "size"] : ["position"])
            }
        }
    }
    func testCancellationDuringInitialReadPreventsFirstWrite() {
        let window = FakeWindow()
        var current = true
        window.duringEveryRead = { current = false }
        XCTAssertFalse(apply(target: visible, window: window, isCurrent: { current }))
        XCTAssertTrue(window.writes.isEmpty)
    }
    func testLoggedOriginDependentSizeConstraintsRecover() {
        let bounds = CGRect(x: -805, y: -1620, width: 2880, height: 1620)
        let cases: [(CGRect, CGRect)] = [
            (CGRect(x: -651, y: -1620, width: 2271, height: 1211), bounds),
            (CGRect(x: -666, y: -1620, width: 2271, height: 1211), bounds),
            (CGRect(x: -1243, y: -1239, width: 2271, height: 1211), CGRect(x: -805, y: -1620, width: 1440, height: 1620))]
        for (original, target) in cases {
            let window = FakeWindow(); window.rect = original; window.bounds = bounds
            XCTAssertTrue(apply(target: target, window: window, isCurrent: { true }))
            XCTAssertEqual(window.rect, target)
        }
    }
    func testStableApplicationRepairsAcceptedWritesRolledBackByOwner() {
        let window = FakeWindow()
        var application = WindowSnapApplication(target: visible)
        while window.writes.count < 2 {
            if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail(); return }
        }
        // Native drag completion restores its stale frame after successful setters.
        window.rect = CGRect(x: 100, y: 100, width: 600, height: 400)
        if case .succeeded = finishApplication(&application, window: window) {} else { XCTFail() }
        XCTAssertEqual(application.attempts, 2)
        XCTAssertEqual(window.rect, visible)
    }
    func testUnstableApplicationHasBoundedRetriesAndCancellationStopsWrites() {
        let window = FakeWindow()
        let original = window.rect
        window.duringEveryRead = { window.rect = original }
        var application = WindowSnapApplication(target: visible)
        if case .failed = finishApplication(&application, window: window) {} else { XCTFail() }
        XCTAssertEqual(window.writes.count, 9, "Three move/size/correction passes at most")
        XCTAssertEqual(application.attempts, 3)
        let writes = window.writes
        if case .failed = application.advance(window: window, isCurrent: { false }) {} else { XCTFail() }
        XCTAssertEqual(window.writes, writes)
    }
    private func finishApplication(_ application: inout WindowSnapApplication, window: FakeWindow) -> WindowSnapApplication.Result {
        for _ in 0..<45 {
            let result = application.advance(window: window, isCurrent: { true })
            if case .pending = result { continue }
            return result
        }
        XCTFail("Application exceeded its observation bound")
        return .failed
    }
    func testMinAndMaxConstraintsRetainAttainedFrameWithoutOriginalRequests() {
        for minimum in [false, true] {
            let window = FakeWindow()
            let original = window.rect
            let target = minimum ? CGRect(x: 600, y: 400, width: 600, height: 400) : visible
            if minimum {
                window.rect.size = CGSize(width: 800, height: 600)
                window.minimumSize = CGSize(width: 700, height: 500)
            }
            else { window.clampsSize = true }
            var application = WindowSnapApplication(target: target)
            if case .limited = finishApplication(&application, window: window) {} else { XCTFail() }
            XCTAssertNotEqual(window.rect, original)
            XCTAssertEqual(window.rect.origin, target.origin)
            XCTAssertEqual(window.requestedSizes, Array(repeating: target.size, count: 3))
            XCTAssertTrue(window.requestedPositions.allSatisfy { $0 == target.origin })
            XCTAssertEqual(application.attempts, 3)
            let writes = window.writes
            if case .limited = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
            XCTAssertEqual(window.writes, writes)
        }
    }
    func testMinimumHeightWithPositionClampingRetainsNearestAttainedFrame() {
        let window = FakeWindow()
        window.rect = CGRect(x: 100, y: 100, width: 600, height: 600)
        window.minimumSize = CGSize(width: 100, height: 500)
        window.bounds = screen
        window.positionBounds = screen
        let target = CGRect(x: 600, y: 400, width: 600, height: 400)
        var application = WindowSnapApplication(target: target)
        if case .limited = finishApplication(&application, window: window) {} else { XCTFail() }
        XCTAssertEqual(window.rect, CGRect(x: 600, y: 300, width: 600, height: 500))
        XCTAssertEqual(window.requestedSizes, Array(repeating: target.size, count: 3))
        XCTAssertTrue(window.requestedPositions.allSatisfy { $0 == target.origin })
    }
    func testAlternatingExactAndNonexactObservationsTerminateWithoutMoreWrites() {
        let window = FakeWindow()
        let original = window.rect
        var application = WindowSnapApplication(target: visible)
        if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
        let writes = window.writes
        var terminated = false
        for index in 0..<45 {
            window.rect = index.isMultiple(of: 2) ? visible : original
            if case .failed = application.advance(window: window, isCurrent: { true }) {
                terminated = true
                break
            }
        }
        XCTAssertTrue(terminated)
        XCTAssertEqual(window.writes, writes, "An unsettled move cannot issue a resize")
        if case .failed = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
        XCTAssertEqual(window.writes, writes)
    }
    func testCancellationWhileMoveOrSizeIsPendingStopsFollowingPhases() {
        for afterSize in [false, true] {
            let window = FakeWindow()
            var application = WindowSnapApplication(target: visible)
            while window.writes.count < (afterSize ? 2 : 1) {
                if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail(); return }
            }
            let writes = window.writes
            if case .failed = application.advance(window: window, isCurrent: { false }) {} else { XCTFail() }
            if case .failed = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
            XCTAssertEqual(window.writes, writes)
        }
    }
    func testCancellationAndEligibilityLossDuringCorrectionAndSizeReadback() {
        for duringCorrection in [false, true] {
            for permissionLoss in [false, true] {
                let window = FakeWindow(); window.rect = screen; window.positionBounds = screen
                var current = true
                let cancel = { if permissionLoss { window.eligible = false } else { current = false } }
                if duringCorrection {
                    window.duringPosition = { if window.writes.count == 3 { cancel() } }
                } else {
                    window.duringReadback = { if window.writes.last == "size" { cancel() } }
                }
                let target = CGRect(x: 600, y: 400, width: 600, height: 400)
                XCTAssertFalse(apply(target: target, window: window, isCurrent: { current }))
                XCTAssertEqual(window.writes, duringCorrection ? ["position", "size", "position"] : ["position", "size"])
            }
        }
    }
    func testDeniedSizeAfterSuccessfulMoveRetainsPartialResult() {
        let window = FakeWindow(); window.sizeAllowed = false
        let originalSize = window.rect.size
        var application = WindowSnapApplication(target: visible)
        if case .limited = finishApplication(&application, window: window) {} else { XCTFail() }
        XCTAssertEqual(window.rect.origin, visible.origin)
        XCTAssertEqual(window.rect.size, originalSize)
        XCTAssertEqual(window.writes, ["position", "size"])
        XCTAssertEqual(application.attempts, 1)
    }
    func testDeniedCorrectionAfterResizeRetainsAttainedFrame() {
        let window = FakeWindow()
        window.rect = screen
        window.positionBounds = screen
        window.duringSize = { window.positionAllowed = false }
        let target = CGRect(x: 600, y: 400, width: 600, height: 400)
        var application = WindowSnapApplication(target: target)
        if case .limited = finishApplication(&application, window: window) {} else { XCTFail() }
        XCTAssertEqual(window.rect.size, target.size)
        XCTAssertEqual(window.writes, ["position", "size", "position"])
    }
    func testAllDeniedAndNoEffectStayFailureAndTerminal() {
        for denied in [true, false] {
            let window = FakeWindow(); let original = window.rect
            if denied { window.positionAllowed = false; window.sizeAllowed = false }
            else { window.duringPosition = { window.rect = original }; window.duringSize = { window.rect = original } }
            var application = WindowSnapApplication(target: visible)
            if case .failed = finishApplication(&application, window: window) {} else { XCTFail() }
            let writes = window.writes
            if case .failed = application.advance(window: window, isCurrent: { true }) {} else { XCTFail() }
            XCTAssertEqual(window.writes, writes)
        }
    }
    func testDelayedSizeReadbackAllowsOriginCorrectionAndSettles() {
        let window = FakeWindow(); window.rect = screen; window.positionBounds = screen
        let original = window.rect
        window.duringSize = { window.rect.size = original.size; window.duringSize = nil }
        let target = CGRect(x: 600, y: 400, width: 600, height: 400)
        var application = WindowSnapApplication(target: target)
        while window.writes.count < 2 {
            if case .pending = application.advance(window: window, isCurrent: { true }) {} else { XCTFail(); return }
        }
        XCTAssertEqual(window.writes, ["position", "size"])
        window.rect.size = target.size
        if case .succeeded = finishApplication(&application, window: window) {} else { XCTFail() }
        XCTAssertEqual(application.attempts, 1)
        XCTAssertEqual(window.writes, ["position", "size", "position"])
    }
    func testOversizedWindowMovesThenShrinksThenCorrectsRightBottomPosition() {
        let window = FakeWindow(); window.rect = screen; window.positionBounds = screen
        let target = CGRect(x: 600, y: 400, width: 600, height: 400)
        XCTAssertTrue(apply(target: target, window: window, isCurrent: { true }))
        XCTAssertEqual(window.writes, ["position", "size", "position"])
        XCTAssertEqual(window.rect, target)
    }
    func testZones() {
        XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: 0, y: 300), screen: screen, visible: visible), CGRect(x: 0, y: 25, width: 600, height: 725))
        XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: 1199, y: 799), screen: screen, visible: visible), CGRect(x: 600, y: 387.5, width: 600, height: 362.5))
        XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: 600, y: 0), screen: screen, visible: visible), visible)
        XCTAssertNil(WindowSnapping.target(pointer: CGPoint(x: 600, y: 799), screen: screen, visible: visible))
        XCTAssertNil(WindowSnapping.target(pointer: CGPoint(x: -1, y: 0), screen: screen, visible: visible))
    }
    func testTopZoneIncludesMenuBarBoundaryAndModestTolerance() {
        for y in [0.0, 24, 25, 36, 37] {
            XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: 600, y: y), screen: screen, visible: visible), visible)
        }
        XCTAssertNil(WindowSnapping.target(pointer: CGPoint(x: 600, y: 38), screen: screen, visible: visible))
        XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: 1, y: 36), screen: screen, visible: visible),
            CGRect(x: 0, y: 25, width: 600, height: 362.5))
        let otherScreen = CGRect(x: -1400, y: -900, width: 1400, height: 900)
        let otherVisible = CGRect(x: -1400, y: -875, width: 1400, height: 875)
        XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: -700, y: -863), screen: otherScreen, visible: otherVisible), otherVisible)
        XCTAssertNil(WindowSnapping.target(pointer: CGPoint(x: -700, y: -862), screen: otherScreen, visible: otherVisible))
        XCTAssertNil(WindowSnapping.target(pointer: CGPoint(x: 100, y: -863), screen: otherScreen, visible: otherVisible))
    }
    func testCoordinatesAndNegativeDisplays() {
        let aboveLeft = CGRect(x: -1200, y: 800, width: 1200, height: 800)
        let cg = WindowSnapping.cgRect(aboveLeft, primaryTop: 800)
        XCTAssertEqual(cg, CGRect(x: -1200, y: -800, width: 1200, height: 800))
        XCTAssertEqual(WindowSnapping.cgRect(cg, primaryTop: 800), aboveLeft)
        XCTAssertEqual(WindowSnapping.target(pointer: CGPoint(x: -1199, y: -799), screen: cg, visible: cg), CGRect(x: -1200, y: -800, width: 600, height: 400))
    }
    func testMultiDisplayConversionPreservesPointGeometryWithNonzeroPrimaryTop() {
        // AppKit, CGEvent, AX and WindowServer rectangles are logical points;
        // a Retina scale factor must not be applied to these coordinates.
        let primaryTop: CGFloat = 1117
        let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                        CGRect(x: -2560, y: 250, width: 2560, height: 1440),
                        CGRect(x: 1728, y: -300, width: 1920, height: 1080)]
        for display in displays {
            let available = display.insetBy(dx: 0, dy: 24)
            let screen = WindowSnapping.cgRect(display, primaryTop: primaryTop)
            let visible = WindowSnapping.cgRect(available, primaryTop: primaryTop)
            XCTAssertEqual(WindowSnapping.cgRect(screen, primaryTop: primaryTop), display)
            let pointer = CGPoint(x: screen.midX, y: visible.minY + 4)
            XCTAssertEqual(WindowSnapping.target(pointer: pointer, screen: screen, visible: visible), visible)
            let half = WindowSnapping.target(pointer: CGPoint(x: screen.minX + 1, y: screen.midY), screen: screen, visible: visible)
            XCTAssertEqual(half, CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height))
            XCTAssertNil(WindowSnapping.target(pointer: CGPoint(x: screen.maxX + 20, y: screen.midY), screen: screen, visible: visible))
        }
    }
    func testMovementRejectsContentAndResize() {
        let initial = CGRect(x: 20, y: 40, width: 600, height: 400)
        XCTAssertFalse(WindowSnapping.isMove(initial: initial, current: initial, pointerDelta: CGPoint(x: 100, y: 100)))
        XCTAssertFalse(WindowSnapping.isMove(initial: initial, current: CGRect(x: 120, y: 140, width: 700, height: 400), pointerDelta: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(WindowSnapping.isMove(initial: initial, current: initial.offsetBy(dx: 100, dy: 100), pointerDelta: CGPoint(x: 100, y: 100)))
    }
    func testAvailabilityAndLegacyDefault() throws {
        XCTAssertTrue(WindowSnapping.eligible(macOSMajorVersion: 14, separateSpaces: true))
        XCTAssertTrue(WindowSnapping.eligible(macOSMajorVersion: 15, separateSpaces: false))
        XCTAssertFalse(WindowSnapping.eligible(macOSMajorVersion: 26, separateSpaces: true))
        let legacy = Data(#"{"isEnabled":true,"shortcut":"optionTab","currentAppOnly":false,"includeMinimized":true,"includeHidden":true}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(WindowSwitcherSettings.self, from: legacy).snappingEnabled)
        var settings = WindowSwitcherSettings(); settings.snappingEnabled = true
        XCTAssertFalse(try JSONDecoder().decode(WindowSwitcherSettings.self, from: JSONEncoder().encode(settings)).snappingEnabled)
    }
}
