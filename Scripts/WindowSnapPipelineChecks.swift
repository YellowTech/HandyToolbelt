import AppKit
import SwiftUI
import HandyToolbeltCore

// Only the unused native preview references Theme. No AppKit windows are created.
enum Theme { static let accent = Color.blue }
private final class Window: WindowSnapWindowAccess {
    var processID: Int32 = 42
    var frame = CGRect(x: 200, y: 200, width: 400, height: 300)
    var eligible = true, readable = true, writesOK = true
    var writes: [String] = []
    var afterSize: (() -> Void)?
    var fastEnabled = false
    var enhancedMode: Bool? = true
    var fastLeases = 0
    var modeWrites: [Bool] = []
    func withImmediateUpdates(isCurrent: () -> Bool, _ body: () -> Void) -> Bool {
        guard fastEnabled else { return false }
        fastLeases += 1
        return WindowSnapImmediateUpdates.perform(assistiveTechnologyEnabled: false,
            isEligible: { isCurrent() && self.eligible }, readMode: { self.enhancedMode },
            writeMode: { value in self.modeWrites.append(value); self.enhancedMode = value; return true }, body: body)
    }
    var bounds: CGRect?
    var maximumSize: CGSize?
    var committedFrame: CGRect?
    var scheduleNative: ((Double, @escaping () -> Void) -> Void)?
    var commitDelay = 0.25
    private var nativeGeneration = 0
    private func publish(_ next: CGRect) {
        frame = next
        guard let scheduleNative else { return }
        nativeGeneration += 1
        let token = nativeGeneration
        scheduleNative(commitDelay) { [self] in
            guard token == nativeGeneration else { return }
            committedFrame = next
            frame = next
        }
    }
    func isEligibleAndActive() -> Bool { eligible }
    func readFrame() -> CGRect? { readable ? frame : nil }
    func setSize(_ value: CGSize) -> Bool {
        writes.append("size")
        if writesOK {
            var next = committedFrame ?? frame
            next.size = value
            if committedFrame != nil { next.size.width = value.width.rounded() }
            if let maximumSize {
                next.size.width = min(next.width, maximumSize.width)
                next.size.height = min(next.height, maximumSize.height)
            }
            if let bounds {
                next.size.width = min(next.width, bounds.maxX - next.minX)
                next.size.height = min(next.height, bounds.maxY - next.minY)
            }
            publish(next)
        }
        afterSize?()
        return writesOK
    }
    func setPosition(_ value: CGPoint) -> Bool {
        writes.append("position")
        if writesOK {
            var next = committedFrame ?? frame
            next.origin = value
            publish(next)
        }
        return writesOK
    }
}
private final class Rig {
    var jobs: [(Double, () -> Void)] = [], previews: [() -> Void] = []
    var time = 0.0
    var shown: [CGRect?] = []
    var window = Window(), other = Window()
    var resolution: (() -> Void)?
    var displays = [(CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 0, y: 24, width: 1000, height: 776))]
    var lookupOK = true
    var routes: [(Int32?, UInt32?)] = []
    lazy var monitor = WindowSnapMonitor(boundary: .init(
        scheduleWorker: { self.jobs.append((self.time + $0, $1)) },
        schedulePreview: { self.previews.append($0) }, now: { self.time },
        resolve: { _, pid, id in
            self.routes.append((pid, id)); self.resolution?()
            guard self.lookupOK else { return nil }
            return .init(access: self.window, frame: self.window.frame,
                         earlierFrame: CGRect(x: 200, y: 200, width: 400, height: 300))
        }, preview: { self.shown.append($0) }),
        screens: displays, activePID: 42)
    init(displays: [(CGRect, CGRect)]? = nil) {
        if let displays { self.displays = displays }
        monitor.onInteraction = { true }
    }
    func send(_ type: CGEventType, _ x: CGFloat = 300, _ y: CGFloat = 220) {
        monitor.capture(type, point: CGPoint(x: x, y: y), targetPID: 42, handlingWindowID: 99)
    }
    func runOne() {
        precondition(!jobs.isEmpty)
        let index = jobs.indices.min { jobs[$0].0 < jobs[$1].0 }!
        let job = jobs.remove(at: index)
        time = max(time + 0.000001, job.0)
        job.1()
    }
    func run() { var count = 0; while !jobs.isEmpty { count += 1; precondition(count < 100); runOne() } }
    func flushPreview() { let callbacks = previews; previews = []; callbacks.forEach { $0() } }
    func moveTop() { window.frame.origin.y = 24; send(.leftMouseDragged, 300, 44) }
    var diagnostics: WindowSnapDiagnostics { monitor.diagnostics.latestInteraction }
}
@main enum Checks {
    static func main() {
        var count = 0
        func check(_ label: String, displays: [(CGRect, CGRect)]? = nil, _ body: (Rig) -> Void) {
            let rig = Rig(displays: displays); body(rig); count += 1; print("PASS \(label)")
        }
        check("delayed lookup, coalesced release, first upward drag and clamped titlebar") { r in
            r.send(.leftMouseDown)
            r.resolution = { r.moveTop(); r.send(.leftMouseUp, 300, 44) }
            r.run(); r.flushPreview()
            precondition(r.window.writes == ["position", "size"])
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 1000, height: 776))
            precondition(r.other.writes.isEmpty && r.routes.first!.0 == 42 && r.routes.first!.1 == 99)
            precondition(r.diagnostics.completed && r.diagnostics.commitSucceeded == true)
        }
        check("fast batch visibly reaches target at first application then verifies") { r in
            r.window.fastEnabled = true
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
            r.runOne(); r.runOne()
            let firstApplyTime = r.time
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 1000, height: 776))
            precondition(r.window.writes == ["position", "size"])
            precondition(r.window.modeWrites == [false, true] && r.window.enhancedMode == true)
            precondition(r.diagnostics.commitSucceeded == nil)
            r.run()
            precondition(r.time - firstApplyTime >= 0.29)
            precondition(r.diagnostics.commitSucceeded == true && r.window.fastLeases == 1)
        }
        check("native drag overwrite after fast batch enters paced fallback exactly once") { r in
            r.window.fastEnabled = true
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
            r.runOne(); r.runOne()
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 1000, height: 776))
            r.jobs.append((r.time + 0.15, {
                r.window.frame = CGRect(x: 200, y: 24, width: 400, height: 300)
            }))
            r.run()
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 1000, height: 776))
            precondition(r.diagnostics.commitSucceeded == true && r.window.fastLeases == 1)
            precondition(r.window.writes == ["position", "size", "position", "size"])
            precondition(r.window.modeWrites == [false, true])
        }
        check("cancel during fast verification cannot issue later writes or leak mode") { r in
            r.window.fastEnabled = true
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
            r.runOne(); r.runOne()
            let writes = r.window.writes
            r.monitor.cancel(); r.run()
            precondition(r.window.writes == writes)
            precondition(r.window.enhancedMode == true && r.window.modeWrites == [false, true])
        }
        check("accepted AX writes rolled back by native drag are reapplied and verified") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
            // Process release, then the delayed first application.
            r.runOne(); r.runOne()
            while r.window.writes.count < 2 { r.runOne() }
            precondition(r.window.writes == ["position", "size"])
            precondition(r.diagnostics.commitSucceeded == nil && !r.diagnostics.completed)
            r.window.frame = CGRect(x: 200, y: 24, width: 400, height: 300)
            r.run()
            precondition(r.window.writes == ["position", "size", "position", "position", "size"])
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 1000, height: 776))
            precondition(r.diagnostics.commitSucceeded == true && r.diagnostics.completed)
        }
        check("accepted size with delayed AX readback is retained until its next observation") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            r.window.afterSize = { r.window.frame.size = CGSize(width: 400, height: 300); r.window.afterSize = nil }
            r.send(.leftMouseUp, 300, 44); r.runOne(); r.runOne()
            while r.window.writes.count < 2 { r.runOne() }
            precondition(r.window.writes == ["position", "size"] && r.diagnostics.commitSucceeded == nil)
            r.window.frame.size = CGSize(width: 1000, height: 776)
            r.run()
            precondition(r.window.writes == ["position", "size"] && r.diagnostics.commitSucceeded == true)
        }
        check("constrained snap retains attained geometry and reports limited result") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            r.window.maximumSize = CGSize(width: 700, height: 500)
            r.send(.leftMouseUp, 300, 44); r.run()
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 700, height: 500))
            precondition(r.diagnostics.completed && r.diagnostics.commitSucceeded == false)
            precondition(r.diagnostics.reason == "partial_result_retained")
            precondition(r.window.writes == Array(repeating: ["position", "size"], count: 3).flatMap { $0 })
        }
        check("new drag cancels verification retry after a rollback") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
            r.runOne(); r.runOne()
            while r.window.writes.count < 2 { r.runOne() }
            r.window.frame = CGRect(x: 200, y: 24, width: 400, height: 300)
            r.send(.leftMouseDown); r.run()
            precondition(r.window.writes == ["position", "size"])
        }
        check("new drag cancels delayed application before any write") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
            r.runOne(); r.send(.leftMouseDown); r.run()
            precondition(r.window.writes.isEmpty)
        }
        check("release before lookup without movement cannot snap") { r in
            r.send(.leftMouseDown); r.send(.leftMouseUp, 300, 24); r.run()
            precondition(r.window.writes.isEmpty && r.diagnostics.completed)
        }
        for disable in [false, true] {
            check(disable ? "disable during lookup" : "cancel during lookup") { r in
                r.send(.leftMouseDown)
                r.resolution = { r.moveTop(); r.send(.leftMouseUp, 300, 44); if disable { r.monitor.stop() } else { r.monitor.cancel() } }
                r.run(); r.flushPreview(); precondition(r.window.writes.isEmpty)
            }
        }
        check("new down while old lookup runs preserves newer release") { r in
            r.send(.leftMouseDown)
            r.resolution = {
                r.resolution = nil; r.send(.leftMouseDown); r.moveTop(); r.send(.leftMouseUp, 300, 44)
            }
            r.run(); precondition(r.routes.count == 2 && r.window.writes == ["position", "size"])
            precondition(r.diagnostics.mouseDownCount == 1 && r.diagnostics.mouseUpCount == 1)
        }
        check("stale queued preview after cancel") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            precondition(!r.previews.isEmpty); r.monitor.cancel(); let count = r.shown.count
            r.flushPreview(); precondition(r.shown.count == count && r.window.writes.isEmpty)
        }
        check("new down invalidates queued preview callbacks") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            r.send(.leftMouseDown); let count = r.shown.count; r.flushPreview()
            precondition(r.shown.count == count && r.window.writes.isEmpty); r.run()
        }
        check("activation change hides visible preview and rejects stale queued preview") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.flushPreview()
            precondition(r.shown.contains { $0 != nil })
            // Leave another valid outline callback queued when activation invalidates its token.
            r.send(.leftMouseDragged, 300, 44); r.run(); precondition(!r.previews.isEmpty)
            r.monitor.applicationActivated(77)
            precondition(r.shown.last! == nil)
            let count = r.shown.count; r.flushPreview(); precondition(r.shown.count == count)
            r.send(.leftMouseUp, 300, 44); r.run(); r.flushPreview()
            precondition(r.window.writes.isEmpty && r.shown.last! == nil)
        }
        check("own process resolution rejected") { r in
            r.window.processID = ProcessInfo.processInfo.processIdentifier
            r.send(.leftMouseDown); r.moveTop(); r.send(.leftMouseUp, 300, 44); r.run()
            precondition(r.window.writes.isEmpty && !r.diagnostics.resolved)
        }
        check("tracking frame read failure prevents commit") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.window.readable = false
            r.send(.leftMouseUp, 300, 44); r.run(); precondition(r.window.writes.isEmpty)
        }
        check("ineligible target prevents commit") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.window.eligible = false
            r.send(.leftMouseUp, 300, 44); r.run(); precondition(r.window.writes.isEmpty)
        }
        check("content drag has no window translation") { r in
            r.send(.leftMouseDown); r.run(); r.send(.leftMouseDragged, 1, 220); r.run(); r.send(.leftMouseUp, 1, 220); r.run()
            precondition(r.window.writes.isEmpty && !r.diagnostics.movementConfirmed)
        }
        check("resize permanently rejects gesture") { r in
            r.send(.leftMouseDown); r.run(); r.window.frame.size.width += 20
            r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44); r.run(); precondition(r.window.writes.isEmpty)
        }
        check("lookup failure") { r in
            r.lookupOK = false; r.send(.leftMouseDown); r.moveTop(); r.send(.leftMouseUp, 300, 44); r.run()
            precondition(r.window.writes.isEmpty && !r.diagnostics.resolved)
        }
        check("AX move failure") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.window.writesOK = false
            r.send(.leftMouseUp, 300, 44); r.run()
            precondition(r.window.writes == ["position"] && r.diagnostics.commitSucceeded == false)
        }
        check("cancel during commit prevents subsequent position write") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.window.afterSize = { r.monitor.cancel() }
            r.send(.leftMouseUp, 300, 44); r.run(); precondition(r.window.writes == ["position", "size"])
        }
        check("drag coalescing and delayed throttle retain latest release") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            for _ in 0..<50 { r.send(.leftMouseDragged, 300, 44) }
            r.runOne(); r.send(.leftMouseUp, 300, 44); r.run()
            precondition(r.window.writes == ["position", "size"] && r.diagnostics.processedDragCount <= 2)
        }
        check("100 same-monitor cycles drain work and bound diagnostics history") { r in
            for cycle in 0..<100 {
                r.window.frame = CGRect(x: 200, y: 200, width: 400, height: 300)
                r.send(.leftMouseDown)
                if cycle.isMultiple(of: 2) {
                    r.run(); r.moveTop(); r.run(); r.send(.leftMouseUp, 300, 44)
                } else {
                    // Repeated invalidation before lookup exercises abandoned queued work too.
                    r.send(.leftMouseDragged, 300, 44); r.monitor.cancel(); r.monitor.cancel()
                }
                r.run(); r.flushPreview()
                precondition(r.jobs.isEmpty && r.previews.isEmpty)
                precondition(r.monitor.diagnostics.completedDrags.count <= 8)
            }
            precondition(r.monitor.diagnostics.totalMouseDownCount == 100)
            precondition(r.monitor.diagnostics.completedDrags.count == 8)
            precondition(r.window.writes.count == 100)
        }
        check("opt-in recording captures native pipeline and commit readbacks") { r in
            DebugEventRecorder.shared.setEnabled(true)
            defer { DebugEventRecorder.shared.setEnabled(false) }
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            r.send(.leftMouseUp, 300, 44); r.run()
            let data = try! DebugEventRecorder.shared.snapshot()
            struct Export: Decodable { let schemaVersion: Int; let events: [DebugEvent] }
            let export = try! JSONDecoder().decode(Export.self, from: data)
            precondition(export.schemaVersion == 1)
            let events = export.events
            precondition(events.contains { $0.category == .snapping && $0.event == "pointer_down" })
            precondition(events.contains { $0.event == "movement" && $0.fields["confirmed"] == "true" })
            precondition(events.contains { $0.event == "commit_observation" && $0.fields["stage"] == "readback" })
            precondition(events.contains { $0.event == "commit_finished" && $0.fields["succeeded"] == "true" })
            let allowedFields: Set<String> = ["generation", "stage", "reason", "x", "y", "pid", "handling_window", "pointer_window",
                "original", "earlier", "current", "confirmed", "invalidated", "display", "visible", "requested", "attempts", "frame", "succeeded"]
            precondition(events.filter { $0.category == .snapping }.allSatisfy { Set($0.fields.keys).isSubset(of: allowedFields) })
        }
        check("logged menu-bar drag qualifies across lagging AX observations",
              displays: [(CGRect(x: 0, y: 0, width: 1800, height: 1169), CGRect(x: 53, y: 39, width: 1747, height: 1130))]) { r in
            r.window.frame = CGRect(x: 926, y: 39, width: 874, height: 1130)
            r.send(.leftMouseDown, 1020.7617, 61.9063); r.run()
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
            for (index, sample) in samples.enumerated() {
                r.jobs.append((sample.0, {
                    r.window.frame = CGRect(x: sample.1, y: sample.2, width: 874, height: 1130)
                    r.send(index == samples.count - 1 ? .leftMouseUp : .leftMouseDragged, sample.3, sample.4)
                }))
            }
            r.run()
            precondition(r.diagnostics.movementConfirmed && r.diagnostics.targetFound)
            precondition(r.diagnostics.commitSucceeded == true)
            precondition(r.window.frame == CGRect(x: 53, y: 39, width: 1747, height: 1130))
        }
        for delay in [0.15, 0.25] {
            let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
            let visible = CGRect(x: 53, y: 39, width: 1747, height: 1130)
            check("logged right half settles coupled native frame at delay \(delay)", displays: [(screen, visible)]) { r in
                r.window.frame = CGRect(x: 1495, y: 309, width: 1747, height: 1130)
                r.send(.leftMouseDown, 1595, 329); r.run()
                r.window.frame.origin.x = 1695
                r.send(.leftMouseDragged, 1795, 329); r.run()
                r.window.committedFrame = r.window.frame
                r.window.commitDelay = delay
                r.window.scheduleNative = { delay, effect in r.jobs.append((r.time + delay, effect)) }
                r.send(.leftMouseUp, 1799, 500); r.run()
                let target = CGRect(x: 926.5, y: 39, width: 873.5, height: 1130)
                precondition(WindowSnapApplication.matches(r.window.frame, target))
                precondition(WindowSnapApplication.matches(r.window.committedFrame!, target))
                precondition(r.diagnostics.commitSucceeded == true)
                precondition(r.window.writes == ["position", "size"])
            }
        }
        for delay in [0.15, 0.25] {
            let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
            let visible = CGRect(x: 53, y: 39, width: 1747, height: 1130)
            check("one fast batch falls back when coupled owner ignores mode at delay \(delay)", displays: [(screen, visible)]) { r in
                r.window.fastEnabled = true
                r.window.frame = CGRect(x: 1495, y: 309, width: 1747, height: 1130)
                r.send(.leftMouseDown, 1595, 329); r.run()
                r.window.frame.origin.x = 1695
                r.send(.leftMouseDragged, 1795, 329); r.run()
                r.window.committedFrame = r.window.frame
                r.window.commitDelay = delay
                r.window.scheduleNative = { delay, effect in r.jobs.append((r.time + delay, effect)) }
                r.send(.leftMouseUp, 1799, 500); r.run()
                let target = CGRect(x: 926.5, y: 39, width: 873.5, height: 1130)
                precondition(WindowSnapApplication.matches(r.window.committedFrame!, target))
                precondition(r.diagnostics.commitSucceeded == true)
                precondition(r.window.fastLeases == 1 && r.window.enhancedMode == true)
                precondition(r.window.modeWrites == [false, true])
                precondition(r.window.writes == ["position", "size", "position", "position", "size"])
            }
        }
        let loggedDisplay = CGRect(x: -805, y: -1620, width: 2880, height: 1620)
        for (x, y, half) in [(-651.0, -1620.0, false), (-666.0, -1620.0, false), (-1243.0, -1239.0, true)] {
            check("logged origin-constrained resize \(x),\(y)", displays: [(loggedDisplay, loggedDisplay)]) { r in
                r.window.frame = CGRect(x: x, y: y + 100, width: 2271, height: 1211)
                let downX = half ? x + 200 : 300
                r.send(.leftMouseDown, downX, y + 120); r.run()
                r.window.frame.origin = CGPoint(x: x, y: y)
                r.send(.leftMouseDragged, downX, y + 20); r.run()
                // The final pointer reaches the left band for the half-screen case.
                let releaseX: CGFloat = half ? -804 : 300
                r.window.bounds = loggedDisplay
                r.send(.leftMouseUp, releaseX, half ? -1000 : -1600); r.run()
                let target = half ? CGRect(x: -805, y: -1620, width: 1440, height: 1620) : loggedDisplay
                precondition(r.window.frame == target && r.diagnostics.commitSucceeded == true)
            }
        }
        for origin in [CGPoint(x: -1400, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: 0, y: -900), CGPoint(x: 0, y: 800)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1400, height: 900))
            let visible = CGRect(x: origin.x, y: origin.y + 24, width: 1400, height: 876)
            check("external display at \(origin.x),\(origin.y) applies global point frame", displays: [(screen, visible)]) { r in
                r.window.frame = CGRect(x: origin.x + 200, y: origin.y + 200, width: 400, height: 300)
                let x = origin.x + 300
                r.send(.leftMouseDown, x, origin.y + 220); r.run()
                r.window.frame.origin.y = visible.minY
                r.send(.leftMouseDragged, x, visible.minY + 20); r.run()
                r.send(.leftMouseUp, x, visible.minY + 20); r.run(); r.flushPreview()
                precondition(r.window.frame == visible && r.diagnostics.commitSucceeded == true)
                precondition(r.window.writes == ["position", "size"])
            }
        }
        print("Window snapping production pipeline: \(count) checks passed")
    }
}
