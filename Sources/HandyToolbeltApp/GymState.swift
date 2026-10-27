import Foundation
import Combine
import HandyToolbeltCore

struct GymSnapshot: Equatable {
    var contacts: [Contact] = []
    var trails: [Int: [TouchPoint]] = [:]
    var feedback = DetectionFeedback()
    var modifier: Corner = .none
    var modifierFinger: Int?
    var aspectRatio: Double = 1.6
    var measuredAspect = false
    var deviceName = "Waiting for touches"
}

struct GymAttempt: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let matched: Bool
    let recognized: Bool
}

/// Sampled diagnostic text has its own observation boundary, below the forms.
final class GymReadout: ObservableObject {
    @Published private(set) var snapshot = GymSnapshot()
    func update(_ next: GymSnapshot) {
        if snapshot != next { snapshot = next }
    }
}

/// Attempt history changes only the independently scrolling history view.
final class GymHistory: ObservableObject {
    @Published var attempts: [GymAttempt] = []
}
