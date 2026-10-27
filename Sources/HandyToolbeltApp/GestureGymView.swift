import SwiftUI
import HandyToolbeltCore

struct GestureGymView: View {
    @ObservedObject var model: AppModel
    @State private var showFineTuning = false
    @State private var showHowTo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gesture gym").font(.system(size: 23, weight: .semibold))
                }
                Spacer()
                Label("Actions paused", systemImage: "pause.circle").font(.caption).foregroundStyle(Theme.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        practiceSelector
                        if showHowTo {
                            GestureHowTo(gesture: model.gymGesture, handAngle: model.gymTuning.handAngleDegrees)
                        }
                        Text("Live").font(.caption).foregroundStyle(Theme.secondary)
                        VStack(spacing: 8) {
                            GymTouchPreview(readout: model.gymReadout, visualization: model.touchVisualization, tuning: model.gymTuning, target: model.gymGesture)
                                .frame(maxWidth: 470, maxHeight: 220)
                                .frame(maxWidth: .infinity)
                                .help("Resting finger is teal, tapping finger blue, and corner hold orange. Keep the pointer over the surface for force-click feedback.")
                        }
                        GymDetectionReadout(readout: model.gymReadout, tuning: model.gymTuning, target: model.gymGesture)
                        Divider()
                        GymAttemptsView(history: model.gymHistory)
                    }.padding(20)
                }.frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PressFeedbackIndicator(visualization: model.touchVisualization)
                        Divider()
                        if model.gymGesture.kind.isAnchored {
                            VStack(alignment: .leading, spacing: 10) {
                                adjustment("Hand angle", value: $model.gymTuning.handAngleDegrees, range: GestureTuning.bounds["handAngleDegrees"]!, step: 1,
                                           display: "\(Int(model.gymTuning.handAngleDegrees))°")
                                HStack {
                                    Button("Left hand") { model.gymTuning.handAngleDegrees = -20 }
                                    Button("Flat") { model.gymTuning.handAngleDegrees = 0 }
                                    Button("Right hand") { model.gymTuning.handAngleDegrees = 20 }
                                    Spacer(minLength: 0)
                                }.controlSize(.small)

                            }.disabled(model.isCalibrating)
                            Divider()
                        }
                        calibrationSection
                        Divider()
                        fineTuning
                        Divider()
                        HapticSettingsView(model: model)
                    }
                    .padding(20)
                }.frame(width: 370)
            }
            Divider()
            HStack(spacing: 12) {
                Text(model.gymHasChanges ? "Unapplied changes" : model.gymSaveMessage == "Changes stay in the gym until you apply them." ? "Saved settings" : model.gymSaveMessage)
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Revert") { model.gymTuning = model.configuration.tuning(for: model.selectedDevice) }
                    .disabled(!model.gymHasChanges || model.isCalibrating)
                Button("Apply settings", action: model.applyGymSettings)
                    .disabled(!model.gymHasChanges || model.isCalibrating)
            }.padding(16)
        }
    }

    private var fineTuning: some View {
        HeaderDisclosureGroup("Fine-tune detection", isExpanded: $showFineTuning) {
            if showFineTuning {
                        VStack(alignment: .leading, spacing: 14) {
                            adjustment("Long touch hold", value: $model.gymTuning.longTouchDuration, range: GestureTuning.bounds["longTouchDuration"]!, step: 0.01,
                                       display: milliseconds(model.gymTuning.longTouchDuration))
                            adjustment("Double tap interval", value: $model.gymTuning.doubleTapInterval, range: GestureTuning.bounds["doubleTapInterval"]!, step: 0.01,
                                       display: milliseconds(model.gymTuning.doubleTapInterval))
                            adjustment("Maximum tap time", value: $model.gymTuning.tapDuration, range: GestureTuning.bounds["tapDuration"]!, step: 0.01,
                                       display: milliseconds(model.gymTuning.tapDuration))
                            adjustment("Movement allowance", value: $model.gymTuning.tapTravel, range: GestureTuning.bounds["tapTravel"]!, step: 0.005,
                                       display: percent(model.gymTuning.tapTravel))
                            adjustment("Rest before tip-tap", value: $model.gymTuning.anchorHold, range: GestureTuning.bounds["anchorHold"]!, step: 0.01,
                                       display: milliseconds(model.gymTuning.anchorHold))
                            adjustment("Minimum finger spacing", value: $model.gymTuning.tipSeparation, range: GestureTuning.bounds["tipSeparation"]!, step: 0.005,
                                       display: percent(model.gymTuning.tipSeparation))
                            adjustment("Corner hold time", value: $model.gymTuning.cornerHold, range: GestureTuning.bounds["cornerHold"]!, step: 0.01,
                                       display: milliseconds(model.gymTuning.cornerHold))
                            adjustment("Corner size", value: $model.gymTuning.cornerSize, range: GestureTuning.bounds["cornerSize"]!, step: 0.01,
                                       display: percent(model.gymTuning.cornerSize))
                            adjustment("Swipe distance", value: $model.gymTuning.swipeTravel, range: GestureTuning.bounds["swipeTravel"]!, step: 0.01,
                                       display: percent(model.gymTuning.swipeTravel))
                            HelpHint("Spacing follows your hand axis as a percentage of surface width. Movement uses normalized surface distance. Hand angle sets anchored finger placement; swipe directions stay aligned to the trackpad.")
                            Button("Restore default detection") { model.gymTuning = GestureTuning() }.controlSize(.small)
                        }.padding(.top, 12).disabled(model.isCalibrating)
            }
        }
    }

    private var practiceSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Practice").fontWeight(.medium)
                Picker("Practice gesture", selection: Binding(get: { model.gymGesture.kind }, set: {
                    model.gymGesture.kind = $0
                    model.gymGesture = model.gymGesture.normalized()
                })) {
                    ForEach(GestureKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.labelsHidden().frame(maxWidth: 195)
                Spacer(minLength: 0)
                Button("How to", systemImage: "questionmark.circle") { showHowTo.toggle() }.help("Show an illustrated example")
                Spacer(minLength: 0)
            }
            GestureFingerPicker(gesture: $model.gymGesture)
            Picker("Corner modifier", selection: Binding(get: { model.gymGesture.corner }, set: {
                model.gymGesture.corner = $0
                model.gymGesture = model.gymGesture.normalized()
            })) {
                ForEach(Corner.allCases) { corner in Text(corner.title).tag(corner) }
            }.frame(maxWidth: 350)
            if model.gymGesture.kind == .forceClick {
                Text(model.forceClickCapability(for: model.selectedDevice).message(includeClickTiming: false)).font(.caption).foregroundStyle(Theme.secondary)
            }
            if (model.gymGesture.kind == .click || model.gymGesture.kind == .forceClick) && !model.clicksAvailable {
                Label("Click practice needs Accessibility permission. Touch visualization still works.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }.disabled(model.isCalibrating)
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Tip-tap calibration").font(.headline); HelpHint("Use one resting finger and one tapping finger: three taps on each side learn angle, spacing, timing, and movement allowance. Corner and swipe settings stay manual.") }
                if model.isCalibrating { Button("Stop", action: model.stopCalibration) }
                else { Button(model.calibrationSamples.isEmpty ? "Calibrate tip-taps" : "Calibrate again", action: model.startCalibration)
                    .disabled(!model.devices.contains { $0.kind == model.selectedDevice }) }
            }
            Text(model.calibrationMessage == "Six tip-taps can teach the app your natural angle, spacing, and timing." ? "Three tip-taps on each side." : model.calibrationMessage).font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                sampleCount("Left", count: model.calibrationSamples.filter { $0.direction == .tipTapLeft }.count)
                sampleCount("Right", count: model.calibrationSamples.filter { $0.direction == .tipTapRight }.count)
                Spacer()
            }

        }
    }

    private func sampleCount(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(title) \(count)/3").font(.caption).frame(width: 58, alignment: .leading)
            ForEach(0..<3) { n in
                Image(systemName: n < count ? "checkmark.circle.fill" : "circle").foregroundStyle(n < count ? Theme.accent : .secondary)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(count) of 3 samples")
    }
    private func adjustment(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(display).monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(label).accessibilityValue(display)
        }
    }
    private func milliseconds(_ seconds: Double) -> String { "\(Int(seconds * 1000)) ms" }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}

struct GymDetectionReadout: View {
    @ObservedObject var readout: GymReadout
    let tuning: GestureTuning
    let target: GestureSpec
    private var snapshot: GymSnapshot { readout.snapshot }
    private var feedback: DetectionFeedback { snapshot.feedback }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: feedback.phase == .recognized ? "checkmark.circle.fill" : feedback.phase == .rejected ? "exclamationmark.circle" : "scope")
                    .foregroundStyle(feedback.phase == .recognized ? Color.green : feedback.phase == .rejected ? Color.orange : Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feedback.message).fontWeight(.medium)
                        .lineLimit(2, reservesSpace: true).help(feedback.message)
                        .accessibilityLabel(feedback.message)
                    Text("\(snapshot.contacts.count) \(snapshot.contacts.count == 1 ? "finger" : "fingers") · \(snapshot.deviceName)")
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                        .help(snapshot.deviceName)
                }
            }
            HStack(spacing: 0) {
                measurement("Rest", value: milliseconds(feedback.holdTime), limit: "min \(milliseconds(tuning.anchorHold))")
                measurement(target.kind == .longTouch ? "Hold" : "Tap", value: milliseconds(feedback.tapTime),
                            limit: target.kind == .longTouch ? "min \(milliseconds(tuning.longTouchDuration))" : "max \(milliseconds(tuning.tapDuration))")
                measurement("Movement", value: percent(feedback.travel), limit: "max \(percent(tuning.tapTravel))")
                measurement("Spacing", value: percent(abs(feedback.separation)), limit: "min \(percent(tuning.tipSeparation))")
            }
        }
    }

    private func measurement(_ label: String, value: String, limit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
            Text(limit).font(.caption2).foregroundStyle(Theme.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func milliseconds(_ seconds: Double) -> String { "\(Int(seconds * 1000)) ms" }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}

/// Device geometry can change with a new input device, without observing its
/// sampled diagnostics in either settings column.
private struct GymTouchPreview: View {
    @ObservedObject var readout: GymReadout
    let visualization: TouchVisualization
    let tuning: GestureTuning
    let target: GestureSpec
    var body: some View {
        GymTouchSurface(visualization: visualization, tuning: tuning, target: target)
            .aspectRatio(readout.snapshot.aspectRatio, contentMode: .fit)
    }
}

/// Measured detection geometry and trails, with display-synchronized finger positions.
struct GymTouchSurface: View {
    @ObservedObject var visualization: TouchVisualization
    private var snapshot: GymSnapshot { visualization.frame }
    let tuning: GestureTuning
    let target: GestureSpec
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let outline = Path(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12)
            context.fill(outline, with: .color(Theme.field))
            context.clip(to: outline)
            func point(_ p: TouchPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
            let anchor = point(snapshot.feedback.anchorPosition ?? .init(x: 0.5, y: 0.5))
            if target.kind.isAnchored {
                var axis = context
                axis.translateBy(x: anchor.x, y: anchor.y)
                axis.rotate(by: .degrees(-tuning.handAngleDegrees))
                let span = max(size.width, size.height) * 3
                let gap = tuning.tipSeparation * size.width
                axis.fill(Path(CGRect(x: -span, y: -span, width: span - gap, height: span * 2)), with: .color(.teal.opacity(0.09)))
                axis.fill(Path(CGRect(x: gap, y: -span, width: span, height: span * 2)), with: .color(.blue.opacity(0.09)))
                var line = Path(); line.move(to: CGPoint(x: -span, y: 0)); line.addLine(to: CGPoint(x: span, y: 0))
                axis.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                for (sign, title) in [(-1.0, "LEFT"), (1.0, "RIGHT")] {
                    let angle = tuning.handAngleDegrees * .pi / 180
                    let p = CGPoint(x: min(size.width - 34, max(34, anchor.x + sign * 92 * cos(angle))),
                                    y: min(size.height - 20, max(20, anchor.y - sign * 92 * sin(angle) - 15)))
                    context.draw(Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.secondary), at: p)
                }
            }
            if target.corner != .none {
                let left = target.corner == .topLeft || target.corner == .bottomLeft
                let top = target.corner == .topLeft || target.corner == .topRight
                let width = size.width * tuning.cornerSize, height = size.height * tuning.cornerSize
                let rect = CGRect(x: left ? 0 : size.width - width, y: top ? 0 : size.height - height, width: width, height: height)
                context.fill(Path(rect), with: .color(.orange.opacity(snapshot.modifier == target.corner ? 0.28 : 0.10)))
                context.stroke(Path(rect), with: .color(.orange.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for (id, samples) in snapshot.trails {
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    if index == 0 { path.move(to: point(sample)) } else { path.addLine(to: point(sample)) }
                }
                context.stroke(path, with: .color(color(id).opacity(0.45)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let position = snapshot.feedback.anchorPosition {
                let center = point(position)
                let tolerance = CGRect(x: center.x - tuning.tapTravel * size.width, y: center.y - tuning.tapTravel * size.height,
                                       width: tuning.tapTravel * size.width * 2, height: tuning.tapTravel * size.height * 2)
                context.stroke(Path(ellipseIn: tolerance), with: .color(.teal.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            // Ghosts retain the measured endpoints after release, so the result is inspectable.
            for (id, trail) in snapshot.trails {
                if let position = trail.last, !snapshot.contacts.contains(where: { $0.id == id }) {
                    let p = point(position)
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(color(id).opacity(0.5)), lineWidth: 1.5)
                }
            }
            for contact in snapshot.contacts {
                let p = point(contact.position)
                let color = visualization.press.kind == .touch ? color(contact.id) : visualization.press.kind.color
                let radius = 14 + 22 * contact.pressureSize
                context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(0.22)))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(color.opacity(0.65)), lineWidth: 1)
                let inner = 7 + 7 * contact.pressureSize
                context.fill(Path(ellipseIn: CGRect(x: p.x - inner, y: p.y - inner, width: inner * 2, height: inner * 2)), with: .color(color))
                let role = contact.id == snapshot.modifierFinger ? "corner" : contact.id == snapshot.feedback.anchorID ? "rest" : contact.id == snapshot.feedback.tapperID ? "tap" : "\(contact.id)"
                context.draw(Text(role).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.text), at: CGPoint(x: p.x, y: max(10, p.y - 23)))
            }
            if snapshot.feedback.phase == .idle {
                context.draw(Text("Touch your trackpad").font(.callout).foregroundColor(Theme.secondary), at: CGPoint(x: size.width / 2, y: size.height - 24))
            }
            context.stroke(outline, with: .color(Theme.separator), lineWidth: 1)
        }
        .overlay(PressureCaptureSurface())
        .background(TouchDisplayClock(visualization: visualization))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live trackpad: \(snapshot.contacts.count) fingers. Hand angle \(Int(tuning.handAngleDegrees)) degrees. \(snapshot.feedback.message)")
    }
    private func color(_ id: Int) -> Color {
        id == snapshot.modifierFinger ? .orange : id == snapshot.feedback.anchorID ? .teal : .blue
    }
}

/// History updates stay inside a fixed viewport instead of relaying out both panes.
struct GymAttemptsView: View {
    @ObservedObject var history: GymHistory
    @State private var atLatest = true
    @State private var visibleAttempt: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent attempts").font(.headline)
                Spacer()
                Button("Clear") { history.attempts = [] }.controlSize(.small).disabled(history.attempts.isEmpty)
            }
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.frame(height: 0).id("latest")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: AttemptTopPreference.self,
                                                   value: geometry.frame(in: .named("attempts")).minY)
                        })
                    if history.attempts.isEmpty {
                        Text("Try the selected gesture.").font(.callout).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(history.attempts.prefix(8)) { attempt in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: attempt.matched ? "checkmark.circle.fill" : attempt.recognized ? "arrow.turn.down.right" : "xmark.circle")
                                .foregroundStyle(attempt.matched ? Color.green : .secondary)
                            Text(attempt.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            Text(attempt.matched ? "Matched" : attempt.recognized ? "Other gesture" : "Rejected")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }.id(attempt.id)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: AttemptRowsPreference.self,
                                value: [attempt.id: geometry.frame(in: .named("attempts"))])
                        })
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
              }.coordinateSpace(name: "attempts").frame(height: 160)
               .onPreferenceChange(AttemptTopPreference.self) { atLatest = $0 >= -1 }
               .onPreferenceChange(AttemptRowsPreference.self) { rows in
                   visibleAttempt = rows.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }?.key
               }
               .onChange(of: history.attempts.first?.id) { _, _ in
                   if atLatest || history.attempts.isEmpty { proxy.scrollTo("latest", anchor: .top) }
                   else if let visibleAttempt, history.attempts.contains(where: { $0.id == visibleAttempt }) {
                       proxy.scrollTo(visibleAttempt, anchor: .top)
                   }
               }
            }
        }
    }
}

private struct AttemptTopPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct AttemptRowsPreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
