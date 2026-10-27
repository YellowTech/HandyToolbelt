import AppKit
import SwiftUI
import HandyToolbeltCore

/// Two independent slots; each has one cancellable, single-shot expiration.
final class VisualFeedbackPresenter {
    enum Position: Hashable { case center, top }
    private struct Slot {
        var panel: FeedbackPanel
        var lifetime: FeedbackLifetime
        var expiration: DispatchWorkItem
    }
    private var slots: [Position: Slot] = [:]
    private struct ProgressSlot {
        let panel: FeedbackPanel
        let model: ProgressFeedbackModel
        let host: NSHostingView<ProgressFeedbackSurface>
    }
    private var progressSlot: ProgressSlot?

    func showText(_ action: GestureAction) {
        guard action.isValid else { return }
        show(action.displayText, at: .center, duration: action.displayDuration)
    }
    func showToast(_ text: String, duration: Double = GestureAction.defaultTextDuration) { guard progressSlot == nil else { return }; show(text, at: .top, duration: duration) }
    func dismissToast() { dismiss(.top) }
    func cancelAll() { for position in Array(slots.keys) { dismiss(position) }; dismissProgress() }
    func dismissProgress() {
        guard let slot = progressSlot else { return }
        slot.model.isVisible = false
        slot.panel.orderOut(nil)
        slot.panel.contentView = nil
        progressSlot = nil
    }
    func showProgress(_ progress: WorkflowProgress, screenID: String?) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == screenID
        }) ?? NSScreen.main else { return }
        dismissToast()
        let width = min(440, max(1, screen.visibleFrame.width - 32))
        let availableHeight = max(1, screen.visibleFrame.height - 32)
        let visibleStepCount = max(1, min(8, Int((availableHeight - 138) / 52)))
        let slot: ProgressSlot
        if let current = progressSlot, current.model.progress.id == progress.id {
            slot = current
            slot.model.update(progress, width: width, visibleStepCount: visibleStepCount)
        } else {
            dismissProgress()
            let model = ProgressFeedbackModel(progress: progress, width: width, visibleStepCount: visibleStepCount)
            let host = NSHostingView(rootView: ProgressFeedbackSurface(model: model))
            let panel = FeedbackPanel(frame: .zero)
            panel.contentView = host
            slot = ProgressSlot(panel: panel, model: model, host: host)
            progressSlot = slot
        }
        // SwiftUI owns the content's height; the panel must use the very same width.
        slot.host.invalidateIntrinsicContentSize()
        slot.host.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: min(availableHeight, ceil(slot.host.fittingSize.height)))
        let frame = FeedbackGeometry.frame(size: size, visibleFrame: screen.visibleFrame, top: true, screenFrame: screen.frame)
        slot.panel.setFrame(frame, display: false)
        slot.host.frame = CGRect(origin: .zero, size: frame.size)
        slot.panel.orderFrontRegardless()
    }

    private func dismiss(_ position: Position) {
        guard var slot = slots.removeValue(forKey: position) else { return }
        slot.expiration.cancel(); slot.lifetime.cancel(); slot.panel.orderOut(nil)
    }

    private func show(_ text: String, at position: Position, duration: Double) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        dismiss(position)
        let top = position == .top
        let maxWidth = min(top ? 440.0 : 520.0, max(1, screen.visibleFrame.width - 32))
        let horizontalPadding = top ? FeedbackSurface.toastOverhead : 40.0
        let font = NSFont.systemFont(ofSize: top ? 14 : 22, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, maxWidth - horizontalPadding), height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let size = CGSize(width: min(maxWidth, ceil(bounds.width) + horizontalPadding + 4),
                          height: min(top ? 100 : 320, ceil(bounds.height) + (top ? 28 : 44)))
        let frame = FeedbackGeometry.frame(size: size, visibleFrame: screen.visibleFrame, top: top, screenFrame: screen.frame)
        let host = NSHostingView(rootView: FeedbackSurface(text: text, top: top))
        let panel = FeedbackPanel(frame: frame)
        panel.contentView = host
        panel.setFrame(frame, display: false)
        var lifetime = FeedbackLifetime()
        let id = lifetime.replace()
        let expiration = DispatchWorkItem { [weak self] in
            guard let self, var slot = self.slots[position], slot.lifetime.expire(id) else { return }
            self.slots.removeValue(forKey: position)
            slot.panel.orderOut(nil)
        }
        slots[position] = Slot(panel: panel, lifetime: lifetime, expiration: expiration)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: expiration)
    }
}

private final class FeedbackPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true
        setAccessibilityLabel("HandyToolbelt visual feedback")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct FeedbackSurface: View {
    static let iconWidth = 20.0
    static let spacing = 10.0
    static let horizontalPadding = 20.0
    static let toastOverhead = 2 * horizontalPadding + spacing + iconWidth
    let text: String
    let top: Bool
    var body: some View {
        HStack(spacing: Self.spacing) {
            if top { Image(systemName: "hand.draw").frame(width: Self.iconWidth).foregroundStyle(Theme.accent).accessibilityHidden(true) }
            Text(text).font(.system(size: top ? 14 : 22, weight: .medium))
                .multilineTextAlignment(top ? .leading : .center)
                .lineLimit(top ? 2 : 10).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: top ? .leading : .center)
        }
        .padding(.horizontal, Self.horizontalPadding).padding(.vertical, top ? 14 : 22)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Theme.text)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.separator))
    }
}

/// Kept for a visible session so native activity indicators and state transitions survive updates.
final class ProgressFeedbackModel: ObservableObject {
    @Published private(set) var progress: WorkflowProgress
    @Published private(set) var width: CGFloat
    @Published private(set) var visibleStepCount: Int
    @Published var isVisible = true

    init(progress: WorkflowProgress, width: CGFloat, visibleStepCount: Int = 8) {
        self.progress = progress; self.width = width; self.visibleStepCount = visibleStepCount
    }
    func update(_ progress: WorkflowProgress, width: CGFloat, visibleStepCount: Int) {
        if self.progress != progress { self.progress = progress }
        if self.width != width { self.width = width }
        if self.visibleStepCount != visibleStepCount { self.visibleStepCount = visibleStepCount }
    }
}

struct ProgressFeedbackSurface: View {
    @ObservedObject var model: ProgressFeedbackModel
    private var progress: WorkflowProgress { model.progress }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(progress.title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 12)
                Text("\(progress.completedCount) / \(progress.steps.count)")
                    .monospacedDigit().foregroundStyle(Theme.secondary)
            }
            GeometryReader { geometry in
                Capsule().fill(Theme.separator)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent)
                            .frame(width: geometry.size.width * completion)
                    }
            }
            .frame(height: 3)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(progress.completedCount) of \(progress.steps.count) steps completed")

            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleIndices, id: \.self) { index in
                    let step = progress.steps[index]
                    HStack(alignment: .top, spacing: 10) {
                        WorkflowActivitySymbol(state: step.state, active: model.isVisible && [.running, .cancelling].contains(progress.state))
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index + 1). \(step.name)").lineLimit(1)
                                .foregroundStyle(step.state == .pending ? Theme.secondary : Theme.text)
                            if let message = step.message, step.state == .running || step.state == .failed {
                                Text(message).font(.caption).lineLimit(2).foregroundStyle(Theme.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(step.state.rawValue.capitalized)
                }
            }
            HStack(spacing: 8) {
                Text(outcome).font(.caption).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                if progress.steps.count > model.visibleStepCount {
                    Text("Steps \((visibleIndices.first ?? 0) + 1)–\((visibleIndices.last ?? 0) + 1)")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if let message = progress.message, !message.isEmpty {
                Text(message).font(.caption).lineLimit(2).foregroundStyle(Theme.secondary)
            }
        }
        .font(.system(size: 14)).padding(18)
        .frame(width: model.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.separator))
    }
    private var completion: Double {
        guard !progress.steps.isEmpty else { return progress.state == .completed ? 1 : 0 }
        return Double(progress.completedCount) / Double(progress.steps.count)
    }
    private var outcome: String {
        switch progress.state {
        case .pending: return "Waiting"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelling: return "Cancelling…"
        case .cancelled: return "Cancelled"
        }
    }
    private var visibleIndices: [Int] {
        let focus = progress.steps.firstIndex(where: { $0.state == .running || $0.state == .failed })
            ?? progress.steps.lastIndex(where: { $0.state == .completed }) ?? 0
        let count = model.visibleStepCount
        let start = max(0, min(focus - count / 2, progress.steps.count - count))
        return Array(start..<min(progress.steps.count, start + count))
    }
}

private struct WorkflowActivitySymbol: View {
    let state: WorkflowState
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if active && state == .running && !reduceMotion {
                FeedbackSpinner()
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(state == .pending ? Theme.secondary : Theme.accent)
                    .id(state)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion || !active ? nil : .easeOut(duration: 0.2), value: state)
        .accessibilityHidden(true)
    }
    private var symbol: String {
        switch state {
        case .pending: return "circle"
        case .running: return "ellipsis.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .cancelling, .cancelled: return "stop.circle"
        }
    }
}

/// AppKit owns the spinner timer and stops it as soon as SwiftUI removes the running step.
private struct FeedbackSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isIndeterminate = true; spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        return spinner
    }
    func updateNSView(_ spinner: NSProgressIndicator, context: Context) {}
    static func dismantleNSView(_ spinner: NSProgressIndicator, coordinator: ()) { spinner.stopAnimation(nil) }
}
