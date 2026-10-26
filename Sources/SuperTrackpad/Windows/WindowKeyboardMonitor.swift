import AppKit
import SuperTrackpadCore

final class WindowKeyboardMonitor {
    enum Command { case begin(reverse: Bool), step(Int), vertical(Int), confirm, cancel }
    var shortcut = WindowShortcut.optionTab
    var chooserOpen = false { didSet { pendingShiftTap = false } }
    var commitOnRelease = false
    var suspended = false { didSet { pendingShiftTap = false } }
    var onCommand: ((Command) -> Bool)?
    var onUnavailable: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumedKeys = Set<UInt16>()
    private var shiftHeld = false
    private var pendingShiftTap = false

    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        shiftHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; chooserOpen = false; consumedKeys = []; commitOnRelease = false; shiftHeld = false
    }
    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<WindowKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
        return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    // Returns whether a key event was consumed. Modifier events always pass through.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pendingShiftTap = false
            _ = onCommand?(.cancel)
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // Ordinary action shortcuts stay excluded to prevent feedback loops. Stack
        // keyboard events deliberately use StackKeyboardDriver.eventMarker so a
        // held Option + Tab sequence follows the same chooser path as hardware.
        guard event.getIntegerValueField(.eventSourceUserData) != ActionExecutor.eventMarker else { return false }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let wasShiftHeld = shiftHeld
        if type == .flagsChanged { shiftHeld = event.flags.contains(.maskShift) }
        if type == .keyUp, consumedKeys.remove(key) != nil { pendingShiftTap = false; return true }
        guard !suspended else { pendingShiftTap = false; return false }
        if type == .flagsChanged {
            if chooserOpen && commitOnRelease && !shortcut.isHeld(flags: event.flags.rawValue) {
                pendingShiftTap = false
                _ = onCommand?(.confirm)
            } else if chooserOpen && (key == 56 || key == 60) {
                if shiftHeld && !wasShiftHeld {
                    pendingShiftTap = true
                } else {
                    let stepBack = pendingShiftTap && !shiftHeld
                    pendingShiftTap = false
                    if stepBack { _ = onCommand?(.step(-1)) }
                }
            } else {
                pendingShiftTap = false
            }
            return false
        }
        // A Shift chord (including repeated Shift-Tab) owns its navigation step.
        pendingShiftTap = false
        guard type == .keyDown else { return false }
        let reverse = event.flags.contains(.maskShift)
        var command: Command?
        if shortcut.matches(keyCode: key, flags: event.flags.rawValue) {
            command = chooserOpen ? .step(reverse ? -1 : 1) : .begin(reverse: reverse)
        } else if chooserOpen {
            switch key {
            case 48: command = .step(reverse ? -1 : 1)
            case 123: command = .step(-1)
            case 124: command = .step(1)
            case 126: command = .vertical(-1)
            case 125: command = .vertical(1)
            case 36, 76: command = .confirm
            case 53: command = .cancel
            default: _ = onCommand?(.cancel)
            }
        }
        if let command, onCommand?(command) == true { consumedKeys.insert(key); return true }
        return false
    }
}
