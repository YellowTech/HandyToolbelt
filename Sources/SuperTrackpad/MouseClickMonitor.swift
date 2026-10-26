import AppKit

final class MouseClickMonitor {
    var onClick: ((Int64, Double) -> Bool)?
    var onRelease: ((Int64, Double) -> Void)?
    var onUnavailable: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedButtons = Set<Int64>()

    func start() -> Bool {
        if tap != nil { return true }
        let events: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
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
        source = nil; tap = nil; swallowedButtons.removeAll()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<MouseClickMonitor>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.onUnavailable?()
            if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != ActionExecutor.eventMarker else { return Unmanaged.passUnretained(event) }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let time = Double(event.timestamp) / 1_000_000_000
        let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        if isDown {
            if monitor.onClick?(button, time) == true { monitor.swallowedButtons.insert(button); return nil }
        } else {
            monitor.onRelease?(button, time)
            if monitor.swallowedButtons.remove(button) != nil { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
