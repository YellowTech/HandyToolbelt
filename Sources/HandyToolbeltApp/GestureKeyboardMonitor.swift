import AppKit
import ApplicationServices
import HandyToolbeltCore

/// Tracks hardware modifier transitions separately from the events this app emits.
final class GestureKeyboardMonitor {
    private var physical = Set<KeyboardModifier>()
    var onUnavailable: (() -> Void)?
    var onPhysicalModifiersChanged: (() -> Void)?
    var onPhysicalKeyDown: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private static let keys: [(KeyboardModifier, CGKeyCode, CGEventFlags)] = [
        (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift), (.command, 55, .maskCommand)]
    var physicalModifiers: Set<KeyboardModifier> { physical }
    func startMonitoring() {
        guard tap == nil else { return }
        physical.removeAll()
        let rightKeys: [CGKeyCode: CGKeyCode] = [59:62, 58:61, 56:60, 55:54]
        for (modifier, key, _) in GestureKeyboardMonitor.keys where CGEventSource.keyState(.hidSystemState, key: key) || CGEventSource.keyState(.hidSystemState, key: rightKeys[key]!) { physical.insert(modifier) }
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let driver = Unmanaged<GestureKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    driver.onUnavailable?()
                    if let tap = driver.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    driver.routeKeyboardEvent(type: type, key: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                        flags: event.flags, marker: event.getIntegerValueField(.eventSourceUserData))
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    /// Shared by the native callback and hardware-free routing checks. Key identity
    /// is used only to filter modifier events and never reaches diagnostics.
    func routeKeyboardEvent(type: CGEventType, key: CGKeyCode, flags: CGEventFlags, marker: Int64) {
        guard marker != ActionExecutor.eventMarker else { return }
        if type == .keyDown {
            if ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key) { onPhysicalKeyDown?() }
        } else if type == .flagsChanged {
            DebugEventRecorder.shared.record(category: .keyboard, event: "modifier_transition")
            physicalTransition(key: key, flags: flags)
        }
    }
    private func physicalTransition(key: CGKeyCode, flags: CGEventFlags) {
        let previous = physical
        let paired: [CGKeyCode: CGKeyCode] = [62:59, 61:58, 60:56, 54:55]
        if let (modifier, _, flag) = GestureKeyboardMonitor.keys.first(where: { $0.1 == (paired[key] ?? key) }) {
            if flags.contains(flag) { physical.insert(modifier) } else { physical.remove(modifier) }
        }
        if physical != previous { onPhysicalModifiersChanged?() }
    }
    func stopMonitoring() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; physical.removeAll()
    }
    deinit { stopMonitoring() }
}
