import SwiftUI
import AppKit
import HandyToolbeltCore

private enum TeachingPhase {
    case contact, action, lift

    init(progress: Double, kind: GestureKind) {
        if kind == .doubleTap || kind.isDoubleTipTap {
            self = progress < 0.22 ? .action : (progress < 0.42 ? .lift : (progress < 0.72 ? .action : .lift))
            return
        }
        if kind == .longTouch { self = progress < 0.72 ? .contact : (progress < 0.88 ? .action : .lift); return }
        if progress < 0.3 { self = .contact }
        else if progress < 0.85 { self = .action }
        else { self = .lift }
    }

    func title(for kind: GestureKind) -> String {
        switch self {
        case .contact: if kind == .longTouch { return "Hold fingers still" }; return kind.isAnchored ? "Hold resting fingers" : "Touch together"
        case .action: return kind.teachingAction
        case .lift: return kind.isAnchored ? "Lift active finger" : "Lift fingers"
        }
    }
}

private extension GestureKind {
    var teachingAction: String {
        if self == .longTouch { return "Hold" }
        if self == .doubleTap { return "Tap" }
        if isSwipe || isTipSwipe { return "Move" }
        return self == .forceClick ? "Press deeper" : (self == .click ? "Press" : "Tap")
    }
    var teachingDirection: CGVector {
        switch self {
        case .swipeLeft, .tipSwipeLeft: return CGVector(dx: -1, dy: 0)
        case .swipeRight, .tipSwipeRight: return CGVector(dx: 1, dy: 0)
        case .swipeUp, .tipSwipeUp: return CGVector(dx: 0, dy: -1)
        case .swipeDown, .tipSwipeDown: return CGVector(dx: 0, dy: 1)
        default: return .zero
        }
    }
    var teachingDirectionName: String {
        switch self {
        case .swipeLeft, .tipSwipeLeft: return "left"
        case .swipeRight, .tipSwipeRight: return "right"
        case .swipeUp, .tipSwipeUp: return "up"
        case .swipeDown, .tipSwipeDown: return "down"
        default: return ""
        }
    }
}

/// Teaching geometry is entirely local: it never enters the input pipeline.
struct GestureGlyph: View {
    private let gesture: GestureSpec
    private let handAngle: Double
    private let progress: Double
    private let compact: Bool

    init(gesture: GestureSpec, handAngle: Double = 0, progress: Double = 0.45, compact: Bool = true) {
        // Disabled stack drafts may contain invalid counts; never render an unbounded range.
        self.gesture = gesture.normalized()
        self.handAngle = handAngle
        self.progress = progress
        self.compact = compact
    }
    private var phase: TeachingPhase { TeachingPhase(progress: progress, kind: gesture.kind) }
    private var radius: CGFloat { compact ? 2.8 : 8 }
    private var activeIndex: Int {
        switch gesture.kind {
        case .tipTapLeft, .doubleTipTapLeft: return 0
        case .tipTapMiddle, .doubleTipTapMiddle: return 1
        default: return gesture.fingers - 1
        }
    }

    var body: some View {
        Canvas { context, size in
            let outline = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerRadius: compact ? 4 : 10)
            context.fill(outline, with: .color(Theme.field))
            context.stroke(outline, with: .color(Theme.separator), lineWidth: 1)
            drawCorner(in: context, size: size)
            for index in 0..<gesture.fingers {
                let held = gesture.kind.isAnchored && index != activeIndex
                // Anchors remain down for repeated actions; acting fingers lift.
                if !compact && !held && phase == .lift { continue }
                if !compact && gesture.kind.isAnchored && !held && phase == .contact { continue }
                drawFinger(index: index, held: held, in: context, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gesture.title), \(gesture.totalFingerCount) \(gesture.totalFingerCount == 1 ? "finger" : "fingers") total. Hollow circles rest; filled circles act.")
    }

    private func drawCorner(in context: GraphicsContext, size: CGSize) {
        guard gesture.corner != .none else { return }
        let left = gesture.corner == .topLeft || gesture.corner == .bottomLeft
        let top = gesture.corner == .topLeft || gesture.corner == .topRight
        let point = CGPoint(x: size.width * (left ? 0.10 : 0.90), y: size.height * (top ? 0.14 : 0.86))
        drawDot(at: point, held: true, color: .orange, label: "corner", labelOffset: top ? 22 : -18, in: context)
    }

    private func drawFinger(index: Int, held: Bool, in context: GraphicsContext, size: CGSize) {
        let count = gesture.fingers
        let spacing = min(0.17, 0.60 / Double(max(1, count - 1)))
        let offset = (Double(index) - Double(count - 1) / 2) * spacing
        let angle = gesture.kind.isAnchored ? -handAngle * .pi / 180 : 0
        let start = CGPoint(x: (0.5 + offset * cos(angle)) * size.width,
                            y: (0.43 + offset * sin(angle)) * size.height)
        let direction = gesture.kind.teachingDirection
        let moving = min(1, max(0, (progress - 0.3) / 0.4))
        let distance = held ? 0 : moving * 0.18
        let point = CGPoint(x: start.x + direction.dx * distance * size.width,
                            y: start.y + direction.dy * distance * size.height)
        let pressing = !compact && !held && (gesture.kind == .click || gesture.kind == .forceClick) && phase == .action
        let label = held ? "rest" : gesture.kind.teachingAction.lowercased()
        drawDot(at: point, held: held, color: gesture.kind == .forceClick ? .purple : Theme.accent, label: label, pressed: pressing, in: context)
        guard !held else { return }
        if direction != .zero {
            let end = CGPoint(x: start.x + direction.dx * 0.20 * size.width,
                              y: start.y + direction.dy * 0.20 * size.height)
            drawArrow(from: start, to: end, in: context)
        } else if !compact && phase == .action {
            let ringRadius: CGFloat = gesture.kind == .forceClick ? 20 : (pressing ? 16 : 12)
            let color: Color = gesture.kind == .forceClick ? .purple : (pressing ? .green : Theme.accent)
            context.stroke(circle(at: point, radius: ringRadius), with: .color(color.opacity(0.7)), lineWidth: pressing ? 3 : 1)
        }
    }

    private func circle(at point: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private func drawDot(at point: CGPoint, held: Bool, color: Color, label: String, pressed: Bool = false, labelOffset: CGFloat = 22, in context: GraphicsContext) {
        let dot = circle(at: point, radius: pressed ? radius * 1.25 : radius)
        if !held { context.fill(dot, with: .color(pressed ? (gesture.kind == .forceClick ? .purple : .green) : color)) }
        context.stroke(dot, with: .color(color), lineWidth: compact ? 1 : 2)
        if !compact {
            context.draw(Text(label).font(.system(size: 10)).foregroundColor(Theme.secondary),
                         at: CGPoint(x: point.x, y: point.y + labelOffset))
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, in context: GraphicsContext) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = compact ? 3 : 6
        for delta in [-0.55, 0.55] {
            line.move(to: end)
            line.addLine(to: CGPoint(x: end.x - cos(angle + delta) * length, y: end.y - sin(angle + delta) * length))
        }
        context.stroke(line, with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
    }
}

extension GestureSpec {
    var teachingInstruction: String {
        let prefix = corner == .none ? "" : "\(corner.title) with one extra finger. "
        let action: String
        if kind.isAnchored {
            let resting = fingers - 1
            let role = resting == 1 ? "finger" : "fingers"
            let motion = kind.isDoubleTipTap ? "Tap twice" : (kind.isTipTap ? "Briefly tap" : "Swipe \(kind.teachingDirectionName)")
            action = "Rest \(resting) \(role). \(motion) with one finger \(teachingPlacement), then lift it. Keep the resting fingers still.\(kind.isDoubleTipTap ? " Lift only the active finger between taps. Matching single tip-taps wait briefly for the second tap." : "")"
        } else if kind == .longTouch {
            action = "Touch \(fingers == 1 ? "one finger" : "\(fingers) fingers together") and hold still without pressing. Lift before trying again."
        } else if kind == .doubleTap {
            action = "Tap \(fingers == 1 ? "one finger" : "\(fingers) fingers together") twice nearby. Lift all acting fingers between taps. Matching single taps wait briefly for the second tap."
        } else if kind == .tap {
            action = "Touch \(fingers) fingers together briefly, then lift without pressing."
        } else if kind == .forceClick {
            let contact = fingers == 1 ? "one finger" : "\(fingers) fingers together"
            action = "Rest \(contact), click, then press deeper."
        } else if kind == .click {
            action = "Rest \(fingers) fingers together, physically press to click, then lift."
        } else {
            action = "Move \(fingers) fingers together \(kind.teachingDirectionName), then lift."
        }
        return prefix + action
    }

    private var teachingPlacement: String {
        switch kind {
        case .tipTapMiddle, .doubleTipTapMiddle: return "between them"
        case .tipTapLeft, .doubleTipTapLeft: return "to their left"
        case .tipTapRight, .doubleTipTapRight: return "to their right"
        default: return "beside them"
        }
    }
}

struct GestureHowTo: View {
    private let gesture: GestureSpec
    private let handAngle: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.45
    @State private var playback: Task<Void, Never>?
    @State private var playing = false

    init(gesture: GestureSpec, handAngle: Double = 0) {
        self.gesture = gesture.normalized()
        self.handAngle = handAngle
    }

    var body: some View {
        HStack(spacing: 18) {
            GestureGlyph(gesture: gesture, handAngle: handAngle, progress: progress, compact: false).frame(width: 170, height: 98)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(phaseTitle).fontWeight(.medium)
                    Spacer(minLength: 0)
                    Button(playing ? "Stop" : "Replay", systemImage: playing ? "stop.fill" : "play.fill") { playing ? stop() : play() }
                        .controlSize(.small).disabled(reduceMotion).help("Play a three-second example; no action runs")
                }
                Text(gesture.teachingInstruction).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(IllustrationAttachment(onDetach: stop).frame(width: 0, height: 0))
        .onDisappear(perform: stop)
        .onChange(of: gesture) { _, _ in stop() }
        .onChange(of: reduceMotion) { _, _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }
    private var phaseTitle: String {
        if playing {
            let phase = TeachingPhase(progress: progress, kind: gesture.kind)
            if (gesture.kind == .doubleTap || gesture.kind.isDoubleTipTap) && phase == .action { return progress < 0.42 ? "First tap" : "Second tap" }
            if gesture.kind == .longTouch && phase == .action { return "Long touch recognized" }
            return phase.title(for: gesture.kind)
        }
        return "Example · \(gesture.totalFingerCount) \(gesture.totalFingerCount == 1 ? "finger" : "fingers") total"
    }

    private func stop() {
        playback?.cancel()
        playback = nil
        playing = false
        progress = 0.45
    }
    private func play() {
        stop(); playing = true; progress = 0
        playback = Task { @MainActor in
            for frame in 0...90 {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard !Task.isCancelled else { return }
                progress = Double(frame) / 90
            }
            playing = false
            playback = nil
            progress = 0.45
        }
    }
}

private struct IllustrationAttachment: NSViewRepresentable {
    var onDetach: () -> Void
    func makeNSView(context: Context) -> AttachmentView { let view = AttachmentView(); view.onDetach = onDetach; return view }
    func updateNSView(_ view: AttachmentView, context: Context) { view.onDetach = onDetach }
    final class AttachmentView: NSView {
        var onDetach: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { onDetach?() } }
    }
}

struct GestureFingerPicker: View {
    @Binding var gesture: GestureSpec
    var isStackChild = false
    var body: some View {
        if gesture.kind == .tipTapMiddle || gesture.kind == .doubleTipTapMiddle {
            Text("2 resting + 1 tapping finger").font(.caption).foregroundStyle(Theme.secondary)
        } else {
            Picker(gesture.kind.isAnchored ? "Resting fingers" : "Fingers", selection: $gesture.fingers) {
                ForEach(gesture.allowedFingerCounts(isStackChild: isStackChild), id: \.self) { count in
                    Text("\(gesture.kind.isAnchored ? count - 1 : count)").tag(count)
                }
            }.frame(maxWidth: 230)
        }
    }
}
