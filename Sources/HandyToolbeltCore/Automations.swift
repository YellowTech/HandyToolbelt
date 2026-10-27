import Foundation
import CryptoKit

/// Configuration and progress limits shared by validation and local control clients.
public enum ConfigurationLimits {
    public static let maximumNameLength = 120
    public static let maximumAutomationSteps = 32
    public static let maximumStackActions = 32
    public static let maximumStackBindings = 32
    public static let automationDelayRange: ClosedRange<Double> = 0...30
}

public struct AutomationStep: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var action: GestureAction?
    public var delay: Double?
    public init(id: UUID = UUID(), name: String, action: GestureAction? = nil, delay: Double? = nil) {
        self.id = id; self.name = name; self.action = action; self.delay = delay
    }
}
public struct SavedAutomation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [AutomationStep]
    public init(id: UUID = UUID(), name: String, steps: [AutomationStep] = []) { self.id = id; self.name = name; self.steps = steps }
}
public struct ConfigurationValidation: Codable, Sendable {
    public var errors: [String] = []
    public var warnings: [String] = []
    public var isValid: Bool { errors.isEmpty }
}
public extension AppConfiguration {
    func revision() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    func validation() -> ConfigurationValidation {
        var result = ConfigurationValidation()
        func error(_ text: String) { result.errors.append(text) }
        func bounded(_ text: String, _ maximum: Int, _ label: String, empty: Bool = false) {
            if text.count > maximum || (!empty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { error("\(label) must contain 1–\(maximum) characters.") }
        }
        func unique(_ ids: [UUID], _ label: String) { if Set(ids).count != ids.count { error("Duplicate \(label) IDs.") } }
        unique(stacks.map(\.id), "stack"); unique(stacks.flatMap { $0.bindings.map(\.id) }, "stack binding"); unique(stacks.flatMap { $0.startActions.map(\.id) }, "stack start action")
        unique(bindings.map(\.id), "binding"); unique(applicationGroups.map(\.id), "application group")
        unique(automations.map(\.id), "automation"); unique(automations.flatMap { $0.steps.map(\.id) }, "automation step")
        for group in applicationGroups { bounded(group.name, ConfigurationLimits.maximumNameLength, "App group name") }
        func actionErrors(_ action: GestureAction, _ label: String, nested: Bool) -> [String] {
            var errors: [String] = []
            if !action.isValid { errors.append("\(label): incomplete action.") }
            if action.kind == .automation {
                if nested { errors.append("\(label): nested automations are not supported.") }
                else if !automations.contains(where: { $0.id == action.automationID }) { errors.append("\(label): missing automation.") }
            }
            if action.applicationBundleIdentifier.count > 255 { errors.append("\(label): application bundle identifier exceeds 255 characters.") }
            if action.text.count > GestureAction.maximumTextLength { errors.append("\(label): text exceeds \(GestureAction.maximumTextLength) characters.") }
            if !action.textDuration.isFinite || !GestureAction.textDurationRange.contains(action.textDuration) { errors.append("\(label): text duration must be in \(GestureAction.textDurationRange) seconds.") }
            if action.script.count > GestureAction.maximumScriptLength { errors.append("\(label): AppleScript exceeds \(GestureAction.maximumScriptLength) characters.") }
            return errors
        }
        for binding in bindings {
            let label = "Binding \(binding.id)"
            let gesture = binding.gesture
            if !gesture.allowedFingerCounts().contains(gesture.fingers) { error("\(label): invalid finger count.") }
            if gesture.corner != .none && gesture.fingers > 4 { error("\(label): corner modifier needs one additional finger (maximum five total).") }
            var issues = actionErrors(binding.action, label, nested: false)
            if gesture.kind == .forceClick && binding.device != .trackpad { issues.append("\(label): Force click requires a Force Touch trackpad.") }
            if let group = binding.applicationGroupID, !applicationGroups.contains(where: { $0.id == group }) { issues.append("\(label): missing app group.") }
            if binding.isEnabled { result.errors += issues } else { result.warnings += issues }
            if hasConflict(binding) { error("\(label): overlaps an enabled binding for the same gesture and scope.") }
        }
        for stack in stacks {
            let label = "Stack \(stack.name)"
            var issues: [String] = []
            if stack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stack.name.count > ConfigurationLimits.maximumNameLength { issues.append("\(label): name must contain 1–\(ConfigurationLimits.maximumNameLength) characters.") }
            if stack.corner == .none { issues.append("\(label): a held corner is required.") }
            if let group = stack.applicationGroupID, !applicationGroups.contains(where: { $0.id == group }) { issues.append("\(label): missing app group.") }
            if stack.startActions.count > ConfigurationLimits.maximumStackActions || stack.releaseActions.count > ConfigurationLimits.maximumStackActions || stack.bindings.count > ConfigurationLimits.maximumStackBindings { issues.append("\(label): each phase and child list is limited to 32 entries.") }
            for start in stack.startActions {
                if start.kind == .action { issues += actionErrors(start.action, label, nested: false) }
                else if start.modifiers.isEmpty { issues.append("\(label): Hold Modifiers needs at least one modifier.") }
            }
            for action in stack.releaseActions { issues += actionErrors(action, label, nested: false) }
            for child in stack.bindings {
                var childIssues: [String] = []
                if stack.device != .trackpad && child.gesture.kind == .forceClick { childIssues.append("\(label): Force click requires a Force Touch trackpad.") }
                if child.gesture.corner != .none || !child.gesture.allowedFingerCounts(isStackChild: true).contains(child.gesture.fingers) { childIssues.append("\(label): child gestures need 1–4 fingers and no corner; anchored gestures need 2–4 fingers, and middle tip-taps need three.") }
                if !(1...ConfigurationLimits.maximumStackActions).contains(child.actions.count) { childIssues.append("\(label): child gestures need 1–32 actions.") }
                for action in child.actions { childIssues += actionErrors(action, label, nested: false) }
                if child.isEnabled {
                    if stack.bindings.contains(where: { $0.id != child.id && $0.isEnabled && $0.gesture == child.gesture && $0.keyboardModifiers.overlaps(child.keyboardModifiers) }) { childIssues.append("\(label): overlapping enabled child gestures.") }
                    issues += childIssues
                } else { result.warnings += childIssues }
            }
            if stack.isEnabled { result.errors += issues } else { result.warnings += issues }
            result.errors += conflictMessages(for: stack).map { "\(label): \($0)" }
        }
        for automation in automations {
            bounded(automation.name, ConfigurationLimits.maximumNameLength, "Automation name")
            if !(1...ConfigurationLimits.maximumAutomationSteps).contains(automation.steps.count) { error("Automation \(automation.name) must contain 1–\(ConfigurationLimits.maximumAutomationSteps) steps.") }
            for step in automation.steps {
                bounded(step.name, ConfigurationLimits.maximumNameLength, "Step name")
                if (step.action == nil) == (step.delay == nil) { error("Step \(step.name) needs exactly one action or delay.") }
                if let delay = step.delay, !delay.isFinite || !ConfigurationLimits.automationDelayRange.contains(delay) { error("Step \(step.name): wait must be in \(ConfigurationLimits.automationDelayRange) seconds.") }
                if let action = step.action { result.errors += actionErrors(action, "Step \(step.name)", nested: true) }
            }
        }
        for (label, tuning) in [("Trackpad", trackpadTuning), ("Mouse", mouseTuning)] {
            if tuning != tuning.validated { error("\(label) tuning contains nonfinite or out-of-range values.") }
        }
        return result
    }
}

public enum WorkflowState: String, Codable, CaseIterable, Sendable {
    case pending, running, completed, failed, cancelling, cancelled
    public static let progressStepStates: [Self] = [.pending, .running, .completed, .failed]
}
public struct WorkflowStepStatus: Codable, Equatable, Sendable {
    public var name: String
    public var state: WorkflowState
    public var message: String?
    public init(name: String, state: WorkflowState = .pending, message: String? = nil) { self.name = name; self.state = state; self.message = message }
}
public struct WorkflowProgress: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var steps: [WorkflowStepStatus]
    public var state: WorkflowState = .running
    public var message: String?
    public var completedCount: Int { steps.filter { $0.state == .completed }.count }
    public init(id: UUID = UUID(), title: String, steps: [String]) { self.id = id; self.title = title; self.steps = steps.map { .init(name: $0) } }
}
/// Pure metadata model. A caller schedules a single shot for nextExpiry and invokes expire().
public struct ProgressSessions {
    public enum Lifetime {
        case external
        /// The in-process runner sends a terminal update when its run ends.
        case automation
    }
    public struct Session {
        public var progress: WorkflowProgress
        public var deadline: TimeInterval?
        public var screenID: String?
        fileprivate var lifetime: Lifetime
    }
    public private(set) var sessions: [Session] = []
    private let now: () -> TimeInterval
    public init(now: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }) { self.now = now }
    public var latest: Session? { sessions.last(where: { [.running, .cancelling].contains($0.progress.state) }) ?? sessions.last }
    public var nextExpiry: TimeInterval? { sessions.compactMap(\.deadline).min() }
    public mutating func begin(_ progress: WorkflowProgress, screenID: String? = nil, lifetime: Lifetime = .external) {
        expire(); sessions.removeAll { $0.progress.id == progress.id }
        sessions.append(.init(progress: progress, deadline: deadline(for: progress.state, lifetime: lifetime), screenID: screenID, lifetime: lifetime))
        if sessions.count > 4 { sessions.removeFirst(sessions.count - 4) }
    }
    @discardableResult public mutating func update(_ progress: WorkflowProgress) -> Bool {
        expire()
        guard let index = sessions.firstIndex(where: { $0.progress.id == progress.id }) else { return false }
        sessions[index].progress = progress
        sessions[index].deadline = deadline(for: progress.state, lifetime: sessions[index].lifetime)
        return true
    }
    private func deadline(for state: WorkflowState, lifetime: Lifetime) -> TimeInterval? {
        if [.completed, .failed, .cancelled].contains(state) { return now() + (state == .completed ? 1 : 3) }
        return lifetime == .external ? now() + 30 : nil
    }
    public mutating func dismiss(_ id: UUID? = nil) { if let id { sessions.removeAll { $0.progress.id == id } } else { sessions.removeAll() } }
    public mutating func expire() { let time = now(); sessions.removeAll { $0.deadline.map { $0 <= time } ?? false } }
}
