// Headless integration: no hardware or user actions, only captured Show Text.
import AppKit
import HandyToolbeltCore

@main struct TypingSuppressionModelChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typing-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var keys: [(CGKeyCode, Bool)] = []
        let keyboard = StackKeyboardDriver(physicalModifiers: [], emit: { key, down, _, _ in keys.append((key, down)) })
        var physicalDowns = 0
        keyboard.onPhysicalKeyDown = { physicalDowns += 1 }
        keyboard.routeKeyboardEvent(type: .flagsChanged, key: 56, flags: .maskShift, marker: 0)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 56, flags: .maskShift, marker: 0)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: StackKeyboardDriver.eventMarker)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: ActionExecutor.eventMarker)
        check(physicalDowns == 0, "Native routing excludes modifiers and both synthetic event markers")
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: 0)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: 0)
        check(physicalDowns == 2, "Physical keydown and repeat both refresh suppression")
        keyboard.routeKeyboardEvent(type: .flagsChanged, key: 56, flags: [], marker: 0)
        let model = AppModel(storage: ConfigurationStore(url: directory.appendingPathComponent("config.json")), nativeInputEnabled: false,
            observeSession: false, sessionIsActive: { true }, accessibilityTrusted: { true }, stackKeyboard: keyboard,
            focusedApplication: { ("com.example.Editor", 100, "Private app name") })
        model.configuration.trackpadModuleEnabled = true
        model.configuration.stacks = []
        model.configuration.bindings = [.init(gesture: .init(kind: .tap, fingers: 3), action: .init(kind: .showText, text: "private action")),
            .init(gesture: .init(kind: .doubleTap, fingers: 3), action: .init(kind: .showText, text: "double"))]
        var output = [String]()
        model.onShowText = { output.append($0.text) }
        model.start(); defer { model.stop() }
        let device = TouchDevice(id: 998877, kind: .trackpad, name: "Private device name", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        model.devices = [device]
        let points = [Contact(id: 1, x: 0.4, y: 0.5), Contact(id: 2, x: 0.5, y: 0.5), Contact(id: 3, x: 0.6, y: 0.5)]
        let now = ProcessInfo.processInfo.systemUptime
        model.receive(device, points, now)
        model.receive(device, points, now + 0.03)
        model.receive(device, [], now + 0.06) // delayed single tap
        model.physicalKeyDown(at: now)
        model.finishTemporalGestures(for: device.id, at: now + 0.6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output.isEmpty, "Typing cancels pending temporal dispatch")
        check(!model.physicalClick(at: now + 0.1), "Typing blocks native clicks")
        model.stackRuntime.begin(GestureStack(startActions: [.init(kind: .holdModifiers, modifiers: [.option])]), deviceID: device.id, fingerID: 1, time: now, tuning: GestureTuning(), aspect: 1.6)
        model.physicalKeyDown(at: now)
        check(keys.contains { $0.0 == 58 && !$0.1 }, "Typing releases stack-owned modifiers")
        model.configuration.bindings = [model.configuration.bindings[0]]
        model.receive(device, points, now + 0.2)
        model.receive(device, [], now + 0.1) // queued stale lift must not rearm
        model.receive(device, [], .nan)
        model.receive(device, [], .infinity)
        RunLoop.main.run(until: Date().addingTimeInterval(0.51))
        model.receive(device, points, now + 0.6)
        model.receive(device, [], now + 0.7)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output.isEmpty, "Held fingers cannot fire when typing cooldown expires")
        model.receive(device, points, now + 0.8)
        model.receive(device, points, now + 0.83)
        model.receive(device, [], now + 0.86)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output == ["private action"], "Fresh gesture after a full lift rearms recognition")
        let recorder = DebugEventRecorder.shared
        recorder.setEnabled(true)
        recorder.touch(deviceID: device.id, contacts: points)
        recorder.record(category: .keyboard, event: "physical_key_down")
        let data = try recorder.snapshot()
        let json = String(decoding: data, as: UTF8.self)
        check(!json.contains("998877") && !json.contains("Private") && !json.contains("private action"), "Export excludes device identity, app names and action text")
        check(json.contains("device-1") && json.contains("physical_key_down"), "Export keeps useful anonymous input")
        recorder.setEnabled(false)
        let cleared = try JSONSerialization.jsonObject(with: recorder.snapshot()) as? [String: Any]
        check((cleared?["events"] as? [Any])?.isEmpty == true, "Disable clears all events")
        check(cleared?["schemaVersion"] as? Int == 1, "Export includes a versioned envelope")
        check((cleared?["context"] as? [String: String])?["typing_cooldown_seconds"] == "0.5", "Export retains sanitized current context")
        print("Typing suppression and recorder model checks passed")
    }
}
