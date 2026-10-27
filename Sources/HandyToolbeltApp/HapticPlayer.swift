import AppKit
import HandyToolbeltCore

/// System haptics only: no helper, private actuator API, or persistent timer.
final class HapticPlayer {
    private var pending: [DispatchWorkItem] = []
    private var generation = 0
    private var lastPlayedAt = -Double.infinity
    private let emit: (HapticPattern.Pulse) -> Void

    init(emit: @escaping (HapticPattern.Pulse) -> Void = HapticPlayer.perform) { self.emit = emit }

    func play(_ pattern: HapticPattern) {
        let now = ProcessInfo.processInfo.systemUptime
        // Coalesce rapid duplicate recognitions without building a pulse backlog.
        guard pattern != .off else { cancel(); return }
        guard now - lastPlayedAt >= 0.08 else { return }
        cancel(); lastPlayedAt = now
        let token = generation
        for (delay, pulse) in pattern.pulses {
            if delay == 0 { emit(pulse) }
            else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.emit(pulse)
                }
                pending.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    func cancel() {
        generation += 1
        pending.forEach { $0.cancel() }; pending.removeAll()
    }

    private static func perform(_ pulse: HapticPattern.Pulse) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch pulse {
        case .alignment: pattern = .alignment
        case .generic: pattern = .generic
        case .levelChange: pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
