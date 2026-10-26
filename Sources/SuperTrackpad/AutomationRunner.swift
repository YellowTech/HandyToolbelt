import Foundation
import Combine
import SuperTrackpadCore

/// Main-thread sequential runner. In-flight native actions finish before cancellation settles.
final class AutomationRunner: ObservableObject {
    typealias Execute = (GestureAction, @escaping (Result<String, Error>) -> Void) -> Void
    typealias Schedule = (Double, @escaping () -> Void) -> (() -> Void)
    @Published private(set) var history: [WorkflowProgress] = []
    var onProgress: ((WorkflowProgress, Bool) -> Void)?
    var isAllowed: () -> Bool = { true }
    private let execute: Execute
    private let schedule: Schedule
    private var automation: SavedAutomation?
    private var activeID: UUID?
    private var cancelWait: (() -> Void)?
    private var actionInFlight = false
    private var currentStep = -1
    init(execute: @escaping Execute, schedule: @escaping Schedule = { delay, body in
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }) { self.execute = execute; self.schedule = schedule }
    var active: WorkflowProgress? { history.first { $0.id == activeID } }
    func status(_ id: UUID) -> WorkflowProgress? { history.first { $0.id == id } }
    @discardableResult func start(_ automation: SavedAutomation) throws -> WorkflowProgress {
        guard activeID == nil else { throw RunnerError.message("An automation is already running.") }
        guard isAllowed() else { throw RunnerError.message("The session is unavailable.") }
        var config = AppConfiguration(); config.bindings = []; config.automations = [automation]
        guard config.validation().isValid else { throw RunnerError.message(config.validation().errors.joined(separator: " ")) }
        let progress = WorkflowProgress(title: automation.name, steps: automation.steps.map(\.name))
        self.automation = automation; activeID = progress.id; history.append(progress)
        if history.count > 20 { history.removeFirst(history.count - 20) }
        onProgress?(progress, true)
        // Return the run ID before executing even a synchronous action.
        DispatchQueue.main.async { [weak self] in self?.advance(progress.id, index: 0) }
        return progress
    }
    @discardableResult func cancel(_ id: UUID) -> WorkflowProgress? {
        guard activeID == id else { return status(id) }
        cancelWait?(); cancelWait = nil
        mutate(id) { $0.state = actionInFlight ? .cancelling : .cancelled; $0.message = actionInFlight ? "Waiting for the current action to return." : "Cancelled" }
        if !actionInFlight { finishCancellation(id) }
        return status(id)
    }
    func stop() { if let activeID { _ = cancel(activeID) } }
    private func mutate(_ id: UUID, _ body: (inout WorkflowProgress) -> Void) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        body(&history[index]); onProgress?(history[index], false)
    }
    private func finishCancellation(_ id: UUID) {
        mutate(id) { progress in
            progress.state = .cancelled
            for index in progress.steps.indices where progress.steps[index].state == .running { progress.steps[index].state = .cancelled }
        }
        activeID = nil; automation = nil; actionInFlight = false
    }
    private func advance(_ id: UUID, index: Int) {
        guard activeID == id, let automation else { return }
        guard isAllowed(), status(id)?.state == .running else { _ = cancel(id); return }
        guard index < automation.steps.count else {
            mutate(id) { $0.state = .completed }; activeID = nil; self.automation = nil; return
        }
        currentStep = index
        let step = automation.steps[index]
        mutate(id) { $0.steps[index].state = .running }
        if let delay = step.delay {
            cancelWait = schedule(delay) { [weak self] in
                guard let self, self.activeID == id, self.status(id)?.state == .running else { return }
                self.cancelWait = nil
                self.mutate(id) { $0.steps[index].state = .completed }
                self.advance(id, index: index + 1)
            }
        } else if let action = step.action {
            actionInFlight = true
            execute(action) { [weak self] result in
                guard let self, self.activeID == id, self.currentStep == index, self.actionInFlight else { return }
                self.actionInFlight = false
                if self.status(id)?.state == .cancelling || !self.isAllowed() { self.finishCancellation(id); return }
                switch result {
                case .success(let message):
                    self.mutate(id) { $0.steps[index].state = .completed; $0.steps[index].message = message }
                    self.advance(id, index: index + 1)
                case .failure(let error):
                    self.mutate(id) { $0.steps[index].state = .failed; $0.steps[index].message = error.localizedDescription; $0.state = .failed; $0.message = error.localizedDescription }
                    self.activeID = nil; self.automation = nil
                }
            }
        }
    }
    enum RunnerError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
}
