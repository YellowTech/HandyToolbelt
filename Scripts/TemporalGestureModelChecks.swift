// Temporal gesture integration uses synthetic contacts, a fake keyboard, and
// captured Show Text actions. No hardware input or system actions are emitted.
import AppKit
import HandyToolbeltCore

@main struct TemporalGestureModelChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Temporal-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var focus: String? = "com.example.Editor"
        var access = true
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { _, _, _, _ in })
        let model = AppModel(storage: ConfigurationStore(url: directory.appendingPathComponent("config.json")), nativeInputEnabled: false,
            observeSession: false, sessionIsActive: { true }, accessibilityTrusted: { access }, stackKeyboard: keyboard,
            focusedApplication: { (focus, 100, "Test") })
        var output: [String] = []
        model.onShowText = { output.append($0.text) }
        model.configuration.trackpadModuleEnabled = true
        model.configuration.stacks = []
        model.start(); defer { model.stop() }
        let device = TouchDevice(id: 1, kind: .trackpad, name: "Non-Force", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        let other = TouchDevice(id: 2, kind: .trackpad, name: "Other", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: true)
        model.devices = [device, other]
        func mapping(_ kind: GestureKind, _ title: String) -> GestureBinding {
            GestureBinding(gesture: .init(kind: kind, fingers: 3), action: .init(kind: .showText, text: title))
        }
        let tap = mapping(.tap, "tap"), double = mapping(.doubleTap, "double"), hold = mapping(.longTouch, "hold")
        let points = [Contact(id: 1, x: 0.4, y: 0.5), Contact(id: 2, x: 0.5, y: 0.5), Contact(id: 3, x: 0.6, y: 0.5)]
        var time = ProcessInfo.processInfo.systemUptime + 1
        func drain(_ duration: Double = 0.001) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        func fresh() {
            time += 2
            model.receive(device, [], time)
            model.receive(other, [], time)
            output = []
        }
        func touch(_ offset: Double, on target: TouchDevice? = nil, contacts: [Contact]? = nil) {
            model.receive(target ?? device, contacts ?? points, time + offset)
        }
        func lift(_ offset: Double, on target: TouchDevice? = nil) { model.receive(target ?? device, [], time + offset) }
        func oneTap(on target: TouchDevice? = nil) { touch(0.01, on: target); touch(0.06, on: target); lift(0.10, on: target) }
        func expire(on target: TouchDevice? = nil) { model.finishTemporalGestures(for: (target ?? device).id, at: time + 0.5); drain() }

        model.configuration.bindings = [tap]
        fresh(); oneTap(); drain()
        check(output == ["tap"], "Tap stays immediate without a matching Double tap")
        model.configuration.bindings = [tap, double, hold]
        fresh(); oneTap(); drain()
        check(output.isEmpty, "A matching Double tap defers the first Tap")
        expire(); check(output == ["tap"], "Idle expiry dispatches a single Tap")
        fresh(); oneTap(); touch(0.27); touch(0.31); lift(0.35); drain(); expire()
        check(output == ["double"], "Double tap dispatches once, with no single fallback")
        fresh(); oneTap(); touch(0.27); touch(0.31)
        _ = model.physicalClick(at: time + 0.32)
        lift(0.35); expire()
        check(output.isEmpty, "Physical click cancels a pending second tap")
        fresh(); oneTap(); _ = model.physicalClick(at: time + 0.15); expire()
        check(output.isEmpty, "Mouse-down with lifted contacts cancels a waiting Tap")

        for reason in ["config", "focus", "modifiers", "permission", "session", "disconnect", "workspace", "selection", "chooser", "recording", "stop", "invalid"] {
            access = true; model.refreshPermissions(); model.devices = [device, other]
            model.configuration.bindings = [tap, double, hold]
            model.selectWorkspace(.mappings); model.setSelected(true)
            fresh(); oneTap()
            switch reason {
            case "config": model.configuration.hapticsInPractice.toggle()
            case "focus":
                focus = "com.example.Other"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
                focus = "com.example.Editor"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
            case "modifiers":
                _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
                _ = keyboard.physicalTransition(key: 55, flags: [])
            case "permission": access = false; model.refreshPermissions()
            case "session": model.handleInputSessionEvent(.lock); model.handleInputSessionEvent(.unlock)
            case "disconnect": model.devices = [other]; model.devices = [device, other]
            case "workspace": model.selectWorkspace(.gym); model.selectWorkspace(.mappings)
            case "selection": model.setSelected(false); model.setSelected(true)
            case "chooser": model.windowChooserVisible = true; model.windowChooserVisible = false
            case "recording": model.isRecordingShortcut = true; model.isRecordingShortcut = false
            case "stop": model.stop(); model.start(); model.devices = [device, other]
            default: touch(0.14, contacts: [.init(id: 1, x: .nan, y: 0.5)])
            }
            expire(); check(output.isEmpty, "\(reason) cancels a waiting single, even when context returns")
        }
        access = true; model.refreshPermissions(); model.configuration.bindings = [tap, double, hold]
        for reason in ["modifiers", "config", "focus"] {
            fresh(); oneTap(); model.finishTemporalGestures(for: device.id, at: time + 0.5)
            if reason == "modifiers" {
                _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
                _ = keyboard.physicalTransition(key: 55, flags: [])
            } else if reason == "config" { model.configuration.hapticsInPractice.toggle() }
            else {
                focus = "com.example.Other"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
                focus = "com.example.Editor"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
            }
            drain(); check(output.isEmpty, "\(reason) also cancels an already-queued expired action")
        }

        fresh(); touch(0.01); touch(0.30); touch(0.57); drain()
        check(output == ["hold"], "Long touch works on a trackpad without Force Touch")
        touch(0.70); touch(0.82); _ = model.physicalClick(at: time + 0.83)
        lift(0.86); drain(); expire()
        check(output == ["hold"], "Long touch fires once and suppresses later click/release tap")
        fresh(); touch(0.01); touch(0.30)
        _ = keyboard.physicalTransition(key: 55, flags: .maskCommand)
        _ = keyboard.physicalTransition(key: 55, flags: [])
        touch(0.60); lift(0.65); drain(); expire()
        check(output.isEmpty, "Changed-back modifiers cannot reinterpret an already-held chord")

        fresh(); oneTap(); oneTap(on: other); expire(); expire(on: other)
        check(output == ["tap", "tap"], "Separate devices never form a Double tap together")
        var disabled = double; disabled.isEnabled = false
        model.configuration.bindings = [tap, disabled]
        fresh(); oneTap(); drain()
        check(output == ["tap"], "Disabled Double tap does not delay Tap")
        var modified = double; modified.keyboardModifiers = .init(mode: .exact, modifiers: [.command])
        model.configuration.bindings = [tap, modified]
        fresh(); oneTap(); drain()
        check(output == ["tap"], "Unmatched keyboard modifiers do not delay Tap")
        let group = ApplicationGroup(name: "Other", applications: [.init("Other", "com.example.Other")])
        model.configuration.applicationGroups = [group]
        var scoped = double; scoped.applicationGroupID = group.id
        model.configuration.bindings = [tap, scoped]
        fresh(); oneTap(); drain()
        check(output == ["tap"], "Inactive app group does not delay Tap")

        model.configuration.bindings = [tap, double, hold]
        model.selectWorkspace(.gym); model.gymGesture = hold.gesture
        focus = Bundle.main.bundleIdentifier; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
        check(model.recognitionTemporalSpecs(for: .trackpad) == [hold.gesture], "Gym reserves only its target")
        fresh(); touch(0.01); touch(0.30); touch(0.57); drain()
        check(output.isEmpty, "Gym focus suppresses production actions")
        focus = "com.example.Editor"; _ = model.updateFocusedApplication(bundleIdentifier: focus, processIdentifier: 100)
        fresh(); oneTap(); touch(0.27); touch(0.31); lift(0.35); drain()
        check(output == ["double"], "Background Gym does not suppress another app's mappings")

        model.selectWorkspace(.mappings)
        let tipSingle = mapping(.tipTapRight, "tip"), tipDouble = mapping(.doubleTipTapRight, "double tip")
        model.configuration.bindings = [tipSingle, tipDouble]
        let resting = Array(points.prefix(2))
        let tapping = resting + [Contact(id: 8, x: 0.7, y: 0.5)]
        func oneTip() {
            touch(0.01, contacts: resting)
            touch(0.21, contacts: tapping)
            touch(0.27, contacts: resting)
        }
        fresh(); oneTip(); drain()
        check(output.isEmpty, "Enabled double tip-tap reserves its matching single")
        expire()
        check(output.isEmpty, "Tip single stays reserved until its release-relative deadline")
        model.finishTemporalGestures(for: device.id, at: time + 0.60); drain()
        check(output == ["tip"], "Tip single expires while anchors remain down")
        fresh(); oneTip()
        touch(0.36, contacts: tapping); touch(0.43, contacts: resting); drain(); model.finishTemporalGestures(for: device.id, at: time + 0.8); drain()
        check(output == ["double tip"], "Double tip-tap dispatches once through enabled mapping eligibility")
        fresh(); oneTip(); lift(0.30); model.finishTemporalGestures(for: device.id, at: time + 0.8); drain()
        check(output.isEmpty, "Losing anchors cancels a deferred single tip-tap")
        model.configuration.bindings = [tipSingle]
        fresh(); oneTip(); drain()
        check(output == ["tip"], "Single tip-tap stays immediate without an enabled matching double")

        model.configuration.bindings = [tipSingle, tipDouble]
        time = ProcessInfo.processInfo.systemUptime + 0.01
        model.receive(device, [], time); output = []
        oneTip(); drain(0.65)
        check(output == ["tip"], "Scheduled tip deadline dispatches with resting fingers held and no further frames")

        // One real main-queue deadline proves the integration works without a
        // subsequent hardware frame; the other checks use explicit virtual time.
        model.selectWorkspace(.mappings); model.configuration.bindings = [tap, double]
        time = ProcessInfo.processInfo.systemUptime + 0.01
        model.receive(device, [], time); output = []
        oneTap(); drain(0.55)
        check(output == ["tap"], "Scheduled idle deadline dispatches without further frames")
        print("Passed \(checks) temporal gesture model checks")
    }
}
