import AppKit
import SwiftUI
import HandyToolbeltCore

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    @Binding var isRecording: Bool
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.target = button; button.action = #selector(RecorderButton.beginRecording)
        return button
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onRecord = { shortcut = $0; isRecording = false }
        view.onState = { isRecording = $0 }
        view.recording = isRecording
        view.title = isRecording ? "Press a key…  (Esc to cancel)" : shortcut?.display ?? "Record key press"
        view.setAccessibilityLabel(view.title)
    }
    static func dismantleNSView(_ nsView: RecorderButton, coordinator: ()) {
        guard nsView.recording else { return }
        nsView.recording = false; nsView.onState?(false)
    }
}

final class RecorderButton: NSButton {
    var recording = false
    var onRecord: ((Shortcut) -> Void)?
    var onState: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        window?.makeFirstResponder(self)
        recording = true; onState?(true)
    }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false; onState?(false) }
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording && event.type == .keyDown { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        guard event.keyCode != 53 else { recording = false; onState?(false); return }
        let allowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let flags = event.modifierFlags.intersection(allowed)
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        recording = false
        onRecord?(.init(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), keyLabel: label))
    }
}
