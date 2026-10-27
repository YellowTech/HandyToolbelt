import AppKit
import ApplicationServices
import HandyToolbeltCore

protocol StackKeyboardDriving: AnyObject {
    var physicalModifiers: Set<KeyboardModifier> { get }
    func hold(_ modifiers: Set<KeyboardModifier>) throws
    func press(_ shortcut: Shortcut) throws
    func releaseAll()
}

/// Tracks hardware modifier transitions separately from the events this app emits.
final class StackKeyboardDriver: StackKeyboardDriving {
    static let eventMarker: Int64 = 0x5354535441434B
    private var held = Set<KeyboardModifier>()
    private var physical = Set<KeyboardModifier>()
    private var pressedKeys: [CGKeyCode: CGEventFlags] = [:]
    var onUnavailable: (() -> Void)?
    var onPhysicalModifiersChanged: (() -> Void)?
    private var emitOverride: ((CGKeyCode, Bool, CGEventFlags, Bool) throws -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private static let keys: [(KeyboardModifier, CGKeyCode, CGEventFlags)] = [
        (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift), (.command, 55, .maskCommand)]
    var physicalModifiers: Set<KeyboardModifier> { physical }
    init(physicalModifiers: Set<KeyboardModifier>, emit: @escaping (CGKeyCode, Bool, CGEventFlags, Bool) throws -> Void) {
        physical = physicalModifiers; emitOverride = emit
    }
    init() {}
    func startMonitoring() {
        guard tap == nil, emitOverride == nil else { return }
        physical.removeAll()
        let rightKeys: [CGKeyCode: CGKeyCode] = [59:62, 58:61, 56:60, 55:54]
        for (modifier, key, _) in StackKeyboardDriver.keys where CGEventSource.keyState(.hidSystemState, key: key) || CGEventSource.keyState(.hidSystemState, key: rightKeys[key]!) { physical.insert(modifier) }
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let driver = Unmanaged<StackKeyboardDriver>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    driver.onUnavailable?()
                    if let tap = driver.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if event.getIntegerValueField(.eventSourceUserData) != StackKeyboardDriver.eventMarker && event.getIntegerValueField(.eventSourceUserData) != ActionExecutor.eventMarker {
                    let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    event.flags = driver.physicalTransition(key: key, flags: event.flags)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    /// Hardware transitions update matching independently, while the delivered
    /// event retains stack-owned flags until the shared ending path releases them.
    @discardableResult func physicalTransition(key: CGKeyCode, flags incoming: CGEventFlags) -> CGEventFlags {
        let previous = physical
        let paired: [CGKeyCode: CGKeyCode] = [62:59, 61:58, 60:56, 54:55]
        if let (modifier, _, flag) = StackKeyboardDriver.keys.first(where: { $0.1 == (paired[key] ?? key) }) {
            if incoming.contains(flag) { physical.insert(modifier) } else { physical.remove(modifier) }
        }
        if physical != previous { onPhysicalModifiersChanged?() }
        return incoming.union(flags(held))
    }
    func stopMonitoring() {
        releaseAll()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; physical.removeAll()
    }
    deinit { stopMonitoring() }
    private func flags(_ modifiers: Set<KeyboardModifier>) -> CGEventFlags {
        StackKeyboardDriver.keys.reduce(CGEventFlags()) { result, entry in modifiers.contains(entry.0) ? result.union(entry.2) : result }
    }
    private func post(key: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool = false) throws {
        if let emitOverride { try emitOverride(key, down, flags, modifier); return }
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: key, keyDown: down) else {
            throw ActionExecutor.ActionError.message("Could not create a keyboard event.")
        }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: StackKeyboardDriver.eventMarker)
        event.post(tap: .cghidEventTap)
    }
    func hold(_ modifiers: Set<KeyboardModifier>) throws {
        guard emitOverride != nil || (AXIsProcessTrusted() && tap != nil) else { throw ActionExecutor.ActionError.message("Accessibility is needed to hold keyboard modifiers safely.") }
        for (modifier, key, _) in StackKeyboardDriver.keys where modifiers.contains(modifier) && !held.contains(modifier) {
            held.insert(modifier)
            if !physical.contains(modifier) { try post(key: key, down: true, flags: flags(held.union(physical)), modifier: true) }
        }
    }
    func press(_ shortcut: Shortcut) throws {
        let combined = flags(held.union(physical)).union(CGEventFlags(rawValue: shortcut.modifiers))
        try post(key: shortcut.keyCode, down: true, flags: combined)
        pressedKeys[shortcut.keyCode] = combined
        do {
            try post(key: shortcut.keyCode, down: false, flags: combined)
            pressedKeys.removeValue(forKey: shortcut.keyCode)
        } catch {
            // A failed key-up must not strand a non-modifier key. Retry here;
            // releaseAll also retries if the event source remains unavailable.
            if (try? post(key: shortcut.keyCode, down: false, flags: combined)) != nil { pressedKeys.removeValue(forKey: shortcut.keyCode) }
            throw error
        }
    }
    func releaseAll() {
        for (key, keyFlags) in pressedKeys { try? post(key: key, down: false, flags: keyFlags) }
        pressedKeys.removeAll()
        for (modifier, key, _) in StackKeyboardDriver.keys.reversed() where held.contains(modifier) {
            held.remove(modifier)
            if !physical.contains(modifier) { try? post(key: key, down: false, flags: flags(held.union(physical)), modifier: true) }
        }
    }
}

/// One global stack owns input until its corner finger ends. Ending invalidates all
/// queued continuations before releasing keys, even if an action never completes.
final class GestureStackRuntime {
    typealias Completion = (Result<String, Error>) -> Void
    let keyboard: StackKeyboardDriving
    private let temporalClock: () -> Double
    var execute: ((GestureAction, @escaping Completion) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var stack: GestureStack?
    private(set) var deviceID: UInt64?
    private(set) var fingerID: Int?
    private(set) var lastFrame: Double = 0
    private var generation = UUID()
    private var queue: [GestureStackAction] = []
    private var busy = false
    private var recognizer = GestureRecognizer()
    private var needsPrime = true
    private var temporalDeadline: DispatchWorkItem?
    private var temporalGeneration = UUID()
    func cancelTemporalGestures() {
        temporalGeneration = UUID()
        temporalDeadline?.cancel(); temporalDeadline = nil
        recognizer.cancelTemporalGestures()
    }
    private func scheduleTemporalDeadline(at time: Double) {
        temporalGeneration = UUID()
        temporalDeadline?.cancel(); temporalDeadline = nil
        guard let deadline = recognizer.nextDeadline else { return }
        let token = generation, temporalToken = temporalGeneration, modifiers = keyboard.physicalModifiers
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.temporalGeneration == temporalToken, self.stack != nil, self.keyboard.physicalModifiers == modifiers else { return }
            self.temporalDeadline = nil
            for var event in self.recognizer.advanceTime(to: deadline) { event.corner = .none; self.handle(event) }
        }
        temporalDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - temporalClock()), execute: work)
    }
    private struct PressSnapshot {
        var contacts: NativePressContacts
        let gesture: GestureSpec
        let modifiers: Set<KeyboardModifier>
        let generation: UUID
    }
    private var presses = NativePressArbiter<PressSnapshot>()
    func cancelPresses() { presses.cancel() }
    func release(at time: Double) { presses.release(at: time) }
    private func valid(_ press: PressSnapshot, at time: Double) -> Bool {
        stack != nil && generation == press.generation && keyboard.physicalModifiers == press.modifiers && time - press.contacts.lastFrame < 0.15
    }
    func pressure(stage: Int, at time: Double) {
        if let press = presses.stage(stage, at: time), valid(press, at: time) {
            var force = press.gesture; force.kind = .forceClick; _ = handle(force)
        }
    }
    func finishPresses(at time: Double) {
        for press in presses.finish(at: time) where valid(press, at: time) { _ = handle(press.gesture) }
    }
    init(keyboard: StackKeyboardDriving, temporalClock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.keyboard = keyboard; self.temporalClock = temporalClock
    }
    func begin(_ value: GestureStack, deviceID: UInt64, fingerID: Int, time: Double, tuning: GestureTuning, aspect: Double) {
        guard stack == nil else { return }
        generation = UUID(); stack = value; self.deviceID = deviceID; self.fingerID = fingerID; lastFrame = time
        recognizer = GestureRecognizer(); recognizer.tuning = tuning; recognizer.surfaceAspectRatio = aspect
        needsPrime = true; queue = value.startActions; busy = false; drain()
    }
    func frame(deviceID: UInt64, contacts: [Contact], time: Double, cornerSize: Double, pressed: Bool) {
        presses.validate { $0.contacts.accepts(deviceID: deviceID, contacts: contacts, at: time) }
        guard let stack, self.deviceID == deviceID else { return }
        guard time.isFinite, time >= lastFrame, time - lastFrame <= 0.8,
              contacts.count <= 10, Set(contacts.map(\.id)).count == contacts.count,
              contacts.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && (0...1).contains($0.position.x) && (0...1).contains($0.position.y) }),
              let owner = contacts.first(where: { $0.id == fingerID }), stack.corner.contains(owner.position, size: cornerSize) else { end(); return }
        lastFrame = time
        if needsPrime {
            let hold = recognizer.tuning.cornerHold + 0.001
            _ = recognizer.process([owner], at: time - hold, enabledCorners: [stack.corner])
            _ = recognizer.process([owner], at: time - hold / 2, enabledCorners: [stack.corner])
            needsPrime = false
        }
        let eligible = Set(stack.bindings.filter {
            $0.isEnabled && $0.keyboardModifiers.matches(keyboard.physicalModifiers) &&
            ($0.gesture.kind == .longTouch || $0.gesture.kind == .doubleTap)
        }.map { binding in
            var spec = binding.gesture; spec.corner = stack.corner; return spec
        })
        let events = recognizer.process(contacts, at: time, enabledCorners: [stack.corner], physicalButtonDown: pressed, eligibleTemporalSpecs: eligible)
        scheduleTemporalDeadline(at: time)
        presses.validate { press in
            contacts.isEmpty || (recognizer.modifier == press.contacts.corner && recognizer.modifierFinger == press.contacts.cornerFinger)
        }
        for var event in events { event.corner = .none; handle(event) }
    }
    @discardableResult func click(at time: Double, primary: Bool = true, supportsForce: Bool = false) -> Bool {
        if !primary && presses.hasPending { return false }
        guard let stack, let event = recognizer.beginPhysicalPress(at: time, allowSingleFinger: supportsForce && primary) else { return false }
        var child = event; child.corner = .none
        var force = child; force.kind = .forceClick
        if primary && supportsForce && stack.bindings.contains(where: { $0.isEnabled && $0.gesture == force && $0.keyboardModifiers.matches(keyboard.physicalModifiers) }) {
            presses.begin(PressSnapshot(contacts: NativePressContacts(deviceID: deviceID!, contacts: recognizer.contacts,
                corner: stack.corner, cornerFinger: fingerID, cornerSize: recognizer.tuning.cornerSize, time: lastFrame, movementTolerance: recognizer.tuning.tapTravel),
                gesture: child, modifiers: keyboard.physicalModifiers, generation: generation), at: time)
            return false
        }
        return handle(child)
    }
    @discardableResult private func handle(_ gesture: GestureSpec) -> Bool {
        guard let stack else { return false }
        let matches = stack.bindings.filter { $0.isEnabled && $0.gesture == gesture && $0.keyboardModifiers.matches(keyboard.physicalModifiers) }
        guard matches.count == 1, let binding = matches.first else { return false }
        guard queue.count + binding.actions.count <= 64 else { end(); return false }
        queue += binding.actions.map { GestureStackAction(action: $0) }; drain(); return true
    }
    private func drain() {
        guard stack != nil, !busy, !queue.isEmpty else { return }
        let token = generation, next = queue.removeFirst(); busy = true
        let complete: Completion = { [weak self] result in
            guard let self, self.generation == token, self.stack != nil else { return }
            self.busy = false
            if case let .failure(error) = result { self.end(); self.onError?(error) } else { self.drain() }
        }
        if next.kind == .holdModifiers {
            do { try keyboard.hold(next.modifiers); complete(.success("Modifiers held")) } catch { complete(.failure(error)) }
        } else if next.action.kind == .shortcut, let shortcut = next.action.shortcut {
            do { try keyboard.press(shortcut); complete(.success(shortcut.display)) } catch { complete(.failure(error)) }
        } else if let execute { execute(next.action, complete) }
        else { complete(.failure(ActionExecutor.ActionError.message("The action runner is unavailable."))) }
    }
    func end() {
        cancelTemporalGestures()
        cancelPresses()
        guard let ending = stack else { return }
        generation = UUID(); stack = nil; deviceID = nil; fingerID = nil; queue = []; busy = false
        keyboard.releaseAll()
        onEnd?()
        // Release actions are intentionally independent of a blocked start action.
        runRelease(ending.releaseActions, index: 0)
    }
    private func runRelease(_ actions: [GestureAction], index: Int) {
        guard index < actions.count, let execute else { return }
        execute(actions[index]) { [weak self] result in
            if case let .failure(error) = result { self?.onError?(error) }
            self?.runRelease(actions, index: index + 1)
        }
    }
}
