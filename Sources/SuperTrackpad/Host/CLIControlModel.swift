import Combine
import Foundation
import SuperToolsControl

/// Local consent deliberately lives outside the transferable app configuration.
protocol CLIControlPreferences: AnyObject {
    var allowed: Bool { get set }
}

final class LocalCLIControlPreferences: CLIControlPreferences {
    private let defaults: UserDefaults
    private let key = "allowCLIControl"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var allowed: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// Main-thread host lifecycle. Disabling stops queued requests, not actions already dispatched.
final class CLIControlModel: ObservableObject {
    typealias Handler = (ControlRequest, @escaping (ControlResponse) -> Void) -> Void
    typealias ServerFactory = (@escaping Handler) -> ControlServer
    @Published private(set) var allowed: Bool
    @Published private(set) var available = false
    @Published private(set) var error: String?
    private let preferences: CLIControlPreferences
    private let serverFactory: ServerFactory
    private let enabled: Bool
    private var server: ControlServer?
    private var handler: Handler?

    init(preferences: CLIControlPreferences = LocalCLIControlPreferences(), enabled: Bool = true,
         serverFactory: @escaping ServerFactory = { ControlServer(handler: $0) }) {
        self.preferences = preferences; self.enabled = enabled; self.serverFactory = serverFactory
        allowed = preferences.allowed
    }
    func start(handler: @escaping Handler) {
        self.handler = handler
        retry()
    }
    func setAllowed(_ value: Bool) {
        preferences.allowed = value; allowed = value
        if value { retry() } else { stopListener() }
    }
    func retry() {
        guard enabled, allowed, let handler, server == nil else { return }
        let candidate = serverFactory(handler)
        do {
            try candidate.start()
            server = candidate; available = candidate.isRunning; error = nil
        } catch {
            candidate.stop(); available = false
            let reason = (error as? ControlError)?.message ?? error.localizedDescription
            self.error = "CLI unavailable: \(reason)"
        }
    }
    func stop() { handler = nil; stopListener() }
    private func stopListener() {
        server?.stop(); server = nil; available = false; error = nil
    }
}
