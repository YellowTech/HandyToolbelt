import AppKit
import ApplicationServices
import HandyToolbeltCore

final class ActionExecutor {
    static let eventMarker: Int64 = 0x53555045525450
    private(set) var scriptRunning = false
    var onWindowAction: ((SystemAction, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onShowText: ((GestureAction) -> Void)?
    // NSAppleScript supports background execution; serialize scripts on this queue.
    // Apple guidance: https://developer.apple.com/forums/thread/759287
    private let scriptQueue = DispatchQueue(label: "HandyToolbelt.AppleScript", qos: .userInitiated)

    func execute(_ action: GestureAction, completion: @escaping (Result<String, Error>) -> Void) {
        let action = action.canonicalized
        if action.kind == .showText {
            guard action.isValid, let onShowText else { completion(.failure(ActionError.message("Enter text first."))); return }
            onShowText(action); completion(.success(action.title)); return
        }
        if action.kind == .openApplication {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.applicationBundleIdentifier) else {
                completion(.failure(ActionError.message("The selected application is not installed."))); return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                DispatchQueue.main.async {
                    if let error { completion(.failure(error)) }
                    else if app != nil { completion(.success(action.title)) }
                    else { completion(.failure(ActionError.message("The application could not be opened."))) }
                }
            }
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.failure(ActionError.message("Allow HandyToolbelt in Accessibility to run actions."))); return
        }
        switch action.kind {
        case .automation: completion(.failure(ActionError.message("Automations must run through the shared runner."))); return
        case .showText, .openApplication: break // Presented above without Accessibility access.
        case .shortcut:
            guard let shortcut = action.shortcut else { completion(.failure(ActionError.message("Record a shortcut first."))); return }
            send(shortcut)
            completion(.success(shortcut.display))
        case .system:
            if action.system.isWindowAction {
                guard let onWindowAction else { completion(.failure(ActionError.message("The Windows module is unavailable."))); return }
                onWindowAction(action.system, completion); return
            }
            system(action.system)
            completion(.success(action.system.title))
        case .appleScript:
            guard !scriptRunning else { completion(.failure(ActionError.message("An AppleScript is still running. Wait for it to finish."))); return }
            guard !action.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(.failure(ActionError.message("Enter an AppleScript first."))); return }
            scriptRunning = true
            let source = action.script
            scriptQueue.async { [weak self] in
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                let failure = error?[NSAppleScript.errorMessage] as? String
                let succeeded = result != nil
                DispatchQueue.main.async { [weak self] in
                    self?.scriptRunning = false
                    if let failure { completion(.failure(ActionError.message(failure))) }
                    else if !succeeded { completion(.failure(ActionError.message("The AppleScript could not be compiled."))) }
                    else { completion(.success("AppleScript finished")) }
                }
            }
        }
    }

    private func send(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: shortcut.modifiers)
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func system(_ action: SystemAction) {
        let control: UInt64 = 1 << 18, command: UInt64 = 1 << 20
        switch action {
        case .previousTab, .nextTab: break // Canonicalized to Key press before dispatch.
        case .missionControl: send(.init(keyCode: 126, modifiers: control, keyLabel: "↑"))
        case .showDesktop: send(.init(keyCode: 103, modifiers: 0, keyLabel: "F11"))
        case .spotlight: send(.init(keyCode: 49, modifiers: command, keyLabel: "Space"))
        case .middleClick:
            let point = CGEvent(source: nil)?.location ?? .zero
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center)
                event?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
                event?.post(tap: .cghidEventTap)
            }
        case .playPause: mediaKey(16)
        case .mute: mediaKey(7)
        case .volumeDown: mediaKey(1)
        case .volumeUp: mediaKey(0)
        case .nextWindow, .previousWindow, .showWindowSwitcher: break // Routed to the Windows module above.
        }
    }

    private func mediaKey(_ code: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)
            event?.cgEvent?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    enum ActionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
