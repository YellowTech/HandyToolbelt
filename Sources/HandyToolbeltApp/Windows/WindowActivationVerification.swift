import Foundation

/// Activation requests and AXRaise are acknowledgements, not proof of focus.
/// This bounded observation policy is independent of AppKit and remote AX calls.
struct WindowActivationVerification {
    enum Decision: Equatable { case focused, wait, focusChanged, timedOut }
    let originPID: Int32?
    let targetPID: Int32
    let deadline: TimeInterval

    func evaluate(frontmostPID: Int32?, targetWindowFocused: Bool, now: TimeInterval) -> Decision {
        guard frontmostPID == originPID || frontmostPID == targetPID else { return .focusChanged }
        if frontmostPID == targetPID && targetWindowFocused { return .focused }
        return now >= deadline ? .timedOut : .wait
    }
}
