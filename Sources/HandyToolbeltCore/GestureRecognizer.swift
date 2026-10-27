import Foundation

public struct TouchPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
}

public struct Contact: Identifiable, Equatable, Sendable {
    public var id: Int
    public var position: TouchPoint
    /// Optional, uncalibrated device force signal. Never used for gesture recognition.
    public var pressure: Double?
    public init(id: Int, x: Double, y: Double, pressure: Double? = nil) {
        self.id = id; position = .init(x: x, y: y)
        self.pressure = pressure.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// A bounded visual cue, not a percentage of physical force.
    public var pressureIntensity: Double {
        guard let pressure, pressure.isFinite, pressure > 0 else { return 0 }
        return 1 - 1 / (1 + pressure)
    }

    /// Convex size curve: firmer levels separate more visibly than light touches.
    /// The input is bounded before exponentiation, including malformed device data.
    public var pressureSize: Double { expm1(2.4 * pressureIntensity) / expm1(2.4) }
}

/// All state belongs to one physical device. Positions are normalized, with y increasing upwards.
/// Platform events and action dispatch stay outside this deterministic recognizer.
public struct GestureRecognizer {
    public typealias Tuning = GestureTuning
    private struct Track {
        var start: TouchPoint
        var position: TouchPoint
        var began: Double
        var travel: Double = 0
        var samples: [(Double, TouchPoint)] = []
    }
    private struct Chord {
        var began: Double
        var origins: [Int: TouchPoint]
        var peak = 0
        var peakSince: Double
        var travel: Double = 0
        var cancelled = false
        var emitted = false
        var corner: Corner
        var longEmitted = false
        var temporalSpecs: Set<GestureSpec> = []
        var lostMembers = false
    }
    private struct Tip {
        var anchors: Set<Int>
        var tapper: Int
        var began: Double
        var kind: GestureKind
        var corner: Corner
        var emitted = false
        var origins: [Int: TouchPoint] = [:]
        var temporalSpecs: Set<GestureSpec> = []
    }
    public var tuning = Tuning()
    public var surfaceAspectRatio = 1.6
    /// Disable for devices whose normalized contact surface has different edge semantics.
    public var usesTrackpadEdgeDeadzone = true
    public private(set) var feedback = DetectionFeedback()
    /// Increments for completed/rejected attempts, allowing the gym to keep a bounded history.
    public private(set) var feedbackSequence = 0
    public private(set) var modifier: Corner = .none
    public private(set) var modifierFinger: Int?
    public private(set) var contacts: [Contact] = []
    private var tracks: [Int: Track] = [:]
    private var chord: Chord?
    private var tip: Tip?
    private var waitForRelease = false
    private var lastTime: Double?
    private var lastClick: Double = -.infinity
    private struct PendingTap {
        var spec: GestureSpec
        var position: TouchPoint
        var deadline: Double
        var secondBegan: Double?
    }
    private struct PendingTip {
        var spec: GestureSpec
        var anchors: Set<Int>
        var origins: [Int: TouchPoint]
        var position: TouchPoint
        var deadline: Double
        var secondBegan = false
    }
    private var pendingTip: PendingTip?
    private var pendingTap: PendingTap?
    public var nextDeadline: Double? { [pendingTap.flatMap { $0.secondBegan == nil ? $0.deadline : nil }, pendingTip.flatMap { !$0.secondBegan ? $0.deadline : nil }].compactMap { $0 }.min() }
    /// Cancels reservations as well as a deferred single tap. The current free-finger chord must lift.
    public mutating func cancelTemporalGestures() {
        pendingTap = nil; pendingTip = nil; tip?.temporalSpecs = []
        tip?.emitted = true
        chord?.temporalSpecs = []
        chord?.cancelled = true
    }
    /// Only deferred single taps use deadlines. Holds always require a fresh hardware frame.
    public mutating func advanceTime(to time: Double) -> [GestureSpec] {
        guard time.isFinite else { return [] }
        var events: [GestureSpec] = []
        if let pending = pendingTap, pending.secondBegan == nil, time >= pending.deadline {
            pendingTap = nil; events.append(pending.spec)
        }
        if let pending = pendingTip, !pending.secondBegan, time >= pending.deadline {
            pendingTip = nil; events.append(pending.spec)
        }
        for event in events { feedback.gesture = event; report(.recognized, event.title) }
        return events
    }

    public init() {}

    public mutating func reset() {
        pendingTip = nil; tracks = [:]; contacts = []; chord = nil; tip = nil; pendingTap = nil
        modifier = .none; modifierFinger = nil; waitForRelease = false; lastTime = nil
        feedback = DetectionFeedback()
    }

    /// Only corners used by enabled bindings are reserved as modifiers.
    public mutating func process(_ input: [Contact], at time: Double, enabledCorners: Set<Corner> = [], physicalButtonDown: Bool = false, eligibleTemporalSpecs: Set<GestureSpec> = []) -> [GestureSpec] {
        guard time.isFinite else { reset(); return [] }
        if let lastTime, time < lastTime || time - lastTime > 0.8 { reset() }
        lastTime = time
        guard input.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && (0...1).contains($0.position.x) && (0...1).contains($0.position.y) }) else {
            reset(); return []
        }
        let ids = Set(input.map(\.id))
        guard ids.count == input.count, input.count <= 10 else { reset(); return [] }
        let old = tracks
        let newIDs = ids.subtracting(old.keys)
        contacts = input
        feedback.fingerCount = input.count
        if !newIDs.isEmpty && tip == nil { feedback = DetectionFeedback(); feedback.fingerCount = input.count }
        for contact in input {
            var t = tracks[contact.id] ?? Track(start: contact.position, position: contact.position, began: time)
            t.samples.append((time, contact.position))
            // Keep one sample at or before the hold window, plus bounded recent hardware samples.
            while t.samples.count > 2 && t.samples[1].0 <= time - tuning.anchorHold { t.samples.removeFirst() }
            if t.samples.count > 256 { t.samples.removeFirst(t.samples.count - 256) }
            t.position = contact.position
            t.travel = max(t.travel, t.start.distance(to: contact.position))
            tracks[contact.id] = t
        }
        // A second touch reserves the first tap only if its onset is inside the window.
        let oldFree = Set(old.keys).subtracting(modifierFinger.map { [$0] } ?? [])
        let incomingFree = ids.subtracting(modifierFinger.map { [$0] } ?? [])
        if var pending = pendingTap, pending.secondBegan == nil, oldFree.isEmpty, !incomingFree.isEmpty, time <= pending.deadline {
            pending.secondBegan = time; pendingTap = pending
        }
        if physicalButtonDown || (modifierFinger.map { !ids.contains($0) || (tracks[$0]?.travel ?? 1) > tuning.tapTravel || !enabledCorners.contains(modifier) } ?? false) { pendingTap = nil }
        if let pending = pendingTip {
            let double = pending.spec.kind.doubleTipTapKind.map { GestureSpec(kind: $0, fingers: pending.spec.fingers, corner: pending.spec.corner) }
            if physicalButtonDown || !pending.anchors.isSubset(of: ids) || pending.spec.corner != modifier ||
                ids.subtracting(modifierFinger.map { [$0] } ?? []).subtracting(pending.anchors).count > 1 ||
                !(double.map { eligibleTemporalSpecs.contains($0) } ?? false) || pending.anchors.contains(where: { id in
                    guard let position = tracks[id]?.position, let origin = pending.origins[id] else { return true }
                    return position.distance(to: origin) > tuning.tapTravel
                }) { pendingTip = nil }
        }
        var events = advanceTime(to: time)

        // A lifted or moved modifier cannot silently become an ordinary gesture.
        if let anchor = modifierFinger,
           !ids.contains(anchor) || (tracks[anchor]?.travel ?? 1) > tuning.tapTravel || !enabledCorners.contains(modifier) {
            chord = nil; tip = nil; pendingTap = nil; pendingTip = nil; modifier = .none; modifierFinger = nil
            waitForRelease = !ids.isEmpty
            report(.rejected, "Corner finger lifted or moved. Lift all fingers and try again.")
        }
        if modifierFinger == nil && !waitForRelease {
            for id in ids.sorted() {
                guard let t = tracks[id], time - t.began >= tuning.cornerHold, t.travel <= tuning.tapTravel,
                      let corner = Corner.allCases.first(where: { enabledCorners.contains($0) && $0.contains(t.start, size: tuning.cornerSize) && $0.contains(t.position, size: tuning.cornerSize) }) else { continue }
                modifier = corner; modifierFinger = id; chord = nil; tip = nil; pendingTap = nil; pendingTip = nil
                feedback = DetectionFeedback()
                feedback.phase = .holding; feedback.fingerCount = input.count
                feedback.message = "Corner hold ready. Use your other fingers for the gesture."
                break
            }
        }
        let freeIDs = ids.subtracting(modifierFinger.map { [$0] } ?? [])
        if !waitForRelease {
            // Every pre-existing free finger must qualify as a stationary anchor.
            if tip == nil, chord?.longEmitted != true, (2...4).contains(freeIDs.count), input.count <= 5,
               newIDs.intersection(freeIDs).count == 1,
               let tapper = newIDs.intersection(freeIDs).first, let tapping = tracks[tapper] {
                let anchors = freeIDs.subtracting([tapper])
                let held = anchors.compactMap { old[$0] }
                if held.count == anchors.count {
                    let separations = held.map { tuning.projectedSeparation(from: $0.position, to: tapping.position, aspectRatio: surfaceAspectRatio) }
                    let settled = held.allSatisfy { track in
                        guard let first = track.samples.first, time - first.0 >= tuning.anchorHold else { return false }
                        return track.samples.allSatisfy { $0.1.distance(to: track.position) <= tuning.tapTravel }
                    }
                    let interior = !usesTrackpadEdgeDeadzone || held.allSatisfy { track in
                        let p = track.position, rim = tuning.tipEdgeDeadzone
                        return p.x >= rim && p.x <= 1 - rim && p.y >= rim && p.y <= 1 - rim
                    }
                    let points = held.map(\.position) + [tapping.position]
                    let nearby = points.allSatisfy { a in points.allSatisfy { b in
                        hypot(a.x - b.x, (a.y - b.y) / Tuning.safeAspect(surfaceAspectRatio)) <= tuning.tipMaxSeparation + 1e-9
                    } }
                    let ready = settled && interior && nearby
                    let left = separations.allSatisfy { $0 <= -tuning.tipSeparation }
                    let right = separations.allSatisfy { $0 >= tuning.tipSeparation }
                    let middle = anchors.count == 2 && separations.contains { $0 <= -tuning.tipSeparation } && separations.contains { $0 >= tuning.tipSeparation }
                    feedback.anchorID = anchors.min(); feedback.tapperID = tapper
                    feedback.anchorPosition = centroid(held.map(\.position)); feedback.tapperPosition = tapping.position
                    feedback.holdTime = held.map { time - $0.began }.min() ?? 0
                    feedback.separation = separations.min(by: { abs($0) < abs($1) }) ?? 0
                    if ready && (left || right || middle) {
                        tip = Tip(anchors: anchors, tapper: tapper, began: time,
                                  kind: middle ? .tipTapMiddle : (left ? .tipTapLeft : .tipTapRight), corner: modifier,
                                  origins: Dictionary(uniqueKeysWithValues: anchors.compactMap { id in old[id].map { (id, $0.position) } }), temporalSpecs: eligibleTemporalSpecs)
                        if let pending = pendingTip {
                            let spec = GestureSpec(kind: middle ? .tipTapMiddle : (left ? .tipTapLeft : .tipTapRight), fingers: anchors.count + 1, corner: modifier)
                            if !pending.secondBegan && time <= pending.deadline && pending.spec == spec && pending.anchors == anchors && pending.position.distance(to: tapping.position) <= tuning.tapTravel * 2 {
                                pendingTip?.secondBegan = true
                            } else {
                                // A valid tip on another side or at another position starts a
                                // separate sequence; it must not swallow the completed single.
                                if pending.anchors == anchors { events.append(pending.spec) }
                                pendingTip = nil
                            }
                        }
                        feedback.phase = .candidate
                        feedback.message = "Active finger found. Tap or swipe while the resting fingers stay down."
                        chord?.cancelled = true
                    } else if ready {
                        report(.rejected, "Fingers are too close along the hand axis.")
                        chord?.cancelled = true
                    } else {
                        report(.rejected, !interior ? "Move resting fingers away from the trackpad edge." : (!nearby ? "Bring the fingers closer together for an anchored gesture." : "Resting fingers must settle and stay still long enough."))
                    }
                }
            }
            if var candidate = tip {
                let anchors = candidate.anchors.compactMap { tracks[$0] }
                let active = tracks[candidate.tapper]
                feedback.tapTime = time - candidate.began
                let anchorDistances = candidate.anchors.compactMap { id -> Double? in
                    guard let track = tracks[id], let origin = candidate.origins[id] else { return nil }
                    return track.position.distance(to: origin)
                }
                let anchorMoved = anchorDistances.count != candidate.anchors.count || anchorDistances.contains { $0 > tuning.tapTravel }
                feedback.travel = max(anchorDistances.max() ?? 0, active?.travel ?? 0)
                feedback.anchorPosition = centroid(anchors.map(\.position)); feedback.tapperPosition = active?.position
                let expected = candidate.anchors.union([candidate.tapper])
                let rejection: String?
                if !candidate.anchors.isSubset(of: freeIDs) { rejection = "Resting finger lifted before the gesture finished." }
                else if !freeIDs.isSubset(of: expected) || input.count > 5 { rejection = "An extra or replaced finger joined the gesture." }
                else if anchorMoved { rejection = "Resting finger moved beyond the movement allowance." }
                else if physicalButtonDown { rejection = "Physical click detected. Tap without pressing." }
                else { rejection = nil }
                if let rejection {
                    report(.rejected, rejection)
                    // Raw button samples and the click event may arrive in either order.
                    // Preserve ordinary click dispatch only for an intact, un-emitted candidate.
                    let clickMayDispatch = physicalButtonDown && !candidate.emitted &&
                        candidate.anchors.isSubset(of: freeIDs) && freeIDs.isSubset(of: expected) &&
                        input.count <= 5 && !anchorMoved
                    tip = nil; pendingTip = nil; chord?.cancelled = true
                    waitForRelease = !ids.isEmpty && !clickMayDispatch
                } else if !freeIDs.contains(candidate.tapper) {
                    if !candidate.emitted, let active, let doubleKind = candidate.kind.doubleTipTapKind, time - candidate.began <= tuning.tapDuration && active.travel <= tuning.tapTravel {
                        let single = GestureSpec(kind: candidate.kind, fingers: candidate.anchors.count + 1, corner: candidate.corner)
                        let double = GestureSpec(kind: doubleKind, fingers: single.fingers, corner: single.corner)
                        if let pending = pendingTip, pending.secondBegan {
                            if pending.spec == single && candidate.temporalSpecs.contains(double) && eligibleTemporalSpecs.contains(double) { events.append(double) }
                            pendingTip = nil
                        } else if candidate.temporalSpecs.contains(double) && eligibleTemporalSpecs.contains(double) {
                            pendingTip = PendingTip(spec: single, anchors: candidate.anchors, origins: candidate.origins, position: active.start, deadline: time + tuning.doubleTapInterval)
                        } else { events.append(single) }
                    } else if !candidate.emitted {
                        pendingTip = nil
                        report(.rejected, "Active finger moved too far for a tap or was held too long.")
                    }
                    tip = nil
                } else if !candidate.emitted, let active {
                    let dx = active.position.x - active.start.x, dy = active.position.y - active.start.y
                    let horizontal = abs(dx) > abs(dy) * 1.4
                    let vertical = abs(dy) > abs(dx) * 1.4
                    if (horizontal && abs(dx) >= tuning.swipeTravel) || (vertical && abs(dy) >= tuning.swipeTravel) {
                        let kind: GestureKind = horizontal ? (dx < 0 ? .tipSwipeLeft : .tipSwipeRight) : (dy < 0 ? .tipSwipeDown : .tipSwipeUp)
                        pendingTip = nil
                        events.append(.init(kind: kind, fingers: candidate.anchors.count + 1, corner: candidate.corner))
                        candidate.emitted = true; tip = candidate
                    } else if time - candidate.began > tuning.tapDuration {
                        // A slow anchored swipe is still valid after the tap window closes.
                        // Count a failed tap only on release, not during an unfinished swipe.
                        feedback.phase = .candidate
                        feedback.message = "Held too long for a tap. Swipe or lift the active finger."
                    }
                }
            }
            if tip == nil && events.isEmpty && freeIDs.count == 1 && feedback.phase != .recognized && feedback.phase != .rejected,
               let id = freeIDs.first, let held = tracks[id] {
                feedback.phase = .holding
                feedback.anchorID = id; feedback.anchorPosition = held.position
                feedback.holdTime = time - held.began; feedback.travel = held.travel
                let recentTravel = held.samples.map { $0.1.distance(to: held.position) }.max() ?? 0
                feedback.travel = recentTravel
                feedback.message = recentTravel > tuning.tapTravel ? "Keep the resting finger still to let it settle." :
                    (feedback.holdTime >= tuning.anchorHold ? "Resting finger ready. Tap on either side." : "Hold the resting finger a little longer…")
            }
            if !events.isEmpty || tip != nil { pendingTap = nil }
            if chord == nil && !freeIDs.isEmpty {
                chord = Chord(began: time, origins: [:], peakSince: time, corner: modifier, temporalSpecs: eligibleTemporalSpecs)
                if tip != nil || events.contains(where: { $0.kind.isAnchored }) { chord?.cancelled = true }
            }
            if var group = chord {
                if !Set(group.origins.keys).isSubset(of: freeIDs) { group.lostMembers = true }
                if group.lostMembers && !freeIDs.isSubset(of: Set(group.origins.keys)) { group.cancelled = true }
                for id in freeIDs {
                    guard let track = tracks[id] else { continue }
                    if group.origins[id] == nil {
                        // Adding/replacing fingers late must not produce an accidental chord.
                        if time - group.began > 0.13 { group.cancelled = true }
                        group.origins[id] = track.position
                    }
                    group.travel = max(group.travel, group.origins[id]!.distance(to: track.position))
                }
                if freeIDs.count > group.peak { group.peak = freeIDs.count; group.peakSince = time }
                if tip == nil && group.peak >= 2 && !group.cancelled && !group.emitted {
                    feedback.phase = .candidate; feedback.message = "\(group.peak) fingers touching. Tap, click, or move together."
                    feedback.tapTime = time - group.began; feedback.travel = group.travel
                }
                if physicalButtonDown { group.cancelled = true; tip = nil }
                let long = GestureSpec(kind: .longTouch, fingers: group.peak, corner: group.corner)
                if !group.cancelled && !group.emitted && !group.lostMembers && tip == nil &&
                    group.temporalSpecs.contains(long) && eligibleTemporalSpecs.contains(long) &&
                    freeIDs.count == group.peak && group.travel <= tuning.tapTravel && time - group.peakSince >= tuning.longTouchDuration {
                    events.append(long); group.emitted = true; group.longEmitted = true; pendingTap = nil
                }
                if let pending = pendingTap, pending.secondBegan != nil,
                   group.cancelled || group.emitted || group.travel > tuning.tapTravel || time - group.began > tuning.tapDuration {
                    pendingTap = nil
                }
                let minimumFingers = group.corner == .none ? 2 : 1
                if !group.cancelled && !group.emitted && group.peak >= minimumFingers && group.peak <= (group.corner == .none ? 5 : 4) &&
                    freeIDs.count == group.peak && time - group.peakSince >= 0.045 {
                    let movements = freeIDs.compactMap { id -> TouchPoint? in
                        guard let start = group.origins[id], let current = tracks[id]?.position else { return nil }
                        return .init(x: current.x - start.x, y: current.y - start.y)
                    }
                    let n = Double(movements.count)
                    let dx = movements.reduce(0) { $0 + $1.x } / n
                    let dy = movements.reduce(0) { $0 + $1.y } / n
                    let horizontal = abs(dx) > abs(dy) * 1.4
                    let vertical = abs(dy) > abs(dx) * 1.4
                    // All fingers must move in the same direction, rejecting pinches and rotations.
                    let coherent = movements.allSatisfy { p in
                        horizontal ? p.x * dx > 0 && abs(p.x) >= tuning.swipeTravel * 0.55 : p.y * dy > 0 && abs(p.y) >= tuning.swipeTravel * 0.55
                    }
                    if coherent && ((horizontal && abs(dx) >= tuning.swipeTravel) || (vertical && abs(dy) >= tuning.swipeTravel)) {
                        let kind: GestureKind = horizontal ? (dx < 0 ? .swipeLeft : .swipeRight) : (dy < 0 ? .swipeDown : .swipeUp)
                        events.append(.init(kind: kind, fingers: group.peak, corner: group.corner))
                        group.emitted = true
                    }
                }
                if freeIDs.isEmpty {
                    if !group.cancelled && !group.emitted && group.peak >= minimumFingers && group.peak <= (group.corner == .none ? 5 : 4) &&
                        time - group.began <= tuning.tapDuration && time - group.peakSince >= 0.035 && group.travel <= tuning.tapTravel {
                        let tap = GestureSpec(kind: .tap, fingers: group.peak, corner: group.corner)
                        let double = GestureSpec(kind: .doubleTap, fingers: group.peak, corner: group.corner)
                        let position = centroid(Array(group.origins.values))!
                        if let pending = pendingTap, pending.secondBegan != nil {
                            // Two tapTravel radii allow natural placement drift without pairing distant chords.
                            if pending.spec == tap && pending.position.distance(to: position) <= tuning.tapTravel * 2 &&
                                group.temporalSpecs.contains(double) && eligibleTemporalSpecs.contains(double) {
                                events.append(double)
                            }
                            pendingTap = nil
                        } else if group.temporalSpecs.contains(double) && eligibleTemporalSpecs.contains(double) {
                            pendingTap = PendingTap(spec: tap, position: position, deadline: time + tuning.doubleTapInterval)
                        } else { events.append(tap) }
                    } else if group.peak >= minimumFingers && !group.emitted && feedback.phase != .rejected && feedback.phase != .recognized {
                        report(.rejected, group.cancelled ? "Finger count changed too late, or a physical click interrupted the tap." :
                            (group.travel > tuning.tapTravel ? "Fingers moved too far for a tap." : "Tap timing was outside the allowed range."))
                    }
                    if pendingTap?.secondBegan != nil { pendingTap = nil }
                    chord = nil
                } else { chord = group }
            }
        }
        tracks = tracks.filter { ids.contains($0.key) }
        if ids.isEmpty { waitForRelease = false; chord = nil; tip = nil }
        for event in events {
            feedback.gesture = event
            report(.recognized, event.title)
        }
        return events
    }

    public mutating func physicalClick(at time: Double) -> GestureSpec? {
        beginPhysicalPress(at: time, allowSingleFinger: false, reportsClick: true)
    }

    /// Captures native mouse-down membership; force is recognized only by a later OS stage event.
    public mutating func beginPhysicalPress(at time: Double, allowSingleFinger: Bool, reportsClick: Bool = false) -> GestureSpec? {
        let wasAnchored = tip?.emitted == true
        let wasLongTouch = chord?.longEmitted == true
        pendingTap = nil; pendingTip = nil
        chord?.cancelled = true; tip = nil
        if wasLongTouch { return nil }
        if wasAnchored { waitForRelease = !contacts.isEmpty; return nil }
        let count = contacts.count - (modifierFinger == nil ? 0 : 1)
        guard !waitForRelease, let lastTime, time - lastTime < 0.15, time - lastClick > 0.08,
              count >= (modifier == .none && !allowSingleFinger ? 2 : 1) && count <= (modifier == .none ? 5 : 4) else { return nil }
        lastClick = time
        let result = GestureSpec(kind: .click, fingers: count, corner: modifier)
        if reportsClick { feedback.gesture = result; report(.recognized, result.title) }
        return result
    }

    private func centroid(_ points: [TouchPoint]) -> TouchPoint? {
        guard !points.isEmpty else { return nil }
        return .init(x: points.reduce(0) { $0 + $1.x } / Double(points.count), y: points.reduce(0) { $0 + $1.y } / Double(points.count))
    }

    private mutating func report(_ phase: DetectionPhase, _ message: String) {
        feedback.phase = phase; feedback.message = message; feedbackSequence += 1
    }
}
