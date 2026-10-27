import AppKit
import HandyToolbeltCore

@main struct GestureStackRuntimeChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }
    static func main() throws {
        var events: [(CGKeyCode, Bool, CGEventFlags, Bool)] = []
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { events.append(($0, $1, $2, $3)) })
        try keyboard.hold([.option])
        try keyboard.press(Shortcut(keyCode: 48, modifiers: 0, keyLabel: "Tab"))
        try keyboard.press(Shortcut(keyCode: 48, modifiers: KeyboardModifier.shift.flag, keyLabel: "Tab"))
        check(events.count == 5, "Option down precedes two complete keypresses")
        check(events[0].0 == 58 && events[0].1 && events[1].0 == 48, "Ordered Option then Tab")
        check(events[1].2.contains(.maskAlternate), "Held Option remains in Tab flags")
        check(events[3].2.contains([.maskAlternate, .maskShift]), "Temporary Shift merges held Option")
        check(keyboard.physicalModifiers.isEmpty, "Synthetic holds never enter physical modifier matching")
        keyboard.releaseAll(); keyboard.releaseAll()
        check(events.count == 6 && !events[5].1 && events[5].0 == 58, "Release emits Option up exactly once")
        var physicalEvents = 0
        let physical = StackKeyboardDriver(physicalModifiers: [.option], emit: { _, _, _, _ in physicalEvents += 1 })
        try physical.hold([.option]); physical.releaseAll()
        check(physicalEvents == 0, "Physically held Option is never released")

        var transitionEvents: [(CGKeyCode, Bool, CGEventFlags)] = []
        let transitions = StackKeyboardDriver(physicalModifiers: [.option], emit: { key, down, flags, _ in transitionEvents.append((key, down, flags)) })
        try transitions.hold([.option])
        let deliveredRelease = transitions.physicalTransition(key: 58, flags: [])
        check(transitions.physicalModifiers.isEmpty && deliveredRelease.contains(.maskAlternate), "Physical Option release updates detection but retains stack hold in delivered event")
        try transitions.press(Shortcut(keyCode: 48, modifiers: 0, keyLabel: "Tab"))
        check(transitionEvents[0].2.contains(.maskAlternate), "Child after physical Option release still holds Option")
        _ = transitions.physicalTransition(key: 58, flags: .maskAlternate)
        let beforePhysicalEnd = transitionEvents.count
        transitions.releaseAll()
        check(transitionEvents.count == beforePhysicalEnd && transitions.physicalModifiers == [.option], "Ending while physical Option is newly down preserves physical key")
        var postAttempts: [Bool] = []
        let failing = StackKeyboardDriver(physicalModifiers: [], emit: { _, down, _, _ in
            postAttempts.append(down)
            if postAttempts.count == 2 { throw ActionExecutor.ActionError.message("Transient key-up failure") }
        })
        do { try failing.press(Shortcut(keyCode: 48, modifiers: 0, keyLabel: "Tab")); check(false, "Expected key-up failure") } catch {}
        check(postAttempts == [true, false, false], "Failed key-up is retried before reporting action failure")
        failing.releaseAll()
        check(postAttempts.count == 3, "Successful cleanup prevents duplicate key release")

        var callbacks: [GestureStackRuntime.Completion] = []
        var ordinary: [String] = []
        var releaseCount = 0
        let runtime = GestureStackRuntime(keyboard: keyboard)
        runtime.execute = { action, complete in ordinary.append(action.text); callbacks.append(complete) }
        runtime.onEnd = { releaseCount += 1 }
        let held = GestureStackAction(kind: .holdModifiers, modifiers: [.option])
        let blocked = GestureAction(kind: .showText, text: "Blocked")
        let release = GestureAction(kind: .showText, text: "Released")
        let value = GestureStack(name: "Test", corner: .topLeft, startActions: [held, .init(action: blocked), held], releaseActions: [release])
        runtime.begin(value, deviceID: 1, fingerID: 10, time: 1, tuning: .init(), aspect: 1.6)
        check(ordinary == ["Blocked"], "Start order waits for async callback")
        runtime.frame(deviceID: 2, contacts: [], time: 1.1, cornerSize: 0.22, pressed: false)
        check(runtime.stack != nil, "Other device cannot end owning stack")
        runtime.frame(deviceID: 1, contacts: [], time: 1.2, cornerSize: 0.22, pressed: false)
        check(runtime.stack == nil && releaseCount == 1 && ordinary == ["Blocked", "Released"], "Corner lift releases immediately despite blocked action")
        let eventCount = events.count
        callbacks[0](.success("Late")); runtime.end()
        check(events.count == eventCount && releaseCount == 1, "Late completion cannot re-hold; repeated end is idempotent")
        check(!events.last!.1, "Held key release precedes ordinary release callback")
        runtime.begin(value, deviceID: 1, fingerID: 10, time: 2, tuning: .init(), aspect: 1.6)
        callbacks[2](.failure(ActionExecutor.ActionError.message("Failed")))
        check(runtime.stack == nil && releaseCount == 2, "Start failure uses same release path")
        runtime.begin(value, deviceID: 1, fingerID: 10, time: 3, tuning: .init(), aspect: 1.6)
        runtime.frame(deviceID: 1, contacts: [.init(id: 10, x: .nan, y: 1)], time: 3.1, cornerSize: 0.22, pressed: false)
        check(runtime.stack == nil && releaseCount == 3, "Invalid contact uses same release path")
        runtime.begin(value, deviceID: 1, fingerID: 10, time: 4, tuning: .init(), aspect: 1.6)
        runtime.frame(deviceID: 1, contacts: [.init(id: 10, x: 0.5, y: 0.5)], time: 4.1, cornerSize: 0.22, pressed: false)
        check(runtime.stack == nil && releaseCount == 4, "Corner move uses same release path")
        runtime.begin(value, deviceID: 1, fingerID: 10, time: 5, tuning: .init(), aspect: 1.6)
        runtime.end()
        check(runtime.stack == nil && releaseCount == 5, "Disconnect/stop entry point uses same release path")
        let tab = GestureAction(kind: .shortcut, shortcut: .init(keyCode: 48, modifiers: 0, keyLabel: "Tab"))
        let child = GestureStackBinding(gesture: .init(kind: .tap, fingers: 1), keyboardModifiers: .init(mode: .exact, modifiers: []), actions: [tab])
        let children = GestureStack(name: "Children", corner: .topLeft, startActions: [held], bindings: [child])
        runtime.begin(children, deviceID: 1, fingerID: 10, time: 6, tuning: .init(), aspect: 1.6)
        let owner = Contact(id: 10, x: 0.05, y: 0.95)
        runtime.frame(deviceID: 1, contacts: [owner], time: 6.01, cornerSize: 0.22, pressed: false)
        let beforeChild = events.count
        runtime.frame(deviceID: 1, contacts: [owner, .init(id: 11, x: 0.5, y: 0.5)], time: 6.1, cornerSize: 0.22, pressed: false)
        runtime.frame(deviceID: 1, contacts: [owner], time: 6.2, cornerSize: 0.22, pressed: false)
        check(events.count == beforeChild + 2, "One-finger stack child works with reserved corner and physical exact-none requirement")
        check(events[beforeChild].2.contains(.maskAlternate), "Child keypress retains held Option")
        runtime.end()
        let clickChild = GestureStackBinding(gesture: .init(kind: .click, fingers: 1), actions: [tab])
        let clickStack = GestureStack(name: "Click", corner: .topLeft, bindings: [clickChild])
        runtime.begin(clickStack, deviceID: 1, fingerID: 10, time: 7, tuning: .init(), aspect: 1.6)
        runtime.frame(deviceID: 1, contacts: [owner], time: 7.01, cornerSize: 0.22, pressed: false)
        check(!runtime.click(at: 7.02), "Unmatched click remains native passthrough")
        runtime.frame(deviceID: 1, contacts: [owner, .init(id: 11, x: 0.5, y: 0.5)], time: 7.1, cornerSize: 0.22, pressed: false)
        check(runtime.click(at: 7.2), "Matched stack click reports native click consumption")
        runtime.end()
        let forceChild = GestureStackBinding(gesture: .init(kind: .forceClick, fingers: 1), actions: [.init(kind: .showText, text: "force")])
        let normalChild = GestureStackBinding(gesture: .init(kind: .click, fingers: 1), actions: [.init(kind: .showText, text: "normal")])
        let forceStack = GestureStack(name: "Native press", corner: .topLeft, bindings: [normalChild, forceChild])
        let forceRuntime = GestureStackRuntime(keyboard: keyboard)
        var pressActions: [String] = []
        forceRuntime.execute = { action, complete in pressActions.append(action.text); complete(.success("done")) }
        func beginPress(_ time: Double) {
            forceRuntime.begin(forceStack, deviceID: 1, fingerID: 10, time: time, tuning: .init(), aspect: 1.6)
            forceRuntime.frame(deviceID: 1, contacts: [owner], time: time + 0.01, cornerSize: 0.22, pressed: false)
            forceRuntime.frame(deviceID: 1, contacts: [owner, .init(id: 11, x: 0.5, y: 0.5)], time: time + 0.05, cornerSize: 0.22, pressed: false)
            check(!forceRuntime.click(at: time + 0.06, supportsForce: true), "Force-enabled stack down stays native")
        }
        beginPress(10)
        check(pressActions.isEmpty, "Stack normal waits for release")
        check(!forceRuntime.click(at: 10.15, primary: false, supportsForce: true), "Secondary down cannot participate in pending primary press")
        forceRuntime.pressure(stage: 2, at: 10.07); forceRuntime.pressure(stage: 1, at: 10.08); forceRuntime.pressure(stage: 2, at: 10.09)
        forceRuntime.release(at: 10.10); forceRuntime.finishPresses(at: 10.15)
        check(pressActions == ["force"], "Stack force fires once, excluding ordinary click")
        forceRuntime.end(); pressActions = []
        beginPress(11)
        forceRuntime.frame(deviceID: 1, contacts: [owner], time: 11.08, cornerSize: 0.22, pressed: false)
        forceRuntime.release(at: 11.09); forceRuntime.finishPresses(at: 11.14)
        check(pressActions == ["normal"], "Stack free-finger lift preserves normal release")
        forceRuntime.end(); pressActions = []
        beginPress(12)
        forceRuntime.release(at: 12.09); forceRuntime.pressure(stage: 2, at: 12.08); forceRuntime.finishPresses(at: 12.14)
        check(pressActions == ["force"], "Stack release grace accepts reordered stage2")
        forceRuntime.end(); pressActions = []
        beginPress(13); forceRuntime.end(); forceRuntime.release(at: 13.09); forceRuntime.finishPresses(at: 13.14)
        check(pressActions.isEmpty, "Stack ending clears pending ordinary fallback")
        beginPress(14)
        _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
        forceRuntime.pressure(stage: 2, at: 14.08); forceRuntime.release(at: 14.09); forceRuntime.finishPresses(at: 14.14)
        check(pressActions.isEmpty, "Physical modifier mismatch never re-matches a stack press")
        forceRuntime.end(); _ = keyboard.physicalTransition(key: 55, flags: [])
        temporalChecks()
        anchoredTemporalChecks()
        print("Passed \(checks) gesture stack runtime checks")
    }
    static func temporalChecks() {
        let owner = Contact(id: 10, x: 0.05, y: 0.95)
        let free = Contact(id: 11, x: 0.45, y: 0.5)
        let replacement = Contact(id: 21, x: 0.46, y: 0.5)
        let tap = GestureStackBinding(gesture: .init(kind: .tap, fingers: 1), actions: [.init(kind: .showText, text: "single")])
        let double = GestureStackBinding(gesture: .init(kind: .doubleTap, fingers: 1), keyboardModifiers: .init(mode: .exact, modifiers: []), actions: [.init(kind: .showText, text: "double")])
        let long = GestureStackBinding(gesture: .init(kind: .longTouch, fingers: 1), actions: [.init(kind: .showText, text: "long")])
        let value = GestureStack(name: "Temporal", corner: .topLeft, bindings: [tap, double, long])
        var tuning = GestureTuning(); tuning.doubleTapInterval = 0.15
        var captures: [String] = []
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { _, _, _, _ in })
        let runtime = GestureStackRuntime(keyboard: keyboard)
        runtime.execute = { action, complete in captures.append(action.text); complete(.success("done")) }
        keyboard.onPhysicalModifiersChanged = { [weak runtime] in runtime?.cancelTemporalGestures() }
        func frame(_ contacts: [Contact], _ time: Double, pressed: Bool = false) {
            runtime.frame(deviceID: 1, contacts: contacts, time: time, cornerSize: tuning.cornerSize, pressed: pressed)
        }
        func begin(_ base: Double) {
            runtime.begin(value, deviceID: 1, fingerID: owner.id, time: base, tuning: tuning, aspect: 1.6)
            frame([owner], base + 0.01)
        }
        func firstTap(_ base: Double) {
            frame([owner, free], base + 0.03)
            frame([owner, free], base + 0.07)
            frame([owner], base + 0.09)
        }
        // Real uptime keeps the idle deadline test on the production dispatch path.
        let paired = ProcessInfo.processInfo.systemUptime
        begin(paired); firstTap(paired)
        check(captures.isEmpty, "Stack single is reserved while an applicable double waits")
        frame([owner, replacement], paired + 0.15)
        frame([owner, replacement], paired + 0.19)
        frame([owner], paired + 0.21)
        check(captures == ["double"], "Stack double accepts new IDs and excludes both single taps")
        runtime.end(); captures = []

        let held = ProcessInfo.processInfo.systemUptime
        begin(held)
        frame([owner, free], held + 0.03)
        frame([owner, free], held + 0.59)
        frame([owner, free], held + 0.65)
        check(captures == ["long"], "Stack long touch recognizes once while held")
        check(!runtime.click(at: held + 0.66), "Click after long touch cannot execute a child")
        frame([owner], held + 0.68)
        frame([owner, replacement], held + 0.72)
        frame([owner, replacement], held + 1.28)
        check(captures == ["long", "long"], "Stack free-finger lift rearms long touch under the same owner")
        runtime.end(); captures = []

        for cancellation in 0..<4 {
            let base = ProcessInfo.processInfo.systemUptime
            begin(base); firstTap(base)
            switch cancellation {
            case 0: frame([], base + 0.12)
            case 1: runtime.end()
            case 2:
                _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
                _ = keyboard.physicalTransition(key: 55, flags: [])
            default:
                // An OS down between taps must cancel, even without a bound click child.
                _ = runtime.click(at: base + 0.12)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.27))
            check(captures.isEmpty, "Stack deferred single cannot survive owner/end/modifier/click cancellation \(cancellation)")
            runtime.end()
        }

        let idle = ProcessInfo.processInfo.systemUptime
        begin(idle); firstTap(idle)
        RunLoop.main.run(until: Date().addingTimeInterval(0.28))
        check(captures == ["single"], "Stack deferred single fires once while input is idle")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(captures == ["single"], "An expired stack deadline never repeats")
        runtime.end(); captures = []

        // A frame delivered late uses its absolute uptime deadline, rather than
        // adding another complete interval from dispatch receipt.
        let queued = ProcessInfo.processInfo.systemUptime - 0.4
        begin(queued); firstTap(queued)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(captures == ["single"], "Queued stack input does not extend an already elapsed deadline")
        runtime.end()
    }

    static func anchoredTemporalChecks() {
        let owner = Contact(id: 10, x: 0.02, y: 0.98)
        let anchor = Contact(id: 11, x: 0.5, y: 0.5)
        let tapper = Contact(id: 12, x: 0.7, y: 0.5)
        let single = GestureStackBinding(gesture: .init(kind: .tipTapRight), actions: [.init(kind: .showText, text: "tip")])
        let double = GestureStackBinding(gesture: .init(kind: .doubleTipTapRight), actions: [.init(kind: .showText, text: "double tip")])
        let value = GestureStack(name: "Anchored temporal", corner: .topLeft, bindings: [single, double])
        var tuning = GestureTuning(); tuning.doubleTapInterval = 0.15
        var captures: [String] = []
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { _, _, _, _ in })
        let runtime = GestureStackRuntime(keyboard: keyboard)
        runtime.execute = { action, complete in captures.append(action.text); complete(.success("done")) }
        keyboard.onPhysicalModifiersChanged = { [weak runtime] in runtime?.cancelTemporalGestures() }
        func frame(_ contacts: [Contact], _ time: Double) {
            runtime.frame(deviceID: 1, contacts: contacts, time: time, cornerSize: tuning.cornerSize, pressed: false)
        }
        func firstTip(_ base: Double, stack: GestureStack = value, resting: Contact = anchor, acting: Contact = tapper) {
            runtime.begin(stack, deviceID: 1, fingerID: owner.id, time: base, tuning: tuning, aspect: 1.6)
            frame([owner], base + 0.01)
            frame([owner, resting], base + 0.03)
            frame([owner, resting, acting], base + 0.21)
            frame([owner, resting], base + 0.27)
        }
        var base = ProcessInfo.processInfo.systemUptime
        firstTip(base)
        check(captures.isEmpty, "Stack double-tip child reserves its matching single under held corner")
        frame([owner, anchor, tapper], base + 0.34)
        frame([owner, anchor], base + 0.40)
        check(captures == ["double tip"], "Production stack double-tip child dispatches exactly once")
        runtime.end(); captures = []
        base = ProcessInfo.processInfo.systemUptime
        firstTip(base)
        RunLoop.main.run(until: Date().addingTimeInterval(0.47))
        check(captures == ["tip"], "Stack anchored single expires while corner and resting finger stay held")
        runtime.end(); captures = []
        for cancellation in 0..<4 {
            base = ProcessInfo.processInfo.systemUptime
            firstTip(base)
            switch cancellation {
            case 0: frame([owner], base + 0.30)
            case 1: runtime.end()
            case 2:
                _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
                _ = keyboard.physicalTransition(key: 55, flags: [])
            default: frame([anchor], base + 0.30)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.47))
            check(captures.isEmpty, "Stack anchored reservation cancels on anchor/end/modifier/corner loss \(cancellation)")
            runtime.end()
        }
        // Mouse contacts have different surface-edge semantics; the stack must
        // apply the same device policy as ordinary mappings.
        var mouse = value; mouse.device = .magicMouse; mouse.bindings = [single]
        let rimAnchor = Contact(id: 11, x: 0.02, y: 0.5)
        let rimTapper = Contact(id: 12, x: 0.22, y: 0.5)
        base = ProcessInfo.processInfo.systemUptime
        firstTip(base, stack: mouse, resting: rimAnchor, acting: rimTapper)
        check(captures == ["tip"], "Mouse stack does not inherit trackpad rim exclusion")
        runtime.end(); captures = []
        var trackpad = value; trackpad.bindings = [single]
        base = ProcessInfo.processInfo.systemUptime
        firstTip(base, stack: trackpad, resting: rimAnchor, acting: rimTapper)
        check(captures.isEmpty, "Trackpad stack keeps rim resting-finger exclusion")
        runtime.end()
    }

}
