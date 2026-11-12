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
        let keyboard = GestureKeyboardMonitor()
        var physicalDowns = 0
        keyboard.onPhysicalKeyDown = { physicalDowns += 1 }
        keyboard.routeKeyboardEvent(type: .flagsChanged, key: 56, flags: .maskShift, marker: 0)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 56, flags: .maskShift, marker: 0)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: ActionExecutor.eventMarker)
        keyboard.routeKeyboardEvent(type: .flagsChanged, key: 55, flags: .maskCommand, marker: ActionExecutor.eventMarker)
        check(keyboard.physicalModifiers == [.shift], "Only hardware modifier transitions update matching")
        check(physicalDowns == 0, "Native routing excludes modifiers and app-generated keyboard events")
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: 0)
        keyboard.routeKeyboardEvent(type: .keyDown, key: 0, flags: [], marker: 0)
        check(physicalDowns == 2, "Physical keydown and repeat both refresh suppression")
        keyboard.routeKeyboardEvent(type: .flagsChanged, key: 56, flags: [], marker: 0)
        let model = AppModel(storage: ConfigurationStore(url: directory.appendingPathComponent("config.json")), nativeInputEnabled: false,
            observeSession: false, sessionIsActive: { true }, accessibilityTrusted: { true }, keyboardMonitor: keyboard,
            focusedApplication: { ("com.example.Editor", 100, "Private app name") })
        model.configuration.trackpadModuleEnabled = true
        model.configuration.bindings = [.init(gesture: .init(kind: .tap, fingers: 3), action: .init(kind: .showText, text: "private action")),
            .init(gesture: .init(kind: .doubleTap, fingers: 3), action: .init(kind: .showText, text: "double")),
            .init(gesture: .init(kind: .tipTapRight, fingers: 2), action: .init(kind: .showText, text: "anchored tap")),
            .init(gesture: .init(kind: .tipSwipeRight, fingers: 2), action: .init(kind: .showText, text: "anchored swipe"))]
        var output = [String]()
        model.onShowText = { output.append($0.text) }
        model.start(); defer { model.stop() }
        let device = TouchDevice(id: 998877, kind: .trackpad, name: "Private device name", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        let anchoredDevice = TouchDevice(id: 998878, kind: .trackpad, name: "Second trackpad", aspectRatio: 1.6, hasMeasuredAspect: true, supportsForce: false)
        model.devices = [device, anchoredDevice]
        let points = [Contact(id: 1, x: 0.4, y: 0.5), Contact(id: 2, x: 0.5, y: 0.5), Contact(id: 3, x: 0.6, y: 0.5)]
        let anchor = Contact(id: 3, x: 0.4, y: 0.5)
        let tapper = Contact(id: 4, x: 0.6, y: 0.5)
        let movedTapper = Contact(id: 4, x: 0.76, y: 0.5)
        let now = ProcessInfo.processInfo.systemUptime
        model.receive(device, points, now)
        model.receive(device, points, now + 0.03)
        model.receive(device, [], now + 0.06) // delayed single tap
        model.physicalKeyDown(at: now + 0.08)
        model.finishTemporalGestures(for: device.id, at: now + 0.6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output.isEmpty, "Typing cancels pending temporal dispatch")
        check(!model.physicalClick(at: now + 0.1), "Typing blocks native clicks")
        model.configuration.bindings.remove(at: 1)
        model.receive(device, points, now + 0.53)
        model.receive(device, [], now + 0.51) // queued stale lift must not rearm
        model.receive(device, [], .nan)
        model.receive(device, [], .infinity)
        model.receive(anchoredDevice, [anchor], now + 0.25)
        model.receive(anchoredDevice, [anchor, tapper], now + 0.55)
        RunLoop.main.run(until: Date().addingTimeInterval(0.59))
        model.receive(anchoredDevice, [anchor, movedTapper], now + 0.60)
        model.receive(anchoredDevice, [anchor], now + 0.62)
        model.receive(device, points, now + 0.65)
        model.receive(device, [], now + 0.70)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output.isEmpty, "Tip gestures and ordinary chords begun during cooldown cannot fire after it")
        model.receive(anchoredDevice, [anchor, tapper], now + 0.63)
        model.receive(anchoredDevice, [anchor], now + 0.69)
        model.receive(anchoredDevice, [anchor, tapper], now + 0.73)
        model.receive(anchoredDevice, [anchor, movedTapper], now + 0.77)
        model.receive(anchoredDevice, [anchor], now + 0.79)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output == ["anchored tap", "anchored swipe"], "A continuously held anchor supports fresh taps and swipes immediately after cooldown")
        model.receive(device, points, now + 0.8)
        model.receive(device, points, now + 0.83)
        model.receive(device, [], now + 0.86)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(output == ["anchored tap", "anchored swipe", "private action"], "A fresh ordinary gesture is recognized after a full lift")
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
