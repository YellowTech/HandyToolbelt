import AppKit
import Combine
import SwiftUI

struct SnappingIllustration: View {
    var selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowIsActive = false
    @State private var startedAt = Date()
    @State private var pausedAt: Double?

    private let windowEvents = Publishers.MergeMany([
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification
    ].map { NotificationCenter.default.publisher(for: $0) })

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if selected && windowIsActive && !reduceMotion && pausedAt == nil {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        diagram(at: phase(at: timeline.date))
                    }
                } else {
                    diagram(at: reduceMotion ? 3.5 : pausedAt ?? 3.5)
                }
            }
            .frame(width: 320, height: 174)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Snapping example: Drag a window by its title bar to the right edge. When the outline appears, release to fill the right half of the screen.")

            if !reduceMotion {
                Button {
                    if let pausedAt {
                        startedAt = Date().addingTimeInterval(-pausedAt)
                        self.pausedAt = nil
                    } else {
                        pausedAt = phase(at: Date())
                    }
                } label: {
                    Image(systemName: pausedAt != nil ? "play.fill" : "pause.fill")
                        .font(.caption.weight(.medium))
                }
                .accessibilityLabel(pausedAt != nil ? "Play snapping example" : "Pause snapping example")
                .help(pausedAt != nil ? "Play snapping example" : "Pause snapping example")
            }
        }
        .onAppear(perform: refreshActivity)
        .onChange(of: selected) { _, _ in refreshActivity() }
        .onReceive(windowEvents) { _ in refreshActivity() }
    }

    private func phase(at date: Date) -> Double {
        max(0, date.timeIntervalSince(startedAt)).truncatingRemainder(dividingBy: 4.8)
    }

    private func refreshActivity() {
        // Match the key window, including miniaturization and Space changes.
        let active = selected && NSApp.isActive
            && NSApp.keyWindow?.occlusionState.contains(.visible) == true
            && MainWindowPresence.shared.snapshot(includeFrame: false)?.focused == true
        if active && !windowIsActive { startedAt = Date() }
        windowIsActive = active
    }

    private func diagram(at time: Double) -> some View {
        let drag = eased(time, after: 0.85, duration: 1.25)
        let snap = eased(time, after: 2.65, duration: 0.35)
        let reset = eased(time, after: 4.4, duration: 0.4)
        let visibility = eased(time, after: 0, duration: 0.15) * (1 - reset)
        let target = CGRect(x: 164, y: 8, width: 148, height: 158)
        let dragged = CGRect(x: 90 + 203 * drag, y: 49 - 20 * drag, width: 114, height: 79)
        let window = CGRect(x: interpolate(dragged.minX, target.minX, snap),
                            y: interpolate(dragged.minY, target.minY, snap),
                            width: interpolate(dragged.width, target.width, snap),
                            height: interpolate(dragged.height, target.height, snap))
        let pointer = CGPoint(x: 112 + 203 * drag - 15 * snap, y: 32 + 23 * eased(time, after: 0.15, duration: 0.6) - 20 * drag + 9 * snap)
        let outline = eased(time, after: 2.0, duration: 0.2)
        let pressed = time >= 0.85 && time < 2.65
        let bezel = RoundedRectangle(cornerRadius: 11)

        return ZStack(alignment: .topLeading) {
            bezel.fill(Theme.chrome)
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.selection)
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
                .opacity(outline * (1 - reset))
            miniatureWindow
                .frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: window.minY)
                .opacity(visibility)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
                .opacity(outline * (1 - reset))
            ZStack(alignment: .topLeading) {
                Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                    .frame(width: 15, height: 15).offset(x: -7, y: -7)
                    .opacity(pressed ? 1 : 0)
                pointerShape
                    .fill(Theme.text)
                    .overlay(pointerShape.stroke(Theme.chrome, lineWidth: 1))
                    .frame(width: 13, height: 17)
            }
            .offset(x: pointer.x, y: pointer.y)
            .opacity(visibility)
        }
        .frame(width: 320, height: 174)
        .clipShape(bezel)
        .overlay(bezel.strokeBorder(Theme.separator))
    }

    private var miniatureWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in
                    Circle().fill(Theme.secondary.opacity(0.58)).frame(width: 4, height: 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 15)
            .background(Theme.editor)
            Rectangle().fill(Theme.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.secondary.opacity(0.42)).frame(width: 38, height: 4)
                Capsule().fill(Theme.separator).frame(width: 68, height: 3)
                Capsule().fill(Theme.separator).frame(width: 54, height: 3)
            }.padding(10)
            Spacer(minLength: 0)
        }
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator))
    }

    private var pointerShape: Path {
        Path { path in
            path.addLines([.zero, CGPoint(x: 0.5, y: 14), CGPoint(x: 4.2, y: 10.6),
                           CGPoint(x: 7.4, y: 16), CGPoint(x: 9.3, y: 14.8),
                           CGPoint(x: 6.3, y: 9.7), CGPoint(x: 12, y: 9.2)])
            path.closeSubpath()
        }
    }

    private func eased(_ time: Double, after start: Double, duration: Double) -> Double {
        let progress = min(max((time - start) / duration, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    private func interpolate(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }
}
