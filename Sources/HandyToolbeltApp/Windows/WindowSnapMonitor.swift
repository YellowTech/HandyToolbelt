import AppKit
import ApplicationServices
import SwiftUI
import HandyToolbeltCore

/// The tap only captures input. All Accessibility IPC is serialized and coalesced off the main thread.
final class WindowSnapMonitor {
    private struct Input {
        var type: CGEventType
        var point: CGPoint
        var generation: UInt64
        var eventTargetPID: Int32?
        var handlingWindowID: UInt32?
        var underPointerWindowID: UInt32?
    }
    private struct Drag { var access: WindowSnapWindowAccess; var pid: pid_t; var movement: WindowSnapDrag; var generation: UInt64 }
    /// Injectable native boundaries. The harness drives the production receive/drain/begin/process path.
    struct Boundary {
        var scheduleWorker: (TimeInterval, @escaping () -> Void) -> Void
        var schedulePreview: (@escaping () -> Void) -> Void
        var now: () -> TimeInterval
        var resolve: (CGPoint, Int32?, UInt32?) -> Resolution?
        var preview: (CGRect?) -> Void
    }
    struct Resolution {
        var access: WindowSnapWindowAccess
        var frame: CGRect
        var earlierFrame: CGRect?
    }
    private var boundary: Boundary?
    init() {}
    init(boundary: Boundary, screens: [(CGRect, CGRect)], activePID: Int32) {
        self.boundary = boundary; self.screens = screens; self.activePID = activePID; enabled = true
    }
    private func schedule(_ delay: TimeInterval = 0, _ work: @escaping () -> Void) {
        if let boundary { boundary.scheduleWorker(delay, work) }
        else if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: work) }
        else { queue.async(execute: work) }
    }
    private let queue = DispatchQueue(label: "HandyToolbelt.window-snapping", qos: .userInitiated)
    private let lock = NSLock()
    private var session = WindowSnapSession()
    typealias Diagnostics = WindowSnapDiagnosticsSnapshot
    private var lastInteraction = WindowSnapDiagnostics()
    private var diagnosticSnapshot = Diagnostics()
    var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        var result = diagnosticSnapshot
        result.latestInteraction = lastInteraction
        return result
    }
    /// Must hold lock. Only dragged interactions enter the bounded history.
    private func finishInteractionLocked(stage: String? = nil, reason: String? = nil) {
        guard lastInteraction.mouseDownCount > 0, !lastInteraction.completed else { return }
        if let stage { lastInteraction.stage = stage }
        if let reason { lastInteraction.reason = reason }
        trace("interaction_finished", ["generation": String(lastInteraction.generation), "stage": lastInteraction.stage,
            "reason": lastInteraction.reason ?? "none"])
        lastInteraction.completed = true
        diagnosticSnapshot.recordCompletedDrag(lastInteraction)
    }
    private func record(_ token: UInt64, _ update: (inout WindowSnapDiagnostics) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard lastInteraction.generation == token, !lastInteraction.completed else { return }
        update(&lastInteraction)
    }
    /// Fields are evaluated only while recording. Coordinates are global logical points.
    private func trace(_ event: String, _ fields: @autoclosure () -> [String: String]) {
        guard DebugEventRecorder.shared.isEnabled else { return }
        DebugEventRecorder.shared.record(category: .snapping, event: event, fields: fields())
    }
    private static func rectText(_ frame: CGRect) -> String {
        "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
    }
    private func reject(_ token: UInt64, _ reason: String) {
        trace("rejected", ["generation": String(token), "reason": reason])
        record(token) { $0.stage = "rejected"; $0.reason = reason }
    }
    private func axReporter(_ token: UInt64) -> (String, AXError) -> Void {
        { [weak self] operation, error in
            self?.record(token) { $0.axResults[operation] = error.rawValue }
            if error != .success || operation == "set_size" || operation == "set_position" {
                self?.trace("ax_result", ["generation": String(token), "operation": operation, "code": String(error.rawValue)])
            }
        }
    }
    private var pending: Input?
    private var scheduled = false
    private var resolvingGeneration: UInt64?
    private var lastMotionTime = -Double.infinity
    private var activePID: pid_t?
    private var enabled = false
    private var screens: [(CGRect, CGRect)] = []
    private var drag: Drag? // worker only
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var preview: NSPanel?
    var onInteraction: (() -> Bool)?
    var onUnavailable: (() -> Void)?

    func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard tap == nil else { return true }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            trace("monitor_availability", ["available": "false", "reason": "tap_creation_failed"])
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.lock(); enabled = true; activePID = frontmostPID; lock.unlock()
        updateScreens()
        CGEvent.tapEnable(tap: port, enable: true)
        trace("monitor_availability", ["available": "true", "reason": "started"])
        return true
    }
    func updateScreens() {
        dispatchPrecondition(condition: .onQueue(.main))
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let captured = NSScreen.screens.map { (WindowSnapping.cgRect($0.frame, primaryTop: primaryTop), WindowSnapping.cgRect($0.visibleFrame, primaryTop: primaryTop)) }
        if DebugEventRecorder.shared.isEnabled {
            for (index, screen) in NSScreen.screens.enumerated() {
                trace("display", ["index": String(index), "coordinate_space": "cg_ax_global_points", "primary_top": String(Double(primaryTop)),
                    "scale": String(Double(screen.backingScaleFactor)), "frame": Self.rectText(captured[index].0), "visible": Self.rectText(captured[index].1)])
            }
        }
        lock.lock()
        screens = captured
        lock.unlock()
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        finishInteractionLocked(stage: "cancelled", reason: "session_cancelled")
        session.invalidate(); pending = nil; resolvingGeneration = nil; lock.unlock()
        if let boundary { boundary.preview(nil) } else { preview?.orderOut(nil) }
    }
    func applicationActivated(_ pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        trace("activation", ["pid": String(pid), "generation": String(session.generation)])
        activePID = pid
        let mismatched = session.activated(pid: pid)
        if mismatched {
            pending = nil
            finishInteractionLocked(stage: "cancelled", reason: "different_app_activated")
        }
        lock.unlock()
        if mismatched {
            if let boundary { boundary.preview(nil) } else { preview?.orderOut(nil) }
        }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        lock.lock(); let wasEnabled = enabled; enabled = false; lock.unlock()
        if wasEnabled { trace("monitor_availability", ["available": "false", "reason": "stopped"]) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; preview?.orderOut(nil); preview = nil
    }
    private static let callback: CGEventTapCallBack = { _, type, event, context in
        if let context { Unmanaged<WindowSnapMonitor>.fromOpaque(context).takeUnretainedValue().receive(type, event) }
        return Unmanaged.passUnretained(event)
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        dispatchPrecondition(condition: .onQueue(.main))
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            trace("monitor_availability", ["available": "false", "reason": type == .tapDisabledByTimeout ? "tap_timeout" : "tap_disabled_by_input"])
            stop(); onUnavailable?(); return
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { cancel() }
            return
        }
        // Read only routing metadata and pointer coordinates; never record event content.
        let rawTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let rawHandlingWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let rawUnderPointerWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        capture(type, point: event.location,
            targetPID: rawTargetPID > 0 ? Int32(exactly: rawTargetPID) : nil,
            handlingWindowID: rawHandlingWindow > 0 ? UInt32(exactly: rawHandlingWindow) : nil,
            underPointerWindowID: rawUnderPointerWindow > 0 ? UInt32(exactly: rawUnderPointerWindow) : nil)
    }
    /// Captures immutable event metadata; no event posting or native objects are needed by checks.
    func capture(_ type: CGEventType, point: CGPoint, targetPID: Int32? = nil,
                 handlingWindowID: UInt32? = nil, underPointerWindowID: UInt32? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        if type == .leftMouseDown { diagnosticSnapshot.totalMouseDownCount += 1 }
        if type == .leftMouseDragged { diagnosticSnapshot.totalMouseDragCount += 1 }
        if type == .leftMouseUp { diagnosticSnapshot.totalMouseUpCount += 1 }
        lock.unlock()
        guard onInteraction?() == true else { cancel(); return }
        if type == .leftMouseDown { cancel(); if boundary == nil { updateScreens() } }
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let input = Input(type: type, point: point, generation: session.generation,
            eventTargetPID: targetPID, handlingWindowID: handlingWindowID, underPointerWindowID: underPointerWindowID)
        if type == .leftMouseDown || type == .leftMouseUp {
            trace(type == .leftMouseDown ? "pointer_down" : "pointer_up", ["generation": String(input.generation),
                "x": String(Double(point.x)), "y": String(Double(point.y)), "pid": targetPID.map(String.init) ?? "none",
                "handling_window": handlingWindowID.map(String.init) ?? "none", "pointer_window": underPointerWindowID.map(String.init) ?? "none"])
        }
        if type == .leftMouseDown {
            lastInteraction = WindowSnapDiagnostics()
            lastInteraction.generation = input.generation
            lastInteraction.stage = "mouse_down"
            lastInteraction.mouseDownCount = 1
            lastInteraction.eventTargetPID = input.eventTargetPID
            lastInteraction.eventHandlingWindowID = input.handlingWindowID
            lastInteraction.eventUnderPointerWindowID = input.underPointerWindowID
            resolvingGeneration = input.generation
            // Down establishes identity before any coalesced motion can run.
            schedule { [weak self] in self?.begin(input) }
        } else {
            if lastInteraction.generation == input.generation {
                if type == .leftMouseDragged { lastInteraction.mouseDragCount += 1 }
                if type == .leftMouseUp { lastInteraction.mouseUpCount += 1 }
            }
            pending = input
        }
        if !scheduled || type == .leftMouseUp {
            scheduled = true
            schedule { [weak self] in self?.drain() }
        }
        lock.unlock()
    }
    private func valid(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return enabled && session.isCurrent(token)
    }
    private func drain() {
        while true {
            lock.lock()
            guard let input = pending else { scheduled = false; lock.unlock(); return }
            // An older drain must not consume a newer generation's up before its queued down resolves.
            guard resolvingGeneration != input.generation else { scheduled = false; lock.unlock(); return }
            if input.type == .leftMouseDragged {
                let now = boundary?.now() ?? ProcessInfo.processInfo.systemUptime
                let delay = 1.0 / 30 - (now - lastMotionTime)
                if delay > 0 {
                    lock.unlock()
                    schedule(delay) { [weak self] in self?.drain() }
                    return
                }
                lastMotionTime = now
            }
            pending = nil; lock.unlock()
            process(input)
        }
    }
    private func begin(_ input: Input) {
        defer {
            lock.lock()
            if resolvingGeneration == input.generation { resolvingGeneration = nil }
            let shouldDrain = pending != nil
            if shouldDrain { scheduled = true }
            lock.unlock()
            if shouldDrain { drain() }
        }
        drag = nil
        guard valid(input.generation) else { return }
        let resolved: Resolution?
        if let boundary { resolved = boundary.resolve(input.point, input.eventTargetPID, input.handlingWindowID) }
        else { resolved = resolveNative(input) }
        guard valid(input.generation) else { return }
        guard let resolved else { if boundary != nil { reject(input.generation, "app_ax_hit_failed") }; return }
        trace("resolved", ["generation": String(input.generation), "pid": String(resolved.access.processID),
            "original": Self.rectText(resolved.frame), "earlier": resolved.earlierFrame.map(Self.rectText) ?? "none"])
        let pid = resolved.access.processID
        guard pid != ProcessInfo.processInfo.processIdentifier else { reject(input.generation, "own_process"); return }
        record(input.generation) { $0.stage = "tracking_move"; $0.resolved = true; $0.resolutionMethod = "app_hit"; $0.selectedPID = pid }
        lock.lock()
        guard enabled, session.isCurrent(input.generation) else { lock.unlock(); return }
        session.resolve(pid: pid, token: input.generation)
        lock.unlock()
        drag = Drag(access: resolved.access, pid: pid,
            movement: WindowSnapDrag(initial: resolved.frame, down: input.point, earlierFrame: resolved.earlierFrame), generation: input.generation)
    }
    private func resolveNative(_ input: Input) -> Resolution? {
        record(input.generation) { $0.stage = "selecting_process" }
        // WindowServer metadata cannot invoke our in-process SwiftUI AX provider.
        // Prefer the event's actual handling window; only absent routing metadata uses
        // the conservative first-containing-surface fallback. Never query our own AX tree.
        guard let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { reject(input.generation, "window_metadata_unavailable"); return nil }
        let candidates = descriptions.compactMap { description -> WindowSnapCandidate? in
            guard let bounds = description[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let pid = description[kCGWindowOwnerPID as String] as? Int32,
                  let layer = description[kCGWindowLayer as String] as? Int,
                  let alpha = description[kCGWindowAlpha as String] as? Double else { return nil }
            return WindowSnapCandidate(processID: pid, frame: frame, layer: layer, alpha: alpha,
                windowID: (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value)
        }
        let firstSurface = candidates.first { $0.alpha > 0 && $0.frame.contains(input.point) }
        record(input.generation) { $0.firstContainingLayer = firstSurface?.layer; $0.firstContainingPID = firstSurface?.processID }
        let selection = WindowSnapping.selectWindow(at: input.point, candidates: candidates,
            ownPID: ProcessInfo.processInfo.processIdentifier, handlingWindowID: input.handlingWindowID,
            eventTargetPID: input.eventTargetPID)
        trace("routing", ["generation": String(input.generation), "method": selection.method, "reason": selection.rejection ?? "none",
            "pid": selection.candidate.map { String($0.processID) } ?? "none"])
        record(input.generation) { $0.routingMethod = selection.method }
        guard let pid = selection.candidate?.processID else {
            reject(input.generation, selection.rejection ?? "identity_not_resolved"); return nil
        }
        guard valid(input.generation) else { return nil }
        record(input.generation) { $0.stage = "resolving_ax"; $0.selectedPID = pid }
        let reportAX = axReporter(input.generation)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.12)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(application, Float(input.point.x), Float(input.point.y), &hit)
        trace("ax_hit", ["generation": String(input.generation), "code": String(hitError.rawValue)])
        record(input.generation) { $0.axHitError = hitError.rawValue }
        guard hitError == .success, let hit, valid(input.generation) else { reject(input.generation, "app_ax_hit_failed"); return nil }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else { reject(input.generation, "ax_hit_pid_mismatch"); return nil }
        AXUIElementSetMessagingTimeout(hit, 0.12)
        let window: AXUIElement
        if AXWindowAccess.string(hit, kAXRoleAttribute, result: reportAX) == kAXWindowRole { window = hit }
        else if let candidate = AXWindowAccess.attribute(hit, kAXWindowAttribute, result: reportAX), CFGetTypeID(candidate) == AXUIElementGetTypeID() { window = unsafeBitCast(candidate, to: AXUIElement.self) }
        else { reject(input.generation, "ax_window_unavailable"); return nil }
        AXUIElementSetMessagingTimeout(window, 0.12)
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { reject(input.generation, "ax_window_pid_mismatch"); return nil }
        guard AXWindowAccess.eligible(window, result: reportAX) else { reject(input.generation, "ax_window_ineligible"); return nil }
        guard let frame = AXWindowAccess.frame(window, result: reportAX) else { reject(input.generation, "ax_frame_unavailable"); return nil }
        guard valid(input.generation) else { return nil }
        let earlierFrame = input.handlingWindowID != nil && input.handlingWindowID != 0
            && selection.candidate?.windowID == input.handlingWindowID ? selection.candidate?.frame : nil
        let access = AXWindowAccess(window: window, processID: pid, result: reportAX) { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.activePID == pid
        }
        return Resolution(access: access, frame: frame, earlierFrame: earlierFrame)
    }
    private func process(_ input: Input) {
        guard valid(input.generation) else { return }
        if input.type == .leftMouseDragged { record(input.generation) { $0.processedDragCount += 1 } }
        var applicationPending = false
        defer {
            if input.type == .leftMouseUp && !applicationPending {
                record(input.generation) { value in
                    if value.reason == nil && value.commitSucceeded == nil {
                        value.reason = value.resolved ? (value.movementConfirmed ? "no_edge_target" : "movement_not_proven") : "identity_not_resolved"
                    }
                    if value.stage != "rejected" && value.stage != "cancelled" { value.stage = "finished" }
                }
                lock.lock()
                if lastInteraction.generation == input.generation { finishInteractionLocked() }
                lock.unlock()
            }
        }
        guard var drag, drag.generation == input.generation else { return }
        let access = drag.access
        guard access.isEligibleAndActive() else {
            reject(input.generation, "target_inactive_or_ineligible"); self.drag = nil; show(nil, token: input.generation); return
        }
        guard let current = access.readFrame() else {
            reject(input.generation, "tracking_frame_unavailable"); self.drag = nil; show(nil, token: input.generation); return
        }
        lock.lock(); let displays = screens; lock.unlock()
        let display = displays.first { $0.0.contains(input.point) }
        let confirmed = drag.movement.observe(frame: current, pointer: input.point, topBoundary: display?.1.minY)
        trace("movement", ["generation": String(input.generation), "x": String(Double(input.point.x)), "y": String(Double(input.point.y)),
            "current": Self.rectText(current), "confirmed": String(confirmed), "invalidated": String(drag.movement.invalidated),
            "display": display.map { Self.rectText($0.0) } ?? "none", "visible": display.map { Self.rectText($0.1) } ?? "none"])
        self.drag = drag.movement.invalidated ? nil : drag
        if drag.movement.invalidated { reject(input.generation, "window_resized") }
        if confirmed { record(input.generation) { $0.movementConfirmed = true; $0.stage = "move_confirmed" } }
        guard confirmed else {
            show(nil, token: input.generation)
            if input.type == .leftMouseUp { self.drag = nil }
            return
        }
        let target = display.flatMap { drag.movement.target(pointer: input.point, screen: $0.0, visible: $0.1) }
        trace("target", ["generation": String(input.generation), "requested": target.map(Self.rectText) ?? "none"])
        if target != nil { record(input.generation) { $0.targetFound = true; $0.stage = "edge_target" } }
        if input.type == .leftMouseUp {
            self.drag = nil; show(nil, token: input.generation)
            guard let target else { return }
            // The listen-only tap sees up before the owner necessarily handles it. Give
            // native dragging time to end, then verify spaced readbacks and repair rollback.
            applicationPending = true
            record(input.generation) { $0.stage = "applying" }
            schedule(0.06) { [weak self] in
                self?.apply(WindowSnapApplication(target: target), access: access, token: input.generation)
            }
        } else { show(target, token: input.generation) }
    }
    private func apply(_ application: WindowSnapApplication, access: WindowSnapWindowAccess, token: UInt64) {
        guard valid(token) else { return }
        var application = application
        trace("commit_advance", ["generation": String(token), "attempts": String(application.attempts), "requested": Self.rectText(application.target)])
        let result = application.advance(window: access, diagnostic: { [weak self] stage, frame in
            self?.trace("commit_observation", ["generation": String(token), "stage": stage, "frame": frame.map(Self.rectText) ?? "none"])
        }, isCurrent: { self.valid(token) })
        guard valid(token) else { return }
        switch result {
        case .pending:
            schedule(0.10) { [weak self] in self?.apply(application, access: access, token: token) }
        case .succeeded, .failed:
            let succeeded: Bool
            if case .succeeded = result { succeeded = true } else { succeeded = false }
            trace("commit_finished", ["generation": String(token), "succeeded": String(succeeded), "attempts": String(application.attempts)])
            record(token) { $0.commitSucceeded = succeeded; $0.reason = succeeded ? nil : "commit_not_stable"; $0.stage = "finished" }
            lock.lock()
            if lastInteraction.generation == token { finishInteractionLocked() }
            lock.unlock()
        }
    }
    private final class AXWindowAccess: WindowSnapWindowAccess {
        let window: AXUIElement
        let processID: Int32
        let isActive: () -> Bool
        let result: (String, AXError) -> Void
        init(window: AXUIElement, processID: Int32, result: @escaping (String, AXError) -> Void, isActive: @escaping () -> Bool) {
            self.window = window; self.processID = processID; self.result = result; self.isActive = isActive
        }
        func isEligibleAndActive() -> Bool {
            AXIsProcessTrusted() && isActive() && Self.eligible(window, result: result)
        }
        func readFrame() -> CGRect? { Self.frame(window, result: result) }
        func setSize(_ value: CGSize) -> Bool {
            var size = value
            guard let ax = AXValueCreate(.cgSize, &size) else { return false }
            let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, ax)
            result("set_size", error)
            return error == .success
        }
        func setPosition(_ value: CGPoint) -> Bool {
            var point = value
            guard let ax = AXValueCreate(.cgPoint, &point) else { return false }
            let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, ax)
            result("set_position", error)
            return error == .success
        }
        static func eligible(_ window: AXUIElement, result: (String, AXError) -> Void) -> Bool {
            guard string(window, kAXSubroleAttribute, result: result) == kAXStandardWindowSubrole,
                  (attribute(window, kAXMinimizedAttribute, result: result) as? Bool) == false,
                  (attribute(window, "AXFullScreen", result: result) as? Bool) != true else { return false }
            var position: DarwinBoolean = false, size: DarwinBoolean = false
            let positionError = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &position)
            result("position_settable", positionError)
            guard positionError == .success, position.boolValue else { return false }
            let sizeError = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &size)
            result("size_settable", sizeError)
            return sizeError == .success && size.boolValue
        }
        static func attribute(_ element: AXUIElement, _ key: String, result: (String, AXError) -> Void) -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            result(key, error)
            return error == .success ? value : nil
        }
        static func string(_ element: AXUIElement, _ key: String, result: (String, AXError) -> Void) -> String? {
            attribute(element, key, result: result) as? String
        }
        static func frame(_ element: AXUIElement, result: (String, AXError) -> Void) -> CGRect? {
            guard let p = attribute(element, kAXPositionAttribute, result: result), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = attribute(element, kAXSizeAttribute, result: result), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: point, size: size)
        }
    }
    private func show(_ rect: CGRect?, token: UInt64) {
        let work = { [weak self] in
            guard let self, self.valid(token) else { return }
            if let boundary = self.boundary { boundary.preview(rect); return }
            guard let rect else { self.preview?.orderOut(nil); return }
            if self.preview == nil {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                panel.ignoresMouseEvents = true; panel.level = .floating; panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.contentView = NSHostingView(rootView: RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.10)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 2)).padding(4))
                self.preview = panel
            }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            self.preview?.setFrame(WindowSnapping.cgRect(rect, primaryTop: top), display: true)
            self.preview?.orderFrontRegardless()
        }
        if let boundary { boundary.schedulePreview(work) } else { DispatchQueue.main.async(execute: work) }
    }
}
