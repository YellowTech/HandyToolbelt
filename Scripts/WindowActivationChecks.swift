import Foundation

/// Exercises the production coordinator using deterministic native-call and queue substitutes.
/// This is orchestration integration coverage, not a macOS focus/permission integration test.
private final class Rig {
    struct Job { let lane: WindowActivationCoordinator.Lane; let time: TimeInterval; let work: () -> Void }
    var jobs: [Job] = []
    var time: TimeInterval = 0
    var lane = WindowActivationCoordinator.Lane.worker
    var enabled = true
    var generation: UInt64 = 0
    var pid: Int32? = 10
    var available = true
    var restoreOK = true
    var localSuccess = true
    var appAccepted = false
    var raiseOK = true
    var focused = false
    var foregroundWorks = false
    var focusAt: TimeInterval?
    var events: [String] = []
    var results: [Result<String, Error>] = []
    var after: ((String) -> Void)?
    func effect(_ event: String, _ required: WindowActivationCoordinator.Lane) {
        precondition(lane == required, "\(event) ran on wrong queue")
        events.append(event); after?(event)
    }
    func start(local: Bool = false, minimized: Bool = false, origin: Int32? = 10) {
        generation &+= 1
        let token = generation
        let coordinator = WindowActivationCoordinator(origin: origin, target: 20, local: local, minimized: minimized,
            name: "Target", success: "Target window", boundary: .init(
                schedule: { self.jobs.append(Job(lane: $0, time: self.time + $1, work: $2)) },
                current: { self.enabled && self.generation == token }, frontmost: { self.pid }, now: { self.time },
                available: { self.effect("available", .worker); return self.available },
                restore: { self.effect("restore", .worker); return self.restoreOK },
                unhide: { self.effect("unhide", .main) },
                activateApp: { self.effect("activateApp", .main); return self.appAccepted },
                foreground: { self.effect("foreground", .worker); if self.foregroundWorks { self.pid = 20 } },
                makeMain: { self.effect("main", .worker) },
                raise: { self.effect("raise", .worker); return self.raiseOK },
                activateLocal: { self.effect("local", .main); return self.localSuccess },
                focused: {
                    self.effect("observe", local ? .main : .worker)
                    if let focusAt = self.focusAt, self.time >= focusAt { self.pid = 20; self.focused = true }
                    return self.focused
                },
                remember: { self.effect("remember", .worker) }, trace: { _ in }),
            completion: { precondition(self.lane == .main); self.results.append($0) })
        coordinator.start()
    }
    func next() {
        jobs.sort { $0.time < $1.time }
        let job = jobs.removeFirst(); time = job.time; lane = job.lane; job.work()
    }
    func run() {
        var count = 0
        while !jobs.isEmpty { next(); count += 1; precondition(count < 100, "Unbounded retries") }
        precondition(results.count == 1, "Completion must fire exactly once")
    }
    var succeeded: Bool { if case .success? = results.first { return true }; return false }
    var message: String { if case .failure(let error)? = results.first { return error.localizedDescription }; return "" }
}

@main
struct WindowActivationChecks {
    static func main() {
        var count = 0
        func check(_ name: String, _ work: () -> Void) { work(); count += 1; print("PASS \(name)") }
        check("rejected AppKit activation recovers through AX foreground") {
            let rig = Rig(); rig.foregroundWorks = true; rig.focused = true; rig.start(); rig.run()
            precondition(rig.succeeded)
            precondition(rig.events == ["available", "unhide", "activateApp", "foreground", "main", "raise", "observe", "remember"])
        }
        check("AXRaise success with unchanged foreground times out") {
            let rig = Rig(); rig.focused = true; rig.start(); rig.run()
            precondition(!rig.succeeded && rig.message.contains("not focus"))
            precondition(!rig.events.contains("remember") && rig.time < 1.4)
        }
        check("correct app wrong selected window times out") {
            let rig = Rig(); rig.foregroundWorks = true; rig.start(); rig.run()
            precondition(!rig.succeeded && rig.message.contains("not focus"))
        }
        check("delayed focus succeeds within bounded observation") {
            let rig = Rig(); rig.focusAt = 0.4; rig.start(); rig.run()
            precondition(rig.succeeded && rig.time >= 0.4 && rig.time < 1.2)
        }
        check("same-app switching still requires selected window") {
            let rig = Rig(); rig.pid = 20; rig.focusAt = 0.24; rig.start(origin: 20); rig.run()
            precondition(rig.succeeded && rig.events.filter { $0 == "observe" }.count >= 3)
        }
        check("minimized restore failure stops all later effects") {
            let rig = Rig(); rig.restoreOK = false; rig.start(minimized: true); rig.run()
            precondition(!rig.succeeded && rig.events == ["available", "restore"])
        }
        check("minimized restore precedes activation") {
            let rig = Rig(); rig.foregroundWorks = true; rig.focused = true; rig.start(minimized: true); rig.run()
            precondition(rig.succeeded && rig.events.prefix(3) == ["available", "restore", "unhide"])
        }
        for reason in ["target gone", "permission denied"] {
            check(reason) {
                let rig = Rig(); rig.available = false; rig.start(); rig.run()
                precondition(!rig.succeeded && rig.events == ["available"])
            }
        }
        check("raise refusal fails without verification") {
            let rig = Rig(); rig.raiseOK = false; rig.start(); rig.run()
            precondition(!rig.succeeded && !rig.events.contains("observe"))
        }
        check("local activation can fail after successful availability") {
            let rig = Rig(); rig.localSuccess = false; rig.start(local: true); rig.run()
            precondition(!rig.succeeded && rig.events == ["available", "local"])
        }
        check("accepted AppKit activation without focus still times out") {
            let rig = Rig(); rig.appAccepted = true; rig.start(); rig.run()
            precondition(!rig.succeeded && rig.message.contains("not focus"))
        }
        check("already focused target is observed immediately") {
            let rig = Rig(); rig.foregroundWorks = true; rig.focused = true; rig.start(); rig.run()
            precondition(rig.succeeded && rig.time == 0)
        }
        for deliveryPID: Int32 in [10, 30] {
            check("focus returned to PID \(deliveryPID) before success delivery fails") {
                let rig = Rig(); rig.foregroundWorks = true; rig.focused = true
                rig.after = { if $0 == "remember" { rig.pid = deliveryPID } }
                rig.start(); rig.run()
                precondition(!rig.succeeded && rig.message.contains("focus changed"))
            }
        }
        check("own window uses AppKit on main and never AX") {
            let rig = Rig(); rig.focusAt = 0; rig.start(local: true, minimized: true); rig.run()
            precondition(rig.succeeded && rig.events == ["available", "local", "observe", "remember"])
        }
        check("unrelated initial focus prevents every native call") {
            let rig = Rig(); rig.pid = 30; rig.start(); rig.run()
            precondition(!rig.succeeded && rig.events.isEmpty)
        }
        let stages = ["available", "restore", "unhide", "activateApp", "foreground", "main", "raise", "observe", "remember"]
        for reason in ["cancel", "disable", "newer request"] {
            for stage in stages {
                check("\(reason) after \(stage) blocks subsequent effects") {
                    let rig = Rig(); rig.foregroundWorks = true; rig.focused = true
                    rig.after = {
                        if $0 == stage {
                            if reason == "disable" { rig.enabled = false }
                            else { rig.generation &+= 1 }
                        }
                    }
                    rig.start(minimized: true); rig.run()
                    precondition(!rig.succeeded && rig.events.last == stage && rig.message.contains("cancelled"))
                }
            }
        }
        for stage in stages.dropLast() {
            check("unrelated focus after \(stage) cancels") {
                let rig = Rig(); rig.focused = true
                rig.after = { if $0 == stage { rig.pid = 30 } }
                rig.start(minimized: true); rig.run()
                precondition(!rig.succeeded && rig.events.last == stage && rig.message.contains("focus changed"))
            }
        }
        check("new request supersedes an already queued request") {
            let rig = Rig(); rig.foregroundWorks = true; rig.focused = true
            rig.start(); rig.start()
            while !rig.jobs.isEmpty { rig.next() }
            precondition(rig.results.count == 2)
            precondition(rig.events.filter { $0 == "activateApp" }.count == 1)
            precondition(rig.results.filter { if case .success = $0 { return true }; return false }.count == 1)
        }
        check("timeout leaves no scheduled work or later mutations") {
            let rig = Rig(); rig.start(); rig.run()
            let events = rig.events; precondition(rig.jobs.isEmpty && rig.time < 1.4)
            rig.time = 100; precondition(rig.events == events && rig.results.count == 1)
        }
        print("\(count) production window activation orchestration checks passed")
    }
}
