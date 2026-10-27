// Native event pipeline checks with local settings and captured Show Text output.
// No event taps, hardware, or real input injection are used by this runner.
import AppKit
import HandyToolbeltCore

@main struct ForceClickModelChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1; if !condition() { fatalError(message) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ForceClick-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var focus = "com.example.Editor"
        var access = true
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { _, _, _, _ in })
        let model = AppModel(storage: ConfigurationStore(url: directory.appendingPathComponent("config.json")), nativeInputEnabled: false,
            observeSession: false, sessionIsActive: { true }, accessibilityTrusted: { access }, stackKeyboard: keyboard,
            focusedApplication: { (focus, 100, "Test") })
        var output: [String] = []
        model.onShowText = { output.append($0.text) }
        model.configuration.trackpadModuleEnabled = true
        model.start(); defer { model.stop() }
        let device = TouchDevice(id: 1, kind: .trackpad, name: "Force Touch", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: true)
        model.devices = [device]
        let normal = GestureBinding(gesture: .init(kind: .click, fingers: 2), action: .init(kind: .showText, text: "normal"))
        let force = GestureBinding(gesture: .init(kind: .forceClick, fingers: 2), action: .init(kind: .showText, text: "force"))
        let points = [Contact(id: 1, x: 0.4, y: 0.5), Contact(id: 2, x: 0.6, y: 0.5)]
        var time = ProcessInfo.processInfo.systemUptime + 0.1
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        func begin(_ contacts: [Contact] = points, device selected: TouchDevice? = nil) {
            time += 1
            let d = selected ?? device
            model.receive(d, [], time)
            model.receive(d, contacts, time + 0.01)
            model.receive(d, contacts, time + 0.05)
        }
        func release() { model.physicalRelease(button: 0, at: time + 0.09); model.finishNativePresses(at: time + 0.14); drain() }
        model.configuration.bindings = [normal]
        begin()
        check(model.physicalClick(at: time + 0.06), "Plain click is consumed immediately")
        drain(); check(output == ["normal"], "Plain click action does not wait for release")
        output = []; model.configuration.bindings = [normal, force]
        begin()
        check(!model.physicalClick(at: time + 0.06), "Force-enabled down stays native")
        drain(); check(output.isEmpty, "Paired normal action is deferred")
        model.pressureChanged(stage: 2, at: time + 0.07)
        model.pressureChanged(stage: 1, at: time + 0.075)
        model.pressureChanged(stage: 2, at: time + 0.08)
        release(); check(output == ["force"], "Stage2 without stage1 fires once and excludes ordinary click")
        output = []; begin(); _ = model.physicalClick(at: time + 0.06)
        model.receive(device, [], time + 0.08)
        release(); check(output == ["normal"], "Touch lift before native up retains normal classification")
        output = []; begin(); _ = model.physicalClick(at: time + 0.06)
        model.physicalRelease(button: 0, at: time + 0.09)
        model.pressureChanged(stage: 2, at: time + 0.08)
        model.finishNativePresses(at: time + 0.14); drain()
        check(output == ["force"], "Late-delivered stage2 before up wins in release grace")
        output = []; begin(); _ = model.physicalClick(at: time + 0.06)
        model.physicalRelease(button: 1, at: time + 0.07)
        model.pressureChanged(stage: 2, at: time + 0.08); drain()
        check(output == ["force"], "Secondary button release does not end primary press")
        release(); output = []
        begin(); _ = model.physicalClick(at: time + 0.06)
        check(!model.physicalClick(button: 1, at: time + 0.16), "Secondary down cannot dispatch a paired ordinary action")
        model.pressureChanged(stage: 2, at: time + 0.08); drain()
        check(output == ["force"], "Primary force remains exclusive after secondary down")
        release(); output = []
        begin(); _ = model.physicalClick(at: time + 0.06)
        model.pressureChanged(stage: 2, at: time + 0.08)
        _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
        _ = keyboard.physicalTransition(key: 55, flags: [])
        drain(); release()
        check(output.isEmpty, "Modifier change-and-back cancels a queued native Force click action")
        for reason in ["config", "focus", "modifiers", "permission", "session", "replacement", "ambiguous", "stale"] {
            model.configuration.bindings = [normal, force]; access = true; model.refreshPermissions()
            begin(); _ = model.physicalClick(at: time + 0.06)
            switch reason {
            case "config": model.configuration.hapticsInPractice.toggle()
            case "focus": focus = "com.example.Other"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 101)
            case "modifiers": _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
            case "permission": access = false; model.refreshPermissions()
            case "session": model.handleInputSessionEvent(.lock)
            case "replacement": model.receive(device, [.init(id: 99, x: 0.5, y: 0.5)], time + 0.07)
            case "ambiguous": model.receive(TouchDevice(id: 2, kind: .trackpad, name: "Other", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: true), points, time + 0.07)
            default: model.receive(device, points, time + 0.3)
            }
            model.pressureChanged(stage: 2, at: time + 0.08); release()
            check(output.isEmpty, "\(reason) invalidates pending force and fallback")
            if reason == "session" { model.handleInputSessionEvent(.unlock); model.receive(device, [], time + 0.2) }
            _ = keyboard.physicalTransition(key: 55, flags: [])
            focus = "com.example.Editor"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
        }
        model.configuration.bindings = [normal, force]; access = true; model.refreshPermissions()
        for fingers in [1, 5] {
            model.devices = [device]
            model.configuration.bindings = [GestureBinding(gesture: .init(kind: .forceClick, fingers: fingers), action: .init(kind: .showText, text: "force\(fingers)"))]
            let contacts = (0..<fingers).map { Contact(id: $0 + 1, x: 0.3 + Double($0) * 0.08, y: 0.5, pressure: 999_999) }
            begin(contacts)
            drain(); check(output.isEmpty, "Raw pressure cannot trigger Force click")
            check(!model.physicalClick(at: time + 0.06), "\(fingers)-finger Force click preserves native down")
            model.pressureChanged(stage: 2, at: time + 0.08); release()
            check(output == ["force\(fingers)"], "\(fingers)-finger Force click routes from captured native membership")
            output = []
        }
        let corner = Contact(id: 10, x: 0.05, y: 0.95)
        let free = Contact(id: 11, x: 0.5, y: 0.5)
        model.configuration.bindings = [GestureBinding(gesture: .init(kind: .forceClick, fingers: 1, corner: .topLeft), action: .init(kind: .showText, text: "corner"))]
        for cornerChange in ["none", "lift", "move"] {
            time += 1
            model.receive(device, [], time)
            for offset in [0.01, 0.14, 0.28] { model.receive(device, [corner], time + offset) }
            model.receive(device, [corner, free], time + 0.30)
            model.receive(device, [corner, free], time + 0.34)
            check(!model.physicalClick(at: time + 0.35), "Corner Force click keeps native down")
            if cornerChange == "lift" { model.receive(device, [free], time + 0.355) }
            if cornerChange == "move" { model.receive(device, [.init(id: 10, x: 0.12, y: 0.95), free], time + 0.355) }
            model.pressureChanged(stage: 2, at: time + 0.36)
            model.physicalRelease(button: 0, at: time + 0.37); model.finishNativePresses(at: time + 0.42); drain()
            check(output == (cornerChange == "none" ? ["corner"] : []), "Corner identity is required while free contacts remain")
            output = []
        }
        let oldTrackpad = TouchDevice(id: 4, kind: .trackpad, name: "Non-Force trackpad", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        check(ForceClickCapability(device: .trackpad, connected: []) == .noTrackpad, "No trackpad is distinct from unsupported hardware")
        check(ForceClickCapability(device: .trackpad, connected: [oldTrackpad]) == .unsupportedTrackpad, "Non-Force capability")
        check(ForceClickCapability(device: .trackpad, connected: [device]) == .supportedTrackpad, "Force capability")
        check(ForceClickCapability(device: .trackpad, connected: [oldTrackpad, device]) == .mixedTrackpads, "Mixed capability")
        check(ForceClickCapability(device: .magicMouse, connected: []) == .magicMouse, "Magic Mouse is always unsupported")
        check(ForceClickCapability.noTrackpad.message().contains("No trackpad detected"), "Missing hardware copy explains connection")
        check(ForceClickCapability.unsupportedTrackpad.message().contains("immediately"), "Unsupported copy preserves immediate Click")
        check(!ForceClickCapability.unsupportedTrackpad.message().contains("waits"), "Unsupported copy never claims Click is deferred")
        check(ForceClickCapability.mixedTrackpads.message().contains("other trackpads keep immediate"), "Mixed copy explains per-trackpad behavior")
        check(ForceClickCapability.supportedTrackpad.message().contains("waits for release"), "Available mapping copy explains paired Click timing")
        check(!ForceClickCapability.supportedTrackpad.message(includeClickTiming: false).contains("waits"), "Gym keeps capability help brief")
        check(ForceClickCapability.supportedTrackpad.message(includeClickTiming: false).contains("native app click may also occur"), "Gym retains native click caveat")
        model.devices = [oldTrackpad]; model.configuration.bindings = [normal, force]
        begin(device: oldTrackpad); check(model.physicalClick(at: time + 0.06), "Non-Force trackpad keeps ordinary Click behavior")
        model.pressureChanged(stage: 2, at: time + 0.08); drain()
        check(output == ["normal"], "Non-Force trackpad cannot route Force click")
        output = []
        model.devices = [oldTrackpad, device]
        begin(device: oldTrackpad)
        check(model.physicalClick(at: time + 0.06), "Mixed hardware keeps non-Force Click immediate")
        model.pressureChanged(stage: 2, at: time + 0.08); drain()
        check(output == ["normal"], "Connected Force pad cannot grant pressure capability to another pad")
        release(); output = []
        model.receive(oldTrackpad, [], time + 0.2)
        begin(); _ = model.physicalClick(at: time + 0.06)
        model.pressureChanged(stage: 2, at: time + 0.08); release()
        check(output == ["force"], "Capable pad still routes Force with non-Force pad connected")
        output = []; begin(); _ = model.physicalClick(at: time + 0.06)
        model.devices = [oldTrackpad]
        model.pressureChanged(stage: 2, at: time + 0.08); release()
        check(output.isEmpty, "Disconnected Force pad cancels its pending press")
        check(model.configuration.bindings == [normal, force], "Disconnect preserves saved Force mappings")
        let mouse = TouchDevice(id: 3, kind: .magicMouse, name: "Mouse", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        model.devices = [mouse]
        var mouseNormal = normal; mouseNormal.device = .magicMouse
        var mouseForce = force; mouseForce.device = .magicMouse
        model.configuration.bindings = [mouseNormal, mouseForce]
        begin(device: mouse); check(model.physicalClick(at: time + 0.06), "Unsupported force device preserves ordinary click")
        model.pressureChanged(stage: 2, at: time + 0.08); drain()
        check(output == ["normal"], "Magic Mouse cannot dispatch a Force click")
        print("Passed \(count) Force click model checks")
    }
}
