import AppKit
import SwiftUI
import SuperTrackpadCore

// Only the unused native preview references Theme. No AppKit windows are created.
enum Theme { static let accent = Color.blue }
private final class Window: WindowSnapWindowAccess {
    var processID: Int32 = 42
    var frame = CGRect(x: 200, y: 200, width: 400, height: 300)
    var eligible = true, readable = true, writesOK = true
    var writes: [String] = []
    var afterSize: (() -> Void)?
    func isEligibleAndActive() -> Bool { eligible }
    func readFrame() -> CGRect? { readable ? frame : nil }
    func setSize(_ value: CGSize) -> Bool {
        writes.append("size"); if writesOK { frame.size = value }; afterSize?(); return writesOK
    }
    func setPosition(_ value: CGPoint) -> Bool { writes.append("position"); if writesOK { frame.origin = value }; return writesOK }
}
private final class Rig {
    var jobs: [(Double, () -> Void)] = [], previews: [() -> Void] = []
    var time = 0.0
    var shown: [CGRect?] = []
    var window = Window(), other = Window()
    var resolution: (() -> Void)?
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
        screens: [(CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 0, y: 24, width: 1000, height: 776))], activePID: 42)
    init() { monitor.onInteraction = { true } }
    func send(_ type: CGEventType, _ x: CGFloat = 300, _ y: CGFloat = 220) {
        monitor.capture(type, point: CGPoint(x: x, y: y), targetPID: 42, handlingWindowID: 99)
    }
    func runOne() {
        precondition(!jobs.isEmpty); let job = jobs.removeFirst(); time = max(time + 0.000001, job.0); job.1()
    }
    func run() { var count = 0; while !jobs.isEmpty { count += 1; precondition(count < 100); runOne() } }
    func flushPreview() { let callbacks = previews; previews = []; callbacks.forEach { $0() } }
    func moveTop() { window.frame.origin.y = 24; send(.leftMouseDragged, 300, 44) }
    var diagnostics: WindowSnapDiagnostics { monitor.diagnostics.latestInteraction }
}
@main enum Checks {
    static func main() {
        var count = 0
        func check(_ label: String, _ body: (Rig) -> Void) {
            let rig = Rig(); body(rig); count += 1; print("PASS \(label)")
        }
        check("delayed lookup, coalesced release, first upward drag and clamped titlebar") { r in
            r.send(.leftMouseDown)
            r.resolution = { r.moveTop(); r.send(.leftMouseUp, 300, 44) }
            r.run(); r.flushPreview()
            precondition(r.window.writes == ["size", "position"])
            precondition(r.window.frame == CGRect(x: 0, y: 24, width: 1000, height: 776))
            precondition(r.other.writes.isEmpty && r.routes.first!.0 == 42 && r.routes.first!.1 == 99)
            precondition(r.diagnostics.completed && r.diagnostics.commitSucceeded == true)
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
            r.run(); precondition(r.routes.count == 2 && r.window.writes == ["size", "position"])
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
            precondition(r.window.writes == ["size"] && r.diagnostics.commitSucceeded == false)
        }
        check("cancel during commit prevents subsequent position write") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run(); r.window.afterSize = { r.monitor.cancel() }
            r.send(.leftMouseUp, 300, 44); r.run(); precondition(r.window.writes == ["size"])
        }
        check("drag coalescing and delayed throttle retain latest release") { r in
            r.send(.leftMouseDown); r.run(); r.moveTop(); r.run()
            for _ in 0..<50 { r.send(.leftMouseDragged, 300, 44) }
            r.runOne(); r.send(.leftMouseUp, 300, 44); r.run()
            precondition(r.window.writes == ["size", "position"] && r.diagnostics.processedDragCount <= 2)
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
        print("Window snapping production pipeline: \(count) checks passed")
    }
}
