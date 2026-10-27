// Compiled and run by check-model-navigation.swift. These checks use temporary
// settings and never start listeners, dispatch actions, or relaunch the app.
import AppKit
import Combine
import SwiftUI
import ApplicationServices
import IOKit.pwr_mgt
import HandyToolbeltControl
import HandyToolbeltCore

@main
struct ModelNavigationChecks {
    static var failures: [String] = []
    static var count = 0

    static func checkWindowChrome() {
        _ = NSApplication.shared
        let window = ChromeCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 800),
                                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let chrome = GraphiteWindowChrome.ChromeView()
        window.contentView?.addSubview(chrome)
        let counts = window.chromeWrites
        for _ in 0..<100 { chrome.updateChrome() }
        check(window.chromeWrites == counts, "Repeated SwiftUI chrome updates do not reassign native window properties")
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.backgroundColor = .systemPink
        let alteredCounts = window.chromeWrites
        chrome.updateChrome()
        check(window.titlebarAppearsTransparent && window.titleVisibility == .hidden && window.backgroundColor == NSColor(Theme.chrome),
              "Chrome updates repair changed native properties")
        check(zip(window.chromeWrites, alteredCounts).allSatisfy { $0 == $1 + 1 }, "Each changed native chrome property is applied once")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            chrome.viewDidChangeEffectiveAppearance()
            check(window.backgroundColor == NSColor(Theme.chrome), "Chrome retains theme color after appearance changes")
            let appearanceCounts = window.chromeWrites
            chrome.updateChrome()
            check(window.chromeWrites == appearanceCounts, "Appearance updates settle without repeated native property writes")
        }
        window.close()
    }

    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures.append(message); print("FAIL: \(message)") }
    }

    static func checkStatusMenu(_ host: ProductivityModel) {
        _ = NSApplication.shared // Native action dispatch only; no windows or app launch.
        var scheduled: [() -> Void] = []
        var opens = 0
        let access = MainWindowAccess(schedule: { scheduled.append($0) })
        access.open()
        check(scheduled.isEmpty, "Startup window request waits for Commands environment")
        access.register { opens += 1 }
        access.register { opens += 1 }
        check(opens == 0 && scheduled.count == 1, "Repeated Commands registration coalesces and defers startup presentation")
        scheduled.removeFirst()()
        check(opens == 1, "Queued startup request opens once after environment registration")
        access.register { opens += 1 }
        check(scheduled.isEmpty, "Body updates do not reopen a closed main window")
        access.open()
        scheduled.removeFirst()()
        check(opens == 2, "Retained Commands opener can recreate a closed main window")

        func event(_ type: NSEvent.EventType, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: Double(number),
                               windowNumber: 0, context: nil, eventNumber: number, clickCount: 1, pressure: 0)!
        }
        let first = event(.leftMouseDown, 1), second = event(.leftMouseDown, 2)
        let tracker = StatusMenuTracking()
        var shown = 0, cancelled = 0
        tracker.toggle(press: first, cancel: { cancelled += 1 }, show: {
            shown += 1
            check(tracker.isTracking, "Menu remains marked open for its entire native tracking loop")
            tracker.toggle(press: second, cancel: { cancelled += 1 }, show: { shown += 1; return nil })
            return second
        })
        check(shown == 1 && cancelled == 1 && !tracker.isTracking, "Second button action cancels and menu completion clears tracking")
        tracker.toggle(press: second, cancel: { cancelled += 1 }, show: { shown += 1; return nil })
        tracker.toggle(press: event(.leftMouseUp, 2), cancel: {}, show: { shown += 1; return nil })
        check(shown == 1, "Forwarded dismissal press and its release cannot reopen the menu")
        for number in [3, 4] {
            tracker.toggle(press: event(.leftMouseDown, number), cancel: {}, show: { shown += 1; return nil })
            check(!tracker.isTracking, "Escape or outside dismissal leaves no tracking state")
        }
        check(shown == 3, "Fresh presses reopen after cancellation or ordinary native dismissal")

        tracker.toggle(press: nil, cancel: {}, show: { shown += 1; return nil })
        tracker.toggle(press: event(.rightMouseDown, 5), cancel: {}, show: { shown += 1; return nil })
        tracker.toggle(press: event(.rightMouseUp, 5), cancel: {}, show: { shown += 1; return nil })
        let keyboard = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 6,
                                       windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                       isARepeat: false, keyCode: 49)!
        tracker.toggle(press: keyboard, cancel: {}, show: { shown += 1; return nil })
        check(shown == 6, "Accessibility, keyboard and right-button activations open without reopening on release")

        host.trackpad.configuration.trackpadModuleEnabled = true
        host.trackpad.configuration.windowSwitcher.isEnabled = true
        host.trackpad.configuration.displayModuleEnabled = true
        host.trackpad.configuration.powerModuleEnabled = true
        host.trackpad.configuration.coffeeModuleEnabled = true
        var routes: [ProductivitySection] = []
        let status = StatusMenu(host: host, reveal: { routes.append($0) })
        func item(_ action: StatusMenu.Action) -> NSMenuItem {
            status.menu.items.first { $0.action != nil && $0.tag == action.rawValue }!
        }
        func activate(_ action: StatusMenu.Action) {
            status.menu.performActionForItem(at: status.menu.index(of: item(action)))
        }
        let expected = ["Open Gestures…", "Open Switcher…", "Open Snapping…", "Open Overlays…", "Open Power…", "", "Prevent idle sleep", "Keep display awake", "Open Coffee…", "", "Settings…", "Restart HandyToolbelt", "Quit HandyToolbelt"]
        check(status.menu.items.filter { !$0.isHidden }.map(\.title) == expected, "Native menu preserves visible labels and ordering")
        host.trackpad.configuration.trackpadModuleEnabled = false
        status.refresh()
        check(!item(.preventIdleSleep).isEnabled && !item(.keepDisplayAwake).isEnabled,
              "Unstarted Coffee keeps its controls disabled")
        for action in [StatusMenu.Action.trackpad, .windows, .snapping, .display, .coffee, .settings] { activate(action) }
        check(routes == [.trackpad, .windows, .snapping, .display, .coffee, .settings], "Every native menu route retains its destination")
        check(item(.quit).keyEquivalent == "q" && item(.quit).keyEquivalentModifierMask == .command,
              "Quit retains its native Command-Q shortcut")

        var failCoffee = true
        var acquired: [CoffeeModel.Mode] = []
        let coffee = CoffeeModel(driver: .init(create: { mode in
            if failCoffee { return (kIOReturnError, 0) }
            acquired.append(mode); return (kIOReturnSuccess, IOPMAssertionID(acquired.count))
        }, release: { _ in kIOReturnSuccess }))
        let coffeeHost = ProductivityModel(trackpad: host.trackpad,
            display: DisplayModel(presenter: nil, observeSession: false), coffee: coffee, controlServerEnabled: false)
        let coffeeMenu = StatusMenu(host: coffeeHost, reveal: { _ in })
        coffee.configure(enabled: true, running: true)
        coffee.set(preventIdleSleep: true)
        coffeeMenu.refresh()
        let retry = coffeeMenu.menu.items.first { $0.action != nil && $0.tag == StatusMenu.Action.retryCoffee.rawValue }!
        check(!retry.isHidden && coffeeMenu.menu.items.contains { $0.title == coffee.errorMessage && !$0.isHidden },
              "Coffee failure retains its error and retry rows")
        failCoffee = false
        coffeeMenu.menu.performActionForItem(at: coffeeMenu.menu.index(of: retry))
        check(coffee.isActive && retry.isHidden, "Retry Coffee refreshes the actual assertion state and clears error rows")
        coffee.set(keepDisplayAwake: true)
        coffeeMenu.refresh()
        let displayMode = coffeeMenu.menu.items.first { $0.action != nil && $0.tag == StatusMenu.Action.keepDisplayAwake.rawValue }!
        check(displayMode.state == .on && displayMode.isEnabled, "Coffee menu checkmarks reflect independent runtime selections")
    }

    static func checkWindowKeyboard() {
        let monitor = WindowKeyboardMonitor()
        var commands: [String] = []
        monitor.onCommand = { command in
            switch command {
            case .begin(let reverse): commands.append(reverse ? "beginBack" : "begin")
            case .step(let delta): commands.append("step\(delta)")
            case .confirm: commands.append("confirm"); monitor.chooserOpen = false
            case .cancel: commands.append("cancel")
            case .vertical: commands.append("vertical")
            }
            return true
        }
        let option = CGEventFlags.maskAlternate
        let shifted: CGEventFlags = [.maskAlternate, .maskShift]
        @discardableResult func send(_ type: CGEventType, _ key: UInt16, _ flags: CGEventFlags, marker: Int64 = 0) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown)!
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            return monitor.handle(type: type, event: event)
        }
        func reset() {
            monitor.chooserOpen = false; monitor.suspended = false; monitor.commitOnRelease = false
            send(.flagsChanged, 56, option)
            monitor.chooserOpen = true; commands = []
        }
        reset()
        check(!send(.flagsChanged, 56, shifted) && commands.isEmpty, "Shift waits for release and passes modifier down through")
        check(!send(.flagsChanged, 56, option) && commands == ["step-1"], "Shift release steps back and passes through")
        send(.flagsChanged, 60, shifted); send(.flagsChanged, 60, option)
        check(commands == ["step-1", "step-1"], "Repeated left/right Shift taps each step once")
        reset(); send(.flagsChanged, 56, shifted)
        send(.keyDown, 48, shifted); send(.keyDown, 48, shifted); send(.keyUp, 48, shifted)
        send(.flagsChanged, 56, option)
        check(commands == ["step-1", "step-1"], "Shift-Tab repeats do not add a release step")
        reset(); monitor.chooserOpen = false; send(.flagsChanged, 56, shifted)
        send(.keyDown, 48, shifted); monitor.chooserOpen = true; send(.flagsChanged, 56, option)
        check(commands == ["beginBack"], "Shift held when opening cannot add a release step")
        reset(); send(.flagsChanged, 56, shifted); send(.keyDown, 123, shifted); send(.flagsChanged, 56, option)
        check(commands == ["step-1"], "Other navigation keys invalidate the Shift tap")
        reset(); send(.flagsChanged, 56, shifted); send(.flagsChanged, 55, [.maskAlternate, .maskShift, .maskCommand]); send(.flagsChanged, 56, option)
        check(commands.isEmpty, "Other modifier chords invalidate the Shift tap")
        for first in [UInt16(56), 60] {
            let second: UInt16 = first == 56 ? 60 : 56
            for releasedFirst in [first, second] {
                reset(); send(.flagsChanged, first, shifted); send(.flagsChanged, second, shifted)
                send(.flagsChanged, releasedFirst, shifted); send(.flagsChanged, releasedFirst == first ? second : first, option)
                check(commands.isEmpty, "Overlapping Shift keys do not produce a bare tap in either release order")
            }
        }
        reset(); send(.flagsChanged, 56, shifted); monitor.chooserOpen = false; monitor.chooserOpen = true; send(.flagsChanged, 56, option)
        check(commands.isEmpty, "Closing and reopening clears pending Shift taps")
        reset(); send(.flagsChanged, 56, shifted); monitor.suspended = true; send(.flagsChanged, 56, option); monitor.suspended = false
        check(commands.isEmpty, "Suspension clears pending Shift taps")
        reset(); send(.flagsChanged, 56, shifted); send(.tapDisabledByTimeout, 0, shifted); send(.flagsChanged, 56, option)
        check(commands == ["cancel"], "Disabled tap cancels and clears pending navigation")
        reset(); monitor.commitOnRelease = true; send(.flagsChanged, 56, shifted); send(.flagsChanged, 58, .maskShift); send(.flagsChanged, 56, [])
        check(commands == ["confirm"], "Modifier-release confirmation has priority over Shift navigation")
        reset(); send(.flagsChanged, 56, shifted, marker: ActionExecutor.eventMarker); send(.flagsChanged, 56, option, marker: ActionExecutor.eventMarker)
        check(commands.isEmpty, "Ordinary action events remain excluded")
        send(.keyDown, 48, shifted, marker: StackKeyboardDriver.eventMarker); send(.keyUp, 48, shifted, marker: StackKeyboardDriver.eventMarker)
        check(commands == ["step-1"], "Stack Shift-Tab continues through the keyboard routing")
        send(.flagsChanged, 56, shifted); send(.flagsChanged, 56, option)
        check(commands == ["step-1", "step-1"], "Stack temporary Shift flags cannot suppress the next physical Shift tap")
        reset(); send(.flagsChanged, 56, shifted); monitor.stop(); monitor.chooserOpen = true; send(.flagsChanged, 56, option)
        check(commands.isEmpty, "Stopping clears pending Shift taps")
    }

    static func checkWindowPreviewService() {
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.006)) }
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let items = (0..<40).map { WindowItem(processID: 42, appName: "Fixture", bundleIdentifier: "fixture", title: "Document \($0)", frame: frame) }
        let candidates = items.enumerated().map { WindowPreviewCandidate(id: UInt32($0.offset + 1), processID: 42, title: $0.element.captureTitle, frame: frame) }
        let backend = PreviewCaptureFixture(candidates: candidates)
        let previews = WindowPreviewService(capture: backend)
        var idlePublications = 0
        let idleObservation = previews.objectWillChange.sink { idlePublications += 1 }
        previews.refreshPermission(); previews.end(); previews.refreshPermission()
        check(idlePublications == 0, "Unchanged preview permission and idle cleanup publish nothing")
        backend.allowed = false
        previews.refreshPermission()
        check(idlePublications == 1 && !previews.hasPermission, "Changed preview permission publishes its real transition once")
        idlePublications = 0
        previews.refreshPermission(); previews.end()
        check(idlePublications == 0, "Repeated denied permission refresh publishes nothing")
        backend.allowed = true; previews.refreshPermission()
        idleObservation.cancel()
        previews.begin(items: items)
        check(backend.loads.isEmpty && backend.captures.isEmpty && backend.requests == 0, "Preview begin never captures or prompts before visible demand")
        previews.setVisible([items[0].id]); backend.completeLoad(); drain()
        check(backend.captures.count == 1 && backend.captures.first?.id == 1, "Only visible windows queue snapshots")
        previews.setVisible(Array(items.prefix(4).map(\.id)))
        check(backend.captures.count == 2, "Native preview concurrency is bounded")
        previews.end()
        backend.completeCapture(); drain()
        check(previews.images.isEmpty && backend.captures.count == 1, "Cancelled snapshot results never publish or queue more capture")
        previews.begin(items: items); previews.setVisible(Array(items.prefix(4).map(\.id))); backend.completeLoad(); drain()
        check(backend.captures.count == 2, "New chooser accounts for unfinished captures from the old generation")
        backend.completeCapture(); drain()
        check(previews.images.isEmpty, "Old generation image cannot populate a reopened chooser")
        previews.end()
        while !backend.captures.isEmpty { backend.completeCapture(); drain() }
        previews.begin(items: items); previews.setVisible([items[0].id])
        previews.end(); backend.completeLoad(); drain()
        check(backend.captures.isEmpty && previews.images.isEmpty, "Cancelled enumeration never starts snapshots")
        backend.allowed = false
        previews.begin(items: items); previews.setVisible([items[0].id])
        check(backend.loads.isEmpty && backend.captures.isEmpty && backend.requests == 0, "Denied permission remains optional and never prompts implicitly")
        previews.requestPermission()
        check(backend.requests == 1 && !previews.hasPermission, "Only explicit preview request invokes permission flow")
        backend.allowed = true
        previews.begin(items: items); previews.setVisible([items[0].id]); backend.completeLoad(); drain()
        backend.allowed = false; backend.completeCapture(); drain()
        check(!previews.hasPermission && previews.images.isEmpty, "Permission revoked during capture clears images before publication")
        backend.allowed = true
        previews.begin(items: items); previews.setVisible([items[0].id]); backend.completeLoad(); drain()
        for item in items {
            previews.setVisible([item.id]); backend.completeCapture(); drain()
        }
        check(previews.images.count == WindowPreviewPolicy.cacheLimit, "Preview memory cache stays bounded while scrolling")
        check(previews.images[items.last!.id] != nil && previews.images[items[0].id] == nil, "Visible previews replace older offscreen images")
        check(backend.sizes.allSatisfy { $0.width <= 480 && $0.height <= 300 }, "Every requested image respects pixel bounds")
        previews.end()
        check(previews.images.isEmpty, "Closing chooser immediately removes all cached images")
    }

    static func checkWindowPreviewSetup() {
        func drain(_ time: TimeInterval = 0.006) { RunLoop.main.run(until: Date().addingTimeInterval(time)) }
        let candidate = WindowPreviewCandidate(id: 5, processID: 42, title: "Test", frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let backend = PreviewCaptureFixture(candidates: [candidate])
        let setup = WindowPreviewSetupModel(capture: backend, ownProcessID: 99, observeSystem: false)
        setup.applicationBecameActive()
        setup.present(); setup.applicationBecameActive()
        check(backend.requests == 0 && backend.loads.isEmpty && backend.captures.isEmpty, "Opening setup and passive refresh never prompt or capture")
        setup.start()
        check(backend.requests == 0 && backend.loads.count == 1 && setup.phase == .checking, "Explicit test skips first permission when already granted")
        backend.completeLoad(); drain()
        check(setup.phase == .checking && backend.captures.count == 1, "Enumeration alone never marks preview access ready")
        backend.completeCapture(); drain()
        check(setup.phase == .ready && !setup.nativeWorkPending, "Ready requires a real successful capture")
        setup.dismiss(); backend.allowed = false; setup.present(); setup.start()
        check(backend.requests == 1 && backend.loads.isEmpty && setup.phase == .screenAccess, "Explicit setup requests missing Screen Recording before capture")
        setup.applicationBecameActive()
        check(backend.requests == 1 && backend.loads.isEmpty, "Denied first permission does not proceed or prompt again passively")
        backend.allowed = true; setup.applicationBecameActive()
        check(backend.loads.count == 1 && setup.phase == .checking, "Returning after first grant automatically advances explicit setup")
        backend.completeLoad(); drain()
        let denied = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Access declined"])
        backend.completeCapture(error: denied); drain()
        check(setup.phase == .problem("Access declined"), "Capture denial is reported truthfully without Ready")
        setup.checkAgain(); backend.completeLoad(error: denied); drain()
        check(setup.phase == .problem("Access declined") && backend.captures.isEmpty, "Enumeration errors never become successful setup")
        backend.candidates = []; setup.checkAgain(); backend.completeLoad(); drain()
        check(setup.phase == .problem("Open a window in another app, then check again."), "Missing targets offer a truthful retry")
        backend.candidates = [WindowPreviewCandidate(id: 1, processID: 99, title: "Own", frame: candidate.frame)]
        setup.checkAgain(); backend.completeLoad(); drain()
        check(backend.captures.isEmpty && setup.phase != .ready, "An own-app window cannot prove cross-app preview access")
        backend.candidates = [candidate]; setup.checkAgain(); setup.dismiss(); setup.present(); setup.start()
        check(backend.loads.count == 1 && setup.nativeWorkPending, "Replacement setup cannot overlap outstanding native work")
        backend.completeLoad(); drain()
        check(backend.captures.isEmpty && setup.phase != .ready && !setup.nativeWorkPending, "Late enumeration cannot start capture or publish Ready in replacement session")
        setup.checkAgain(); backend.completeLoad(); drain(); setup.dismiss(); backend.completeCapture(); drain()
        check(!setup.isPresented && setup.phase != .ready, "Dismissal prevents a late image from marking hidden setup Ready")
        backend.allowed = false; setup.present(); setup.start(); setup.dismiss(); backend.allowed = true; setup.applicationBecameActive()
        check(backend.loads.isEmpty, "Cancelled first-permission flow never advances on later reactivation")
        let timeoutBackend = PreviewCaptureFixture(candidates: [candidate])
        let timedSetup = WindowPreviewSetupModel(capture: timeoutBackend, ownProcessID: 99, timeout: 0.01, observeSystem: false)
        timedSetup.present(); timedSetup.start(); timeoutBackend.completeLoad(); drain(); drain(0.02)
        if case .problem = timedSetup.phase { check(true, "Timeout offers recovery") } else { check(false, "Timeout offers recovery") }
        timedSetup.checkAgain()
        check(timeoutBackend.captures.count == 1 && timeoutBackend.loads.isEmpty, "Timed out native work retains its slot to prevent retries overlapping")
        timeoutBackend.completeCapture(); drain()
        check(timedSetup.phase != .ready && !timedSetup.nativeWorkPending, "Late timeout result is discarded and releases native slot")
        setup.present(); setup.presentationIsVisible = { true }; setup.start(); backend.completeLoad(); drain()
        setup.presentationIsVisible = { false }; backend.completeCapture(); drain()
        check(setup.phase != .ready && !setup.nativeWorkPending, "A hidden sheet cannot publish Ready even without a close notification")
        setup.applicationBecameActive(); setup.checkAgain()
        check(backend.loads.isEmpty, "Hidden sheets cannot start further native work")
        check(backend.sizes.allSatisfy { $0.width <= 240 && $0.height <= 150 }, "Setup test requests a small bounded image")
    }

    static func checkPower() throws {
        let accessory: [String: Any] = ["Type": "UPS", "Current Capacity": 100, "Max Capacity": 100]
        check(PowerReading.decode([accessory]).batteryPresent == false, "Power ignores external UPS")
        let battery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 40, "Max Capacity": 80, "Is Charging": false, "Power Source State": "AC Power"]
        let reading = PowerReading.decode([accessory, battery])
        check(reading.chargePercent == 50 && reading.isCharging == false && reading.powerSource == "ac", "Power decodes built-in battery independently of accessories")
        check(PowerReading.decode([["Type": "InternalBattery", "Max Capacity": 0]]).chargePercent == nil, "Invalid capacity remains unknown")
        check(PowerReading.decode([["Type": "InternalBattery"]]).isCharging == nil, "Missing charging status remains unknown")
        var electrical = PowerReading()
        electrical.mergeRegistry(["MaxCapacity": 100, "Voltage": 12000, "Amperage": NSNumber(value: UInt64.max - 999), "ExternalConnected": false,
            "BatteryData": ["DesignCapacity": 6000, "FullChargeCapacity": 5100, "CycleCount": 200]])
        check(electrical.batteryWatts == -12 && electrical.estimatedMacWatts == 12, "Unsigned negative current decodes discharge watts")
        check(electrical.estimatedHealthPercent == 85 && electrical.fullChargeCapacityMAh == 5100 && electrical.cycleCount == 200, "Actual capacities and cycles decode independently of percentage MaxCapacity")
        var nominal = PowerReading()
        nominal.mergeRegistry(["BatteryData": ["DesignCapacity": 6075, "FullChargeCapacity": 5067, "NominalChargeCapacity": 5217]])
        check(nominal.estimatedHealthPercent == 86 && nominal.healthEstimateSource == "nominalCapacity" && nominal.nominalChargeCapacityMAh == 5217, "Health prefers rounded nominal long-term capacity over raw full capacity")
        nominal.mergeRegistry(["BatteryData": ["DesignCapacity": 6000, "NominalChargeCapacity": 6300]])
        check(nominal.estimatedHealthPercent == 100 && nominal.healthEstimateSource == "nominalCapacity", "Nominal health caps at 100 percent")
        nominal.mergeRegistry(["BatteryData": ["DesignCapacity": 6000, "NominalChargeCapacity": 9000, "FullChargeCapacity": 5100]])
        check(nominal.estimatedHealthPercent == 85 && nominal.healthEstimateSource == "fullChargeCapacity", "Implausible nominal ratio falls back to full charge capacity")
        nominal.mergeRegistry(["BatteryData": ["DesignCapacity": 6000, "NominalChargeCapacity": -1, "FullChargeCapacity": 5100]])
        check(nominal.nominalChargeCapacityMAh == nil && nominal.estimatedHealthPercent == 85, "Invalid nominal capacity falls back safely")
        nominal.mergeRegistry(["BatteryData": ["NominalChargeCapacity": 5217]])
        check(nominal.estimatedHealthPercent == nil && nominal.healthEstimateSource == nil, "Missing design capacity leaves health and source unknown")
        check(electrical.healthEstimateSource == "fullChargeCapacity", "Raw capacity fallback reports its estimate source")
        var implausible = PowerReading(); implausible.mergeRegistry(["Voltage": 30000, "Amperage": -30000, "ExternalConnected": false])
        check(implausible.batteryWatts == nil && implausible.estimatedMacWatts == nil, "Implausible electrical power remains unknown")
        var percentageOnly = PowerReading(); percentageOnly.mergeRegistry(["MaxCapacity": 100])
        check(percentageOnly.fullChargeCapacityMAh == nil && percentageOnly.estimatedMacWatts == nil, "Percentages and missing electrical data stay unknown")
        var charging = PowerReading(); charging.mergeRegistry(["ExternalConnected": true, "Voltage": 12000, "Amperage": 1000, "PowerTelemetryData": ["SystemPowerIn": 30000]], adapter: ["Watts": 96])
        check(charging.estimatedMacWatts == 18 && charging.adapterWatts == 96, "Charging subtracts battery power from actual input, not adapter rating")
        var assisting = PowerReading(); assisting.mergeRegistry(["ExternalConnected": true, "Voltage": 12000, "Amperage": -1000, "PowerTelemetryData": ["SystemPowerIn": 30000]])
        check(assisting.estimatedMacWatts == 42, "Battery assistance adds discharge to adapter input")
        var unplugged = PowerReading(); unplugged.mergeRegistry(["ExternalConnected": false, "PowerTelemetryData": ["SystemPowerIn": 30000]])
        check(unplugged.inputWatts == nil && unplugged.estimatedMacWatts == nil, "Unplugged stale adapter input cannot create consumption")
        var flowReading = PowerReading(batteryPresent: true, isCharging: true, powerSource: "ac", externalConnected: true, batteryWatts: 12, inputWatts: 30, estimatedMacWatts: 18)
        check(PowerFlowState.resolve(flowReading, settling: false) == .charging, "Positive battery power directs flow into battery")
        flowReading.batteryWatts = -12; flowReading.isCharging = false
        check(PowerFlowState.resolve(flowReading, settling: false) == .batteryAssisting, "Negative battery power while plugged in supplies Mac alongside adapter")
        flowReading.externalConnected = false; flowReading.powerSource = "battery"
        check(PowerFlowState.resolve(flowReading, settling: false) == .batteryDischarging, "Unplugged battery supplies Mac despite stale adapter telemetry")
        flowReading.batteryWatts = 12
        check(PowerFlowState.resolve(flowReading, settling: false) == .unavailable, "Unplugged stale charging watts never create active flow")
        flowReading.batteryWatts = nil
        check(PowerFlowState.resolve(flowReading, settling: false) == .unavailable, "Missing battery power is not idle")
        flowReading.batteryWatts = 0
        check(PowerFlowState.resolve(flowReading, settling: false) == .disconnected, "Zero battery power while unplugged stays disconnected")
        flowReading.externalConnected = true; flowReading.powerSource = "ac"
        check(PowerFlowState.resolve(flowReading, settling: false) == .idle, "Known zero battery power is idle")
        flowReading.powerSource = "battery"
        check(PowerFlowState.resolve(flowReading, settling: false) == .unavailable, "Contradictory source reports suppress active arrows")
        check(PowerFlowState.resolve(flowReading, settling: true) == .settling, "Settling suppresses all active directions")
        var clock = Date(timeIntervalSince1970: 1000)
        var liveTick: (() -> Void)?; var timerStarts = 0; var timerStops = 0
        var frontmost = true
        var liveReading = electrical
        let live = PowerModel(driver: .init(read: { liveReading }, observe: { _ in return {} }), scheduler: .init(repeatEvery: { interval, tick in
            check(interval == 2, "Only live two-second timer is scheduled")
            timerStarts += 1; liveTick = tick; return { timerStops += 1 }
        }), now: { clock }, isFrontmost: { frontmost }, observeLifecycle: false)
        live.configure(enabled: true, running: true)
        check(timerStarts == 0 && live.reading.estimatedMacWatts == nil, "Hidden Power has no periodic sampling and initial source settles")
        live.setVisible(true); clock.addTimeInterval(5); liveTick?()
        check(live.reading.estimatedMacWatts == 12 && live.isLive && !live.isSettling, "Settled visible foreground data becomes live")
        liveReading.estimatedMacWatts = 20; liveTick?()
        check(live.reading.estimatedMacWatts == 16, "Live display smooths consumption")
        liveReading.externalConnected = true; liveReading.estimatedMacWatts = 30; liveTick?()
        check(live.reading.estimatedMacWatts == nil, "Source transition discards smoothed old power")
        clock.addTimeInterval(5); liveTick?()
        check(live.reading.estimatedMacWatts == 30, "Source transition restarts smoothing")
        frontmost = false; liveTick?()
        check(!live.isLive && timerStops == 1, "A tick after focus loss stops live polling")
        frontmost = true; live.setVisible(true)
        check(live.isLive && timerStarts == 2, "Returning to visible Power resumes live polling")
        live.setVisible(false)
        check(!live.isLive && timerStops == 2, "Leaving Power tears down live timer")
        live.setSessionActive(false)
        check(!live.running && live.reading.chargePercent == nil, "Inactive session stops monitoring and clears stale readings")
        var reads = 0, starts = 0, stops = 0
        var callback: (() -> Void)?
        var value = reading
        var model: PowerModel? = PowerModel(driver: .init(read: { reads += 1; return value }, observe: { changed in starts += 1; callback = changed; return { stops += 1 } }), observeLifecycle: false)
        model!.configure(enabled: true, running: false)
        check(reads == 0 && starts == 0, "Unstarted Power has no observer or reads")
        model!.configure(enabled: true, running: true)
        model!.configure(enabled: true, running: true)
        check(reads == 1 && starts == 1, "Power starts exactly one event observer")
        value.chargePercent = 51; callback?()
        check(model!.reading.chargePercent == 51 && reads == 2, "Power notification refreshes its reading")
        model!.configure(enabled: false, running: true); callback?()
        check(stops == 1 && reads == 2 && model!.reading.chargePercent == nil, "Disabling Power stops observation and discards stale reading")
        model!.configure(enabled: true, running: true); model = nil
        check(starts == 2 && stops == 2, "Power releases its observer on deinit")
        for version in 1...5 {
            let raw = Data("{\"version\":\(version),\"bindings\":[],\"isEnabled\":false}".utf8)
            let migrated = try JSONDecoder().decode(AppConfiguration.self, from: raw)
            check(migrated.version == 6 && migrated.powerModuleEnabled, "Version \(version) enables read-only Power when migrated")
        }
        var config = AppConfiguration(); config.powerModuleEnabled = false
        check(try !JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config)).powerModuleEnabled, "Disabled Power preference roundtrips")
    }

    static func checkPermissionPolicy() {
        var old = AppConfiguration()
        old.trackpadModuleEnabled = false; old.windowSwitcher.isEnabled = false
        for module in [ProductivitySection.trackpad, .windows, .snapping] {
            var next = old
            if module == .trackpad { next.trackpadModuleEnabled = true }
            else if module == .windows { next.windowSwitcher.isEnabled = true }
            else { next.snappingModuleEnabled = true }
            check((try? ModulePermissionPolicy.validateTransition(from: old, to: next, hasAccessibility: false)) == nil, "Denied access blocks a new input-tool enable")
            do { try ModulePermissionPolicy.validateTransition(from: old, to: next, hasAccessibility: true) }
            catch { check(false, "Granted access permits enabling") }
            do { try ModulePermissionPolicy.validateTransition(from: next, to: old, hasAccessibility: false) }
            catch { check(false, "Turning off remains available without access") }
            var edited = next; edited.displayModuleEnabled.toggle()
            do { try ModulePermissionPolicy.validateTransition(from: next, to: edited, hasAccessibility: false) }
            catch { check(false, "Revoked access preserves stored intent during unrelated edits") }
        }
    }

    static func checkInputSessionLifecycle(directory: URL) throws {
        var active = false
        var events: [String] = []
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { _, down, _, _ in events.append(down ? "down" : "up") })
        let model = AppModel(storage: ConfigurationStore(url: directory.appendingPathComponent("input-session.json")),
                             nativeInputEnabled: false, observeSession: false, sessionIsActive: { active },
                             accessibilityTrusted: { true }, stackKeyboard: keyboard)
        defer { model.stop() }
        model.start()
        check(model.isRunning && !model.inputSessionAvailable && !model.inputMonitoringActive && !model.clicksAvailable,
              "Starting outside the active console session keeps input monitors stopped")
        model.refreshPermissions(); model.reconnect()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(!model.inputMonitoringActive && !model.clicksAvailable, "Refresh, reconnect, and watchdog cannot resume unavailable input")
        active = true; model.handleInputSessionEvent(.unlock)
        check(model.inputSessionAvailable && model.inputMonitoringActive, "Unlock resumes only after the session query succeeds")
        model.stackRuntime.execute = { action, completion in events.append(action.text); completion(.success("done")) }
        let stack = GestureStack(name: "Lifecycle", corner: .topLeft,
                                 startActions: [.init(kind: .holdModifiers, modifiers: [.option])],
                                 releaseActions: [.init(kind: .showText, text: "release")])
        func beginStack() {
            model.stackRuntime.begin(stack, deviceID: 1, fingerID: 1, time: ProcessInfo.processInfo.systemUptime, tuning: .init(), aspect: 1.6)
        }
        for ending in [AppModel.InputSessionEvent.lock, .sleep, .resign] {
            events = []; beginStack(); model.startCalibration()
            model.contacts = [.init(id: 1, x: 0.1, y: 0.9)]
            model.activeCorner = .topLeft
            model.handleInputSessionEvent(ending)
            check(!model.inputSessionAvailable && !model.inputMonitoringActive && !model.clicksAvailable,
                  "Lock, sleep, and session resignation suspend all input monitoring")
            check(model.stackRuntime.stack == nil && events == ["down", "up", "release"],
                  "Session loss releases owned modifiers before required release actions exactly once")
            check(!model.isCalibrating && model.contacts.isEmpty && model.activeCorner == .none,
                  "Session loss cancels calibration and clears contact state")
            model.refreshPermissions(); model.handleInputSessionEvent(ending)
            check(events == ["down", "up", "release"], "Repeated session loss and permission refresh do not duplicate releases")
            active = false; model.handleInputSessionEvent(.wake)
            check(!model.inputSessionAvailable && !model.inputMonitoringActive, "Wake while still locked cannot resume input")
            model.handleInputSessionEvent(.unlock)
            check(!model.inputSessionAvailable, "Unlock notification alone does not override unavailable console session")
            active = true; model.handleInputSessionEvent(.activate)
            check(model.inputSessionAvailable && model.inputMonitoringActive, "Activation requeries availability before resuming")
        }
        // No configured actions or force-capable device: this only observes
        // recognition feedback and cannot post keys, capture, or actuate haptics.
        model.configuration.bindings = []; model.configuration.stacks = []
        let device = TouchDevice(id: 42, kind: .trackpad, name: "Synthetic", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        let fingers = [Contact(id: 1, x: 0.4, y: 0.5), Contact(id: 2, x: 0.6, y: 0.5)]
        let time = ProcessInfo.processInfo.systemUptime + 0.01
        model.receive(device, [], time)
        model.receive(device, fingers, time + 0.01)
        let beforeSuspend = model.lastEventID
        model.handleInputSessionEvent(.sleep)
        model.receive(device, [], time + 0.02)
        model.handleInputSessionEvent(.wake)
        model.receive(device, [], time - 1)
        model.receive(device, [], .infinity)
        model.receive(device, [], .nan)
        model.receive(device, fingers, time + 0.03)
        model.receive(device, [], time + 0.12)
        check(model.lastEventID == beforeSuspend, "Held contacts remain blocked across sleep, suspended/stale empty frames, and nonfinite timestamps")
        model.receive(device, fingers, time + 0.2)
        model.receive(device, [], time + 0.3)
        check(model.lastEventID != beforeSuspend && model.lastGesture == GestureSpec(kind: .tap, fingers: 2).title,
              "Raw lift clears suspension barrier and allows a fresh ordinary gesture")
        let beforeIdleLock = model.lastEventID
        model.handleInputSessionEvent(.lock); model.handleInputSessionEvent(.unlock)
        model.receive(device, fingers, time + 0.4)
        model.receive(device, [], time + 0.5)
        check(model.lastEventID != beforeIdleLock, "An idle device accepts its first fresh gesture after unlock without an extra lift")
        model.handleInputSessionEvent(.sleep)
        model.handleInputSessionEvent(.unlock)
        check(!model.inputSessionAvailable, "Unlock does not override sleep")
        model.handleInputSessionEvent(.wake)
        check(model.inputSessionAvailable, "Wake resumes an unlocked console session")
        model.stop(); model.handleInputSessionEvent(.unlock)
        check(!model.inputMonitoringActive && !model.inputSessionAvailable, "Late session notifications cannot restart a stopped model")
    }

    static func main() throws {
        checkPermissionPolicy()
        checkIndependentSnapping()
        try checkPower()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HandyToolbelt-model-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func fixture(_ name: String, configuration: AppConfiguration = AppConfiguration(), accessibilityTrusted: @escaping () -> Bool = { true }) throws -> (AppModel, ProductivityModel, ConfigurationStore) {
            let storage = ConfigurationStore(url: directory.appendingPathComponent(name + ".json"))
            try storage.save(configuration)
            let model = AppModel(storage: storage, nativeInputEnabled: false, observeSession: false, accessibilityTrusted: accessibilityTrusted)
            return (model, ProductivityModel(trackpad: model, display: DisplayModel(presenter: nil, observeSession: false), controlServerEnabled: false), storage)
        }

        let (_, statusHost, _) = try fixture("status-menu")
        checkStatusMenu(statusHost)
        try checkInputSessionLifecycle(directory: directory)
        var permissionGranted = false
        let (model, host, storage) = try fixture("drafts", accessibilityTrusted: { permissionGranted })
        check(ProductivitySection(rawValue: "general") == .settings, "Legacy general restart argument restores Settings")
        if ProcessInfo.processInfo.arguments.contains("general") {
            check(host.section == .settings && !model.isSelected, "Host restores legacy Settings route before starting")
        }
        host.section = .trackpad
        host.revealSettings(.accessibility)
        let firstNavigation = host.settingsNavigationID
        host.revealSettings(.accessibility)
        check(host.section == .settings && host.settingsTarget == .accessibility && host.settingsNavigationID != firstNavigation, "Repeated requirements clicks produce a fresh Global Settings navigation")
        host.consumeSettingsNavigation(firstNavigation)
        check(host.settingsTarget == .accessibility, "A stale scroll cannot consume a newer navigation request")
        host.consumeSettingsNavigation(host.settingsNavigationID)
        check(host.settingsTarget == nil, "Applied navigation is consumed for ordinary gear returns")
        host.revealGestureSettings()
        check(host.section == .trackpad && model.workspace == .settings, "Gesture Settings route selects its cached workspace")
        model.selectWorkspace(.mappings)
        var denied = AppConfiguration(); denied.trackpadModuleEnabled = false; denied.windowSwitcher.isEnabled = false
        model.configuration = denied; model.hasAccessibility = true
        try model.replaceConfiguration(denied)
        let deniedData = try Data(contentsOf: storage.url)
        var enabling = denied; enabling.trackpadModuleEnabled = true
        do { _ = try host.commands.apply(enabling, expectedRevision: try denied.revision()); check(false, "CLI denied enable must fail") }
        catch { check((try? model.configuration.revision()) == (try? denied.revision()) && (try? Data(contentsOf: storage.url)) == deniedData, "Denied CLI enabling leaves model and persisted settings untouched") }
        permissionGranted = true; model.hasAccessibility = false
        _ = try host.commands.apply(enabling, expectedRevision: try denied.revision())
        permissionGranted = false; model.hasAccessibility = true
        var edited = enabling; edited.visualFeedbackEnabled.toggle()
        _ = try host.commands.apply(edited, expectedRevision: try enabling.revision())
        check((try? model.configuration.revision()) == (try? edited.revision()), "CLI unrelated edits retain requested enablement after access revocation")
        _ = try host.commands.apply(denied, expectedRevision: try edited.revision())
        check(!model.configuration.trackpadModuleEnabled, "CLI can disable without access")
        for module in [ProductivitySection.trackpad, .windows, .snapping] {
            model.hasAccessibility = true; permissionGranted = false
            let before = try Data(contentsOf: storage.url)
            host.setModule(module, enabled: true)
            check(!model.configuration.trackpadModuleEnabled && !model.configuration.windowSwitcher.isEnabled && !model.configuration.snappingModuleEnabled && (try? Data(contentsOf: storage.url)) == before,
                  "UI enable uses fresh revoked access and preserves disk")
            permissionGranted = true; model.hasAccessibility = false
            host.setModule(module, enabled: true)
            check(module == .trackpad ? model.configuration.trackpadModuleEnabled : module == .windows ? model.configuration.windowSwitcher.isEnabled : model.configuration.snappingModuleEnabled,
                  "UI enable uses fresh grant despite stale denied cache")
            permissionGranted = false
            host.setModule(module, enabled: false)
        }
        permissionGranted = true
        host.section = .trackpad
        model.configuration = AppConfiguration()
        try model.replaceConfiguration(model.configuration)
        let originalData = try Data(contentsOf: storage.url)
        let originalTuning = model.configuration.trackpadTuning
        check(!model.hasUnappliedGymChanges && !model.gymHasChanges, "Initial settings have no trial changes")
        model.selectWorkspace(.gym)
        check(model.gymGesture == model.configuration.bindings.first?.gesture, "First Gym visit practices selected mapping")
        model.gymTuning.handAngleDegrees = 23
        model.gymAttempts = [.init(message: "Kept", matched: true, recognized: true)]
        model.selectWorkspace(.gym)
        check(model.gymTuning.handAngleDegrees == 23 && model.gymAttempts.count == 1, "Selecting current Gym is idempotent")
        check(model.gymHasChanges && model.hasUnappliedGymChanges, "Editing trial sets both dirty states")
        check(try Data(contentsOf: storage.url) == originalData, "Trial editing does not persist detection changes")

        model.startCalibration()
        model.isRecordingShortcut = true
        model.selectWorkspace(.settings)
        check(!model.isCalibrating && !model.isRecordingShortcut && model.workspace == .settings, "Gesture Settings stops calibration and shortcut recording")
        model.selectWorkspace(.groups)
        check(!model.isCalibrating && model.workspace == .groups, "Leaving Gym for App Groups stops training")
        check(model.gymTuning.handAngleDegrees == 23, "Workspace change keeps draft")
        model.selectWorkspace(.gym)
        model.startCalibration()
        host.section = .settings
        check(!model.isSelected && !model.isCalibrating, "Leaving Trackpad stops training and deselects module")
        host.section = .trackpad
        check(model.isSelected && model.showGym && model.gymTuning.handAngleDegrees == 23, "Returning to Trackpad preserves Gym and its draft")
        model.selectDevice(.magicMouse)
        check(model.gymTuning == model.configuration.mouseTuning && !model.gymHasChanges, "New device begins with its own tuning")
        model.gymTuning.handAngleDegrees = -17
        model.selectDevice(.trackpad)
        check(model.gymTuning.handAngleDegrees == 23, "Trackpad draft survives device round trip")
        model.selectDevice(.magicMouse)
        check(model.gymTuning.handAngleDegrees == -17, "Mouse draft survives device round trip")
        model.applyGymSettings()
        let applied = try storage.load()
        check(applied.mouseTuning.handAngleDegrees == -17 && applied.trackpadTuning == originalTuning, "Apply persists only the selected device")
        check(!model.gymHasChanges && model.hasUnappliedGymChanges, "Applying mouse leaves Trackpad draft dirty")
        check(model.devicesWithGymChanges == [.trackpad], "Dirty-device list excludes the clean selected mouse")
        host.section = .settings
        host.restart()
        check(!host.isRestarting && host.errorMessage?.contains("Trackpad") == true && host.errorMessage?.contains("Review Gym Trials") == true && !model.isRunning, "Restart is blocked by hidden other-device draft")
        host.errorMessage = nil
        model.reviewGymTrials()
        host.section = .trackpad
        check(model.selectedDevice == .trackpad && model.showGym && model.gymTuning.handAngleDegrees == 23, "Review trials selects the dirty device and preserves its tuning")
        model.gymTuning = model.configuration.tuning(for: .trackpad)
        check(!model.hasUnappliedGymChanges, "Reverting remaining device clears all draft changes")
        check(model.devicesWithGymChanges.isEmpty, "Dirty-device list clears after revert")
        model.reviewGymTrials()
        check(model.selectedDevice == .trackpad && model.showGym, "Review with no changes leaves the selected device stable")
        model.startCalibration()
        host.restart()
        check(!host.isRestarting && host.errorMessage?.contains("training") == true && !model.isRunning, "Restart is blocked by active training")
        model.stopCalibration()

        model.configuration.trackpadModuleEnabled = true
        model.selectWorkspace(.gym)
        model.gymTuning.handAngleDegrees = 35
        model.gymGesture.corner = .topRight
        model.configuration.bindings = [.init(gesture: .init(kind: .tipTapLeft, corner: .bottomLeft), action: .init(system: .nextTab))]
        model.updateFocusedApplication(bundleIdentifier: Bundle.main.bundleIdentifier, processIdentifier: ProcessInfo.processInfo.processIdentifier)
        check(model.gymActive && model.recognitionTuning(for: .trackpad) == model.gymTuning.validated && model.recognitionCorners(for: .trackpad) == [.topRight], "Frontmost Gym uses draft tuning and practice corners")
        model.updateFocusedApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 999)
        check(model.productionFocusAllowsActions && !model.gymActive && model.showGym && model.recognitionTuning(for: .trackpad) == model.configuration.trackpadTuning && model.recognitionCorners(for: .trackpad) == [.bottomLeft], "Background Gym restores saved production tuning and corners without changing workspace")
        model.isRecordingShortcut = true
        model.selectWorkspace(.groups)
        check(model.productionFocusAllowsActions && model.recognitionCorners(for: .trackpad) == [.bottomLeft], "Background groups and shortcut recording preserve production corners")
        model.isRecordingShortcut = false
        model.selectWorkspace(.gym)
        model.updateFocusedApplication(bundleIdentifier: Bundle.main.bundleIdentifier, processIdentifier: ProcessInfo.processInfo.processIdentifier)
        check(model.gymActive && model.recognitionCorners(for: .trackpad) == [.topRight], "Returning to HandyToolbelt restores the Gym draft")

        model.configuration.trackpadModuleEnabled = false
        model.configuration.windowSwitcher.isEnabled = false
        for section in ProductivitySection.allCases { host.section = section }
        check(!model.configuration.trackpadModuleEnabled && !model.configuration.windowSwitcher.isEnabled, "Selecting tabs does not mutate per-tool enable settings")
        check(!model.configuration.trackpadModuleEnabled && !model.configuration.windowSwitcher.isEnabled, "Selecting sections preserves disabled modules")
        check(!model.isRunning && !host.windows.isRunning, "Unstarted model checks never start listeners")

        let (routing, routingHost, routingStorage) = try fixture("routing")
        routingHost.section = .trackpad
        routing.selectWorkspace(.gym)
        routing.gymTuning.handAngleDegrees = 31
        let groupID = routing.configuration.applicationGroups.last!.id
        routing.showApplicationGroups(selecting: groupID)
        check(routing.workspace == .groups && routing.selectedGroupID == groupID, "Edit Groups selects requested group")
        let gesture = GestureSpec(kind: .click, fingers: 4)
        routing.practice(gesture)
        check(routing.showGym && routing.gymGesture == gesture && routing.gymTuning.handAngleDegrees == 31, "Practice link selects gesture without losing tuning")
        let beforeBindings = routing.configuration.bindings.count
        routing.addBinding()
        check(routing.workspace == .mappings && routing.configuration.bindings.count == beforeBindings + 1, "New Gesture routes to mapping editor")
        check(routing.configuration.bindings.last?.id == routing.selectedID && routing.configuration.bindings.last?.isEnabled == true, "New Gesture selects active new mapping")
        check(routing.configuration.bindings.last?.action.kind == .showText && routing.configuration.bindings.last?.action.text == "New gesture" && routing.configuration.validation().errors.isEmpty, "New Gesture uses a valid harmless action and avoids existing conflicts")
        let sortedSelection = routing.selectedID
        let firstGroup = routing.configuration.applicationGroups.first!.id
        let lastGroup = routing.configuration.applicationGroups.last!.id
        let everywhere = GestureBinding(gesture: .init(kind: .tap), action: .init(kind: .showText, text: "Everywhere"), isEnabled: false)
        let firstScoped = GestureBinding(gesture: .init(kind: .tap), action: .init(kind: .showText, text: "First"), isEnabled: false, applicationGroupID: firstGroup)
        let secondScoped = GestureBinding(gesture: .init(kind: .tap), action: .init(kind: .showText, text: "Second"), isEnabled: false, applicationGroupID: firstGroup)
        let lastScoped = GestureBinding(gesture: .init(kind: .tap), action: .init(kind: .showText, text: "Last"), isEnabled: false, applicationGroupID: lastGroup)
        let originalBindings = routing.configuration.bindings
        routing.configuration.bindings = [lastScoped, firstScoped, everywhere, secondScoped]
        check(routing.visibleBindings.map(\.id) == [everywhere.id, firstScoped.id, secondScoped.id, lastScoped.id], "Mappings sort Everywhere first, then configured app groups with stable intra-group order")
        check(routing.selectedID == sortedSelection && routing.mappingScopeIDs.first! == nil && routing.mappingScopeIDs.dropFirst().prefix(routing.configuration.applicationGroups.count).compactMap { $0 } == routing.configuration.applicationGroups.map(\.id), "Scope ordering preserves selection and configured group order")
        routing.configuration.bindings = originalBindings
        let completeBindings = routing.configuration.bindings
        routing.configuration.bindings.append(.init(gesture: .init(kind: .tap, fingers: 2), action: .init(kind: .shortcut)))
        routing.addBinding()
        check(routing.configuration.bindings.last?.isEnabled == true && routing.configuration.bindings.last?.action.isValid == true, "An unrelated incomplete action does not prevent a new valid mapping from starting active")
        routing.configuration.bindings = completeBindings
        routing.selectedID = sortedSelection
        let savedAfterMapping = try routingStorage.load()
        check(routing.hasUnappliedGymChanges && savedAfterMapping.trackpadTuning.handAngleDegrees == 0, "Saving new mapping does not save Gym draft")
        routing.selectDevice(.magicMouse)
        routing.selectWorkspace(.gym)
        routing.gymTuning.handAngleDegrees = -24
        routingHost.section = .windows
        routingHost.addWindowStackExample()
        let example = routing.configuration.stacks.first!
        check(!example.isEnabled && example.corner == .topLeft && example.bindings.count == 2, "Window stack starts inactive with a corner hold and two child gestures")
        check(example.startActions.first?.kind == .holdModifiers && example.startActions.first?.modifiers == [.option] && example.startActions.last?.action.shortcut?.keyCode == 48, "Window stack uses held Option plus an ordinary Tab key press")
        check(example.bindings.allSatisfy { $0.actions.first?.kind == .shortcut } && example.releaseActions.isEmpty, "Window stack uses keyboard bindings and automatic release only")
        check(routingHost.section == .trackpad && routing.workspace == .mappings && routing.selectedDevice == .trackpad && routing.selectedStackID == example.id, "Window stack route selects its own editor")
        let examplesCount = routing.configuration.stacks.count
        routingHost.addWindowStackExample()
        check(routing.configuration.stacks.count == examplesCount, "Adding the window stack twice preserves the existing example")
        routing.selectDevice(.magicMouse)
        routing.selectWorkspace(.gym)
        check(routing.gymTuning.handAngleDegrees == -24, "Window example route preserves hidden mouse draft")
        routing.stop()
        check(routing.gymTuning.handAngleDegrees == -24 && routing.hasUnappliedGymChanges, "Stopping input preserves all trial settings")

        var custom = AppConfiguration()
        let mouseGesture = GestureSpec(kind: .swipeLeft, fingers: 3)
        let mouseBinding = GestureBinding(device: .magicMouse, gesture: mouseGesture, action: .init(system: .nextWindow), isEnabled: false)
        custom.bindings.insert(mouseBinding, at: 0)
        let (seed, seedHost, _) = try fixture("device-first-visit", configuration: custom)
        seedHost.section = .trackpad
        seed.selectDevice(.magicMouse)
        seed.selectWorkspace(.gym)
        check(seed.gymGesture == mouseGesture, "First Gym visit after switching device practices its selected mapping")
        seedHost.addWindowStackExample()
        check(seed.configuration.stacks.first { $0.id == seed.selectedStackID }?.device == .trackpad, "Window example route selects a trackpad stack even after editing a mouse mapping")

        let invalid = directory.appendingPathComponent("invalid.json")
        let invalidData = Data("invalid settings".utf8)
        try invalidData.write(to: invalid)
        let recovery = AppModel(storage: ConfigurationStore(url: invalid))
        let recoveryHost = ProductivityModel(trackpad: recovery, display: DisplayModel(presenter: nil, observeSession: false), controlServerEnabled: false)
        check(recovery.settingsNeedRecovery && recoveryHost.section == .trackpad, "Settings recovery takes priority over restored section")
        recoveryHost.section = .settings
        recovery.configuration.trackpadModuleEnabled = false
        check(try Data(contentsOf: invalid) == invalidData, "Navigating and disabling during recovery preserves unreadable settings")

        let failedRecoveryURL = directory.appendingPathComponent("recovery-write-failure.json")
        try invalidData.write(to: failedRecoveryURL)
        var failRecoveryWrite = true
        var recoveryWrites = 0
        let failedRecoveryStore = ConfigurationStore(url: failedRecoveryURL, recoverySave: { replacement in
            recoveryWrites += 1
            if failRecoveryWrite {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try ConfigurationStore(url: failedRecoveryURL).save(replacement)
        })
        let failedRecovery = AppModel(storage: failedRecoveryStore, nativeInputEnabled: false)
        failedRecovery.configuration.trackpadModuleEnabled = false
        let beforeRecovery = failedRecovery.configuration
        failedRecovery.recoverSettings()
        check(failedRecovery.settingsNeedRecovery && failedRecovery.errorMessage?.contains("Could not recover") == true,
              "Failed recovery retains recovery state and reports the replacement failure")
        check(try failedRecovery.configuration.revision() == beforeRecovery.revision() && recoveryWrites == 1,
              "Failed recovery never publishes defaults or invokes a second save")
        check(try Data(contentsOf: failedRecoveryURL) == invalidData,
              "Failed recovery preserves unreadable settings at their original path")
        let recoveryBackups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings-backup-") }
        check(try recoveryBackups.contains { try Data(contentsOf: $0) == invalidData },
              "Failed recovery retains an exact backup copy of unreadable settings")
        failedRecovery.configuration.displayModuleEnabled.toggle()
        check(try Data(contentsOf: failedRecoveryURL) == invalidData,
              "Edits after failed recovery remain unable to overwrite the unreadable file")
        failRecoveryWrite = false
        failedRecovery.recoverSettings()
        check(!failedRecovery.settingsNeedRecovery && failedRecovery.errorMessage == nil && recoveryWrites == 2,
              "Successful retry publishes recovered state after one committed write")
        check(try ConfigurationStore(url: failedRecoveryURL).load().revision() == failedRecovery.configuration.revision(),
              "Recovered in-memory configuration exactly matches the atomically saved replacement")
        failedRecovery.configuration.displayModuleEnabled.toggle()
        check(try ConfigurationStore(url: failedRecoveryURL).load().revision() == failedRecovery.configuration.revision(),
              "Successful recovery restores ordinary saving")

        // Text actions route locally without sending input or presenting a real window.
        let textExecutor = ActionExecutor()
        var displayedText: [GestureAction] = []
        var textResult: Result<String, Error>?
        textExecutor.onShowText = { displayedText.append($0) }
        let textAction = GestureAction(kind: .showText, text: "Window selected", textDuration: 0.5)
        textExecutor.execute(textAction) { textResult = $0 }
        check(displayedText == [textAction], "Show Text routes its message and duration to the local presenter")
        check((try? textResult?.get()) == "Show Text", "Show Text completes without generating input or requesting access")
        textExecutor.execute(.init(kind: .showText, text: " \n ")) { textResult = $0 }
        check(displayedText.count == 1 && (try? textResult?.get()) == nil, "Blank Show Text never reaches the presenter")
        textExecutor.onShowText = nil
        textExecutor.execute(textAction) { textResult = $0 }
        check((try? textResult?.get()) == nil, "Missing text presenter reports failure")

        let previewDisplay = DisplayModel(presenter: nil, observeSession: false)
        check(previewDisplay.previewProgress(), "Progress demo begins without an automation")
        let demoID = previewDisplay.progress.latest?.progress.id
        check(previewDisplay.progress.latest?.progress.title == "Progress demo", "Demo is identified honestly")
        previewDisplay.cancelProgressPreview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        check(previewDisplay.progress.latest == nil, "Cancelled demo cannot publish queued updates")
        check(previewDisplay.previewProgress(), "Demo restarts")
        let realProgress = WorkflowProgress(title: "Real work", steps: ["Step"])
        _ = previewDisplay.begin(realProgress)
        previewDisplay.cancelProgressPreview()
        check(previewDisplay.progress.latest?.progress.id == realProgress.id && previewDisplay.progress.sessions.count == 1, "Real progress replaces demo and survives demo cleanup")
        check(!previewDisplay.previewProgress(), "Demo refuses to overwrite real progress")
        previewDisplay.dismiss()
        _ = previewDisplay.previewProgress()
        previewDisplay.configure(enabled: false)
        check(previewDisplay.progress.latest == nil && demoID != nil, "Disabling overlays clears the demo")

        let (_, previewHost, _) = try fixture("preview-navigation")
        previewHost.section = .display
        _ = previewHost.display.previewProgress()
        previewHost.section = .settings
        check(previewHost.display.progress.latest == nil && previewHost.automationRunner.active == nil, "Navigation cancels demo without creating a real automation")
        previewDisplay.configure(enabled: true)
        _ = previewDisplay.previewProgress()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        check(previewDisplay.progress.latest?.progress.state == .completed && previewDisplay.progress.latest?.progress.completedCount == 3, "Demo advances coherent steps to completion")
        previewDisplay.cancelProgressPreview()

        let shortLabel = "Tip-tap left · Previous browser tab"
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let measured = (shortLabel as NSString).size(withAttributes: [.font: font]).width
        let width = ceil(measured) + FeedbackSurface.toastOverhead + 4
        let shortHost = NSHostingView(rootView: FeedbackSurface(text: shortLabel, top: true).frame(width: width))
        let longHost = NSHostingView(rootView: FeedbackSurface(text: String(repeating: "Long gesture description ", count: 8), top: true).frame(width: width))
        shortHost.layoutSubtreeIfNeeded(); longHost.layoutSubtreeIfNeeded()
        check(shortHost.fittingSize.height < 50, "Native toast layout fits the browser-tab label on one line")
        check(longHost.fittingSize.height > shortHost.fittingSize.height, "Native toast layout wraps long labels")
        for (name, nativeHost) in [("short", shortHost), ("long", longHost)] {
            let size = NSSize(width: width, height: ceil(nativeHost.fittingSize.height))
            nativeHost.frame = NSRect(origin: .zero, size: size)
            nativeHost.layoutSubtreeIfNeeded()
            if let bitmap = nativeHost.bitmapImageRepForCachingDisplay(in: nativeHost.bounds) {
                nativeHost.cacheDisplay(in: nativeHost.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/overlay-\(name).png"))
                }
            }
        }


        // Haptic timing uses a fake performer; these checks never actuate hardware.
        var pulses: [HapticPattern.Pulse] = []
        let haptics = HapticPlayer { pulses.append($0) }
        haptics.play(.doubleClick)
        check(pulses.count == 1, "First haptic pulse is immediate")
        haptics.play(.doubleClick)
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        check(pulses.count == 2, "Rapid duplicate requests coalesce into one double pattern")
        haptics.play(.strongDouble)
        haptics.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        check(pulses.count == 3, "Stopping cancels the queued second haptic pulse")
        haptics.play(.doubleClick)
        haptics.play(.off)
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        check(pulses.count == 4, "Off cancels a pending pattern without emitting a pulse")

        let visual = TouchVisualization()
        visual.submit(GymSnapshot(contacts: [.init(id: 1, x: 0.5, y: 0.5, pressure: 2)]), deviceID: 1, at: 10)
        visual.updatePress(stage: 2, at: 10)
        check(visual.render(at: 10) && visual.press.kind == .forceClick, "Force click reaches the live presentation")
        visual.submit(GymSnapshot(), deviceID: 1, at: 10.1)
        check(visual.render(at: 10.1) && !visual.press.isHeld, "Lift preserves the short pulse but releases the press")
        check(!visual.render(at: 10.7) && visual.press.kind == .touch, "Display work stops after lift and pulse expiry")
        visual.submit(GymSnapshot(contacts: [.init(id: 1, x: 0.5, y: 0.5)]), deviceID: 1, at: 11)
        visual.updatePress(stage: 2, at: 11)
        visual.submit(GymSnapshot(contacts: [.init(id: 1, x: 0.5, y: 0.5)]), deviceID: 2, at: 11.1)
        _ = visual.render(at: 11.1)
        check(visual.press.kind == .touch, "Switching physical devices clears force-click state")
        visual.updatePress(stage: 2, at: 12)
        visual.reset()
        check(!visual.render(at: 12) && visual.press.kind == .touch, "Reset clears presentation and pending pulse")

        var executedSteps: [String] = []
        var actionCompletion: ((Result<String, Error>) -> Void)?
        var delayedStep: (() -> Void)?
        var cancelledWait = false
        let runner = AutomationRunner(execute: { action, completion in
            executedSteps.append(action.text); actionCompletion = completion
        }, schedule: { _, body in delayedStep = body; return { cancelledWait = true } })
        let sequence = SavedAutomation(name: "Sequence", steps: [
            .init(name: "First", action: .init(kind: .showText, text: "First")),
            .init(name: "Wait", delay: 1),
            .init(name: "Last", action: .init(kind: .showText, text: "Last"))
        ])
        let run = try runner.start(sequence)
        check(executedSteps.isEmpty, "Run returns identity before executing its first action")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(executedSteps == ["First"] && runner.status(run.id)?.steps[0].state == .running, "Runner waits for real action completion")
        actionCompletion?(.success("First completed"))
        check(runner.status(run.id)?.steps[1].state == .running && executedSteps.count == 1, "Wait starts only after the previous action completes")
        _ = runner.cancel(run.id)
        delayedStep?()
        check(cancelledWait && runner.status(run.id)?.state == .cancelled && executedSteps.count == 1, "Cancellation invalidates even an already-queued wait callback")
        runner.isAllowed = { false }
        do { _ = try runner.start(sequence); check(false, "Unavailable session must refuse a new run") }
        catch { check(true, "Unavailable session refuses a new run") }

        var created: [CoffeeModel.Mode] = [], released: [IOPMAssertionID] = []
        var nextID: IOPMAssertionID = 0
        var failCreate: CoffeeModel.Mode?, failRelease = false
        let driver = CoffeeModel.Driver(create: { mode in
            created.append(mode)
            if failCreate == mode { return (kIOReturnError, 0) }
            nextID += 1; return (kIOReturnSuccess, nextID)
        }, release: { id in released.append(id); return failRelease ? kIOReturnError : kIOReturnSuccess })
        var coffee: CoffeeModel? = CoffeeModel(driver: driver)
        coffee!.set(preventIdleSleep: true, keepDisplayAwake: true)
        check(created.isEmpty && !coffee!.isActive, "Unstarted Coffee cannot acquire assertions")
        coffee!.configure(enabled: true, running: true)
        check(created == [.preventIdleSleep, .keepDisplayAwake] && coffee!.isActive, "Coffee acquires both independent modes")
        coffee!.configure(enabled: true, running: true)
        coffee!.set(preventIdleSleep: true)
        check(created.count == 2 && released.isEmpty, "Duplicate updates do not churn assertions")
        coffee!.set(keepDisplayAwake: false)
        check(coffee!.isEffective(.preventIdleSleep) && !coffee!.isEffective(.keepDisplayAwake) && released.count == 1, "Display mode releases independently")
        coffee!.configure(enabled: false, running: true)
        check(!coffee!.isActive && !coffee!.preventIdleSleep && !coffee!.keepDisplayAwake, "Disabling releases assertions and clears runtime selections")
        coffee!.configure(enabled: true, running: true)
        check(!coffee!.isActive && created.count == 2, "Re-enabling Coffee does not resume a previous mode")
        coffee!.set(preventIdleSleep: true, keepDisplayAwake: true)
        coffee!.configure(enabled: false, running: true)
        check(!coffee!.isActive && !coffee!.preventIdleSleep && !coffee!.keepDisplayAwake, "Module off clears both modes")
        coffee!.set(preventIdleSleep: true)
        check(!coffee!.preventIdleSleep && !coffee!.isActive, "Disabled Coffee cannot retain an activation request")
        coffee!.configure(enabled: true, running: true)
        coffee!.set(preventIdleSleep: true)
        failCreate = .keepDisplayAwake
        coffee!.set(keepDisplayAwake: true)
        check(coffee!.isEffective(.preventIdleSleep) && !coffee!.isEffective(.keepDisplayAwake) && coffee!.errorMessage != nil, "Partial acquisition exposes error and actual active state")
        failCreate = nil; coffee!.retry()
        check(coffee!.isEffective(.keepDisplayAwake) && coffee!.errorMessage == nil, "Retry acquires failed mode")
        failRelease = true
        coffee!.set(preventIdleSleep: false, keepDisplayAwake: false)
        check(coffee!.isActive && coffee!.errorMessage != nil, "Failed release retains IDs and active state")
        failRelease = false; coffee!.retry()
        check(!coffee!.isActive && coffee!.errorMessage == nil, "Retry releases retained assertions")
        coffee!.set(preventIdleSleep: true)
        coffee!.configure(enabled: true, running: false)
        check(!coffee!.isActive && coffee!.preventIdleSleep, "Stop releases assertions")
        coffee!.configure(enabled: true, running: true)
        let releaseCount = released.count
        coffee = nil
        check(released.count == releaseCount + 1, "Deinit releases held assertion")
        let freshCoffee = CoffeeModel(driver: driver)
        check(!freshCoffee.preventIdleSleep && !freshCoffee.keepDisplayAwake, "Selections reset for a fresh process model")
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfiguration())) as! [String: Any]
        legacyObject["version"] = 5
        legacyObject.removeValue(forKey: "coffeeModuleEnabled")
        let migrated = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(migrated.coffeeModuleEnabled, "Legacy settings enable Coffee with no active selection")
        var disabledCoffee = migrated; disabledCoffee.coffeeModuleEnabled = false
        check(try !JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(disabledCoffee)).coffeeModuleEnabled, "Coffee setting roundtrips")
        let schema = try ControlSchema.value()
        check(schema.objectValue?["commands"]?.objectValue?["coffee.set"] != nil, "Machine schema exposes Coffee")
        let coffeeCommands = ControlCommandService(display: DisplayModel(presenter: nil, observeSession: false), runner: runner, coffee: freshCoffee,
            getConfiguration: { migrated }, saveConfiguration: { _ in })
        check(!coffeeCommands.handle(.init(command: "coffee.set", parameters: ["preventIdleSleep": .bool(true)])).ok, "CLI rejects activation before host starts")
        check(coffeeCommands.handle(.init(command: "coffee.set", parameters: ["preventIdleSleep": .bool(false)])).ok, "CLI allows disabling before host starts")
        check(!coffeeCommands.handle(.init(command: "coffee.set", parameters: [:])).ok, "CLI requires one mode")
        check(!coffeeCommands.handle(.init(command: "coffee.set", parameters: ["preventIdleSleep": .string("true")])).ok, "CLI rejects nonboolean modes")

        // Local AX reference equality only: nonexistent PIDs ensure this cannot inspect another app.
        let firstAXIdentity = AXUIElementCreateApplication(Int32.max)
        let duplicateAXIdentity = AXUIElementCreateApplication(Int32.max)
        let otherAXIdentity = AXUIElementCreateApplication(Int32.max - 1)
        let deduplicatedAX = WindowCatalog.deduplicatedElements([firstAXIdentity, duplicateAXIdentity, firstAXIdentity, otherAXIdentity])
        check(deduplicatedAX.count == 2 && CFEqual(deduplicatedAX[0], firstAXIdentity) && CFEqual(deduplicatedAX[1], otherAXIdentity), "Catalog deduplicates equivalent AX identities before assigning window UUIDs")

        checkWindowChrome()
        checkWindowKeyboard()
        checkWindowPreviewService()
        checkWindowPreviewSetup()

        print("\(count - failures.count)/\(count) model and feedback checks passed")
        if !failures.isEmpty { exit(1) }
    }
}

private final class ChromeCountingWindow: NSWindow {
    var chromeWrites: [Int] = [0, 0, 0]
    override var titlebarAppearsTransparent: Bool { didSet { chromeWrites[0] += 1 } }
    override var titleVisibility: NSWindow.TitleVisibility { didSet { chromeWrites[1] += 1 } }
    override var backgroundColor: NSColor! { didSet { chromeWrites[2] += 1 } }
}

// Synthetic images and manually completed callbacks exercise lifecycle behavior without TCC or screen capture.
private final class PreviewCaptureFixture: WindowPreviewCapturing {
    var allowed = true
    var requests = 0
    var candidates: [WindowPreviewCandidate]
    var loads: [(Result<[WindowPreviewCandidate], Error>) -> Void] = []
    var captures: [(id: UInt32, completion: (Result<CGImage, Error>) -> Void)] = []
    var sizes: [CGSize] = []
    init(candidates: [WindowPreviewCandidate]) { self.candidates = candidates }
    func hasPermission() -> Bool { allowed }
    func requestPermission() { requests += 1 }
    func loadWindows(completion: @escaping (Result<[WindowPreviewCandidate], Error>) -> Void) { loads.append(completion) }
    func capture(id: UInt32, size: CGSize, completion: @escaping (Result<CGImage, Error>) -> Void) {
        captures.append((id, completion)); sizes.append(size)
    }
    func completeLoad(error: Error? = nil) { if !loads.isEmpty { loads.removeFirst()(error.map { .failure($0) } ?? .success(candidates)) } }
    func completeCapture(error: Error? = nil) {
        guard !captures.isEmpty else { return }
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        captures.removeFirst().completion(error.map { .failure($0) } ?? .success(context!.makeImage()!))
    }
}


extension ModelNavigationChecks {
    static func checkIndependentSnapping() {
        let driver = FakeSnappingMonitor()
        let workspace = NotificationCenter(), application = NotificationCenter(), distributed = NotificationCenter()
        var trusted = true, eligible = true, active = true
        let model = WindowSnappingModel(monitor: driver, trusted: { trusted }, eligibility: { eligible },
            sessionIsActive: { active }, workspaceCenter: workspace, applicationCenter: application, distributedCenter: distributed)
        var configuration = AppConfiguration(); configuration.windowSwitcher.isEnabled = false; configuration.snappingModuleEnabled = true
        model.configure(enabled: configuration.snappingModuleEnabled, running: true)
        check(driver.running && model.monitorAvailable, "Snapping runs independently with Switcher off")
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        for _ in 0..<100 { check(driver.onInteraction?() == true, "Unchanged drag input remains eligible") }
        model.configure(enabled: true, running: true); model.refreshAvailability()
        check(notifications == 0, "Unchanged snapping input and refresh publish no UI changes")
        model.setSuspended(true)
        check(!driver.running && !model.monitorAvailable, "Chooser or shortcut recording suspension stops snapping")
        model.setSuspended(false)
        check(driver.running, "Ending suspension resumes independent snapping")
        trusted = false
        check(driver.onInteraction?() == false && !driver.running && !model.hasAccessibility, "Revoked permission stops snapping at the input boundary")
        trusted = true; model.refreshAvailability()
        eligible = false
        check(driver.onInteraction?() == false && !driver.running && !model.eligible, "Native tiling availability stops snapping at the input boundary")
        eligible = true; model.refreshAvailability()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(!driver.running, "Sleep stops snapping")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(driver.running, "Wake resumes enabled snapping")
        active = false
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        check(!driver.running, "Screen lock stops snapping")
        active = true
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        check(driver.running, "Unlock resumes enabled snapping")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        model.configure(enabled: false, running: true)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(!driver.running, "Disabled Snapping stays stopped across wake")
        model.configure(enabled: true, running: true)
        check(driver.running, "Re-enabling starts a fresh awake session after a missed wake")
        model.stop()
        check(!driver.running, "Host shutdown stops independent snapping")
        withExtendedLifetime(subscription) {}
    }
}

private final class FakeSnappingMonitor: WindowSnappingMonitoring {
    var diagnostics = WindowSnapDiagnosticsSnapshot()
    var onInteraction: (() -> Bool)?
    var onUnavailable: (() -> Void)?
    var running = false
    func start() -> Bool { running = true; return true }
    func stop() { running = false }
    func cancel() {}
    func updateScreens() {}
    func applicationActivated(_ processID: pid_t) {}
}
