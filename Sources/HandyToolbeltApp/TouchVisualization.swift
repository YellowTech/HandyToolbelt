import AppKit
import QuartzCore
import SwiftUI
import HandyToolbeltCore

/// Only the small drawing views observe this object, never the settings form.
final class TouchVisualization: ObservableObject {
    @Published private(set) var frame = GymSnapshot()
    private(set) var press = PressDisplay()
    let pressReadout = TouchPressReadout()
    private var pressFeedback = PressFeedback()
    private var pending = GymSnapshot()
    private var smoother = TouchSmoothing()
    private var deviceID: UInt64?
    var wakeObservers: [UUID: () -> Void] = [:]

    func submit(_ snapshot: GymSnapshot, deviceID: UInt64, at time: Double) {
        let needsDisplay = !snapshot.contacts.isEmpty || pending != snapshot || self.deviceID != deviceID
        if self.deviceID != deviceID { smoother.reset(); pressFeedback = PressFeedback(); self.deviceID = deviceID }
        pending = snapshot
        smoother.receive(snapshot.contacts, at: time)
        if snapshot.contacts.isEmpty { pressFeedback.update(stage: 0, at: time) }
        if needsDisplay { wakeObservers.values.forEach { $0() } }
    }

    func updateFeedback(_ feedback: DetectionFeedback) {
        guard pending.feedback != feedback else { return }
        pending.feedback = feedback
        wakeObservers.values.forEach { $0() }
    }

    func updatePress(stage: Int, at time: Double = ProcessInfo.processInfo.systemUptime) {
        pressFeedback.update(stage: stage, at: time)
        wakeObservers.values.forEach { $0() }
    }

    func reset() {
        smoother.reset(); deviceID = nil
        pending = GymSnapshot()
        pressFeedback = PressFeedback()
        publish(frame: pending, press: PressDisplay())
    }

    /// Returns false to pause the display link after the final lift/stale frame.
    func render(at time: Double) -> Bool {
        var next = pending
        next.contacts = smoother.render(at: time)
        if next.contacts.isEmpty {
            next.modifier = .none; next.modifierFinger = nil
            pressFeedback.update(stage: 0, at: time)
        }
        let nextPress = pressFeedback.display(at: time)
        publish(frame: next, press: nextPress)
        return !next.contacts.isEmpty || nextPress.needsAnimation
    }
    private func publish(frame next: GymSnapshot, press nextPress: PressDisplay) {
        // A single drawing invalidation per display sample, even when both the
        // positions and click animation advance. Readout ignores position changes.
        let pressChanged = press != nextPress
        if frame == next && pressChanged { objectWillChange.send() }
        press = nextPress
        if frame != next { frame = next }
        pressReadout.update(press: nextPress, isTouching: !next.contacts.isEmpty)
    }

}

/// NSView's display link follows the window's screen and suspends when off screen.
/// There is no timer or animation loop when fingers are up or the surface is removed.
struct TouchDisplayClock: NSViewRepresentable {
    let visualization: TouchVisualization
    func makeNSView(context: Context) -> DisplayClockView { DisplayClockView(visualization) }
    func updateNSView(_ view: DisplayClockView, context: Context) {}
    static func dismantleNSView(_ view: DisplayClockView, coordinator: ()) { view.disconnect() }

    final class DisplayClockView: NSView {
        private let visualization: TouchVisualization
        private let observerID = UUID()
        private var link: CADisplayLink?
        var isSampling: Bool { link.map { !$0.isPaused } ?? false }

        init(_ visualization: TouchVisualization) {
            self.visualization = visualization
            super.init(frame: .zero)
            visualization.wakeObservers[observerID] = { [weak self] in self?.wake() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { link?.invalidate(); link = nil }
            else { wake() }
        }

        private func wake() {
            guard window != nil else { return }
            if link == nil {
                let newLink = displayLink(target: self, selector: #selector(tick(_:)))
                newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                newLink.add(to: .main, forMode: .common)
                link = newLink
            }
            link?.isPaused = false
        }

        @objc private func tick(_ link: CADisplayLink) {
            // Sample the newest frame; no extra buffering or forward prediction.
            link.isPaused = !visualization.render(at: ProcessInfo.processInfo.systemUptime)
        }

        func disconnect() {
            visualization.wakeObservers.removeValue(forKey: observerID)
            link?.invalidate(); link = nil
        }
    }
}

/// Only click animation and touch membership invalidate the textual indicator.
final class TouchPressReadout: ObservableObject {
    struct State: Equatable {
        var press = PressDisplay()
        var isTouching = false
    }
    @Published private(set) var state = State()
    func update(press: PressDisplay, isTouching: Bool) {
        let next = State(press: press, isTouching: isTouching)
        if state != next { state = next }
    }
}
