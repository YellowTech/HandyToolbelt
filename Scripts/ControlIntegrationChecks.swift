// Real CLI -> Unix socket -> command service, with temporary settings and fake
// native actions. No production endpoint, app launch, input listener, or panels.
import AppKit
import IOKit.pwr_mgt
import HandyToolbeltCore
import HandyToolbeltControl

private struct CheckError: LocalizedError { var errorDescription: String? }
private final class CLIResult {
    let lock = NSLock()
    var value: Result<(ControlResponse, Int32), Error>?
}

@main
struct ControlIntegrationChecks {
    static var count = 0
    static var failures: [String] = []
    static var cliPath = ""
    static var socketPath = ""
    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures.append(message); print("FAIL: \(message)") }
    }
    static func pump(until predicate: () -> Bool, timeout: Double = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard predicate() else { throw CheckError(errorDescription: "Timed out waiting for isolated check.") }
    }
    static func cli(_ arguments: [String]) throws -> (ControlResponse, Int32) {
        let result = CLIResult(), executable = cliPath, endpoint = socketPath
        DispatchQueue.global().async {
            let value: Result<(ControlResponse, Int32), Error> = Result {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["--socket", endpoint] + arguments
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                do { return (try JSONDecoder().decode(ControlResponse.self, from: data), process.terminationStatus) }
                catch { throw CheckError(errorDescription: "Invalid CLI output: \(String(decoding: data + diagnostics, as: UTF8.self))") }
            }
            result.lock.lock(); result.value = value; result.lock.unlock()
        }
        try pump(until: { result.lock.lock(); defer { result.lock.unlock() }; return result.value != nil }, timeout: 10)
        result.lock.lock(); defer { result.lock.unlock() }; return try result.value!.get()
    }
    static func call(_ command: String, _ parameters: JSONObject = [:]) throws -> (ControlResponse, Int32) {
        let data = try JSONEncoder().encode(parameters)
        return try cli(["call", command, "--json", String(decoding: data, as: UTF8.self)])
    }
    static func result(_ invocation: (ControlResponse, Int32)) throws -> JSONValue {
        guard invocation.0.ok, invocation.1 == 0, let value = invocation.0.result else {
            throw CheckError(errorDescription: "CLI rejected check: \(invocation.0.error?.message ?? "missing result")")
        }
        return value
    }
    static func main() throws {
        if CommandLine.arguments.contains("--generate-docs") {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            try ControlContract.referenceMarkdown().write(to: root.appendingPathComponent("Docs/CLI-reference.md"), atomically: true, encoding: .utf8)
            print("Generated Docs/CLI-reference.md")
            return
        }
        cliPath = CommandLine.arguments[1]
        // Short path stays within sockaddr_un.sun_path even on macOS temp roots.
        let directory = URL(fileURLWithPath: "/tmp/st-check-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        socketPath = directory.appendingPathComponent("control.sock").path
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var config = AppConfiguration(); config.bindings = []; config.trackpadModuleEnabled = false; config.windowSwitcher.isEnabled = false
        config.coffeeModuleEnabled = true; config.displayModuleEnabled = true
        let signal = GestureAction(kind: .showText, text: "Signal")
        let complete = SavedAutomation(name: "Complete", steps: [.init(name: "Wait", delay: 0.05), .init(name: "Signal", action: signal)])
        let wait = SavedAutomation(name: "Wait", steps: [.init(name: "Wait", delay: 2), .init(name: "Must not execute", action: signal)])
        let native = SavedAutomation(name: "Native", steps: [.init(name: "Native action", action: .init(kind: .appleScript, script: "-- fake executor only")), .init(name: "Must not execute", action: signal)])
        let failing = SavedAutomation(name: "Failure", steps: [.init(name: "Fail", action: .init(kind: .showText, text: "FAIL")), .init(name: "Must not execute", action: signal)])
        config.automations = [complete, wait, native, failing]
        try store.save(config)
        let display = DisplayModel(presenter: nil, observeSession: false)
        var assertionID: IOPMAssertionID = 0
        var heldAssertions: Set<IOPMAssertionID> = []
        let coffee = CoffeeModel(driver: .init(create: { _ in
            assertionID += 1; heldAssertions.insert(assertionID)
            return (kIOReturnSuccess, assertionID)
        }, release: { id in heldAssertions.remove(id); return kIOReturnSuccess }))
        coffee.configure(enabled: true, running: true)
        var nativeCompletion: ((Result<String, Error>) -> Void)?
        var executed: [String] = []
        let runner = AutomationRunner { action, completion in
            executed.append(action.text)
            if action.kind == .appleScript { nativeCompletion = completion }
            else if action.text == "FAIL" { completion(.failure(CheckError(errorDescription: "Intentional test failure"))) }
            else { completion(.success("Done")) }
        }
        runner.isAllowed = { true }
        runner.onProgress = { progress, begin in if begin { display.begin(progress) } else { display.update(progress) } }
        var rejectSave = false
        var loginState = LoginItemModel.Status.notRegistered
        var loginWrites = 0
        var rejectLogin = false
        let login = LoginItemModel(driver: .init(status: { loginState }, register: {
            loginWrites += 1
            if rejectLogin { throw CheckError(errorDescription: "Intentional login registration failure") }
            loginState = .requiresApproval
        }, unregister: { loginWrites += 1; loginState = .notRegistered }, openSettings: {}))
        let service = ControlCommandService(display: display, runner: runner, coffee: coffee, loginItem: login, getConfiguration: { config }, saveConfiguration: { next in
            if rejectSave { throw CheckError(errorDescription: "Intentional persistence failure") }
            try store.save(next); config = next
            display.configure(enabled: config.displayModuleEnabled)
            coffee.configure(enabled: config.coffeeModuleEnabled, running: true)
        })
        var covered: Set<ControlCommand> = []
        let suite = "HandyToolbelt-CLI-consent-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LocalCLIControlPreferences(defaults: defaults)
        let control = CLIControlModel(preferences: preferences, serverFactory: { ControlServer(socketPath: socketPath, handler: $0) })
        let handler: CLIControlModel.Handler = { request, reply in
            let response = service.handle(request)
            if let command = ControlCommand(rawValue: request.command), response.ok, let result = response.result {
                covered.insert(command)
                check(command.inputErrors(request.parameters).isEmpty, "Successful \(command.rawValue) input matches contract")
                let errors = command.outputErrors(result)
                check(errors.isEmpty, "\(command.rawValue) output matches contract: \(errors)")
            }
            reply(response)
        }
        control.start(handler: handler); defer { control.stop() }
        check(!control.allowed && !control.available && !FileManager.default.fileExists(atPath: socketPath), "Missing consent defaults off without creating a listener")
        // UI/gesture commands use the service directly while the CLI stays off.
        let localRun = try service.run("Complete")
        try pump(until: { runner.status(localRun.id)?.state == .completed })
        check(executed == ["Signal"] && !control.available, "In-app automation works with CLI off")
        executed.removeAll()
        let offRevision = try config.revision()
        _ = try service.apply(config, expectedRevision: offRevision)
        check(!preferences.allowed && !control.available, "Configuration replacement cannot grant CLI consent")
        control.setAllowed(true)
        check(control.allowed && control.available && preferences.allowed, "Opt-in starts isolated listener immediately")

        let schema = try result(cli(["schema"]))
        check(schema.objectValue?["commands"]?.objectValue?["config.apply"] != nil && schema.objectValue?["$defs"] != nil, "Schema exposes commands and configuration")
        let status = try result(cli(["status"]))
        check(status.objectValue?["modules"]?.objectValue?["trackpad"] == .bool(false), "Status reflects disabled Trackpad")
        let loginStatus = try result(call("login.status"))
        check(loginStatus.objectValue?["status"] == .string("notRegistered") && loginWrites == 0, "Login reads do not register the app")
        let loginPending = try result(call("login.set", ["enabled": .bool(true)]))
        check(loginPending.objectValue?["status"] == .string("requiresApproval") && loginPending.objectValue?["enabled"] == .bool(false), "Login registration awaiting approval is not reported enabled")
        loginState = .enabled
        let loginEnabled = try result(call("login.status"))
        check(loginEnabled.objectValue?["enabled"] == .bool(true), "Login status observes external approval")
        let loginDisabled = try result(call("login.set", ["enabled": .bool(false)]))
        check(loginDisabled.objectValue?["enabled"] == .bool(false) && loginWrites == 2, "Login disabling unregisters with the same native model")
        let invalidLogin = try call("login.set", ["enabled": .string("yes")])
        check(invalidLogin.0.error?.code == "invalid_parameters" && loginWrites == 2, "Invalid login input cannot change registration")
        rejectLogin = true
        let failedLogin = try call("login.set", ["enabled": .bool(true)])
        check(failedLogin.0.error?.code == "login_registration_failed" && !login.enabled, "Login failure returns an error and preserves OS state")
        rejectLogin = false
        let idle = try result(call("coffee.set", ["preventIdleSleep": .bool(true)]))
        check(idle.objectValue?["effective"]?.objectValue?["preventIdleSleep"] == .bool(true) && heldAssertions.count == 1, "Coffee CLI acquires idle assertion")
        let both = try result(call("coffee.set", ["keepDisplayAwake": .bool(true)]))
        check(both.objectValue?["effective"]?.objectValue?["keepDisplayAwake"] == .bool(true) && heldAssertions.count == 2, "Partial Coffee update preserves other mode")
        let powerStatus = try result(call("power.status"))
        check(powerStatus.objectValue?["chargePercent"] == .null, "Unstarted Power reports unknown charge")
        check(powerStatus.objectValue?["nominalChargeCapacityMAh"] == .null && powerStatus.objectValue?["healthEstimateSource"] == .null, "Unstarted Power serializes unknown nominal capacity and health source")
        let coffeeStatus = try result(call("coffee.status"))
        check(coffeeStatus.objectValue?["isActive"] == .bool(true), "Coffee status reports actual held assertions")
        let invalidCoffee = try call("coffee.set", ["preventIdleSleep": .string("false")])
        check(invalidCoffee.0.error?.code == "invalid_parameters" && heldAssertions.count == 2, "Invalid Coffee command cannot mutate assertions")
        let initial = try result(cli(["config", "get"]))
        let revision = initial.objectValue!["revision"]!.stringValue!
        let original = initial.objectValue!["configuration"]!
        check(try original.decode(AppConfiguration.self).revision() == revision, "Get returns stable canonical revision")
        let file = directory.appendingPathComponent("edited.json")
        try JSONEncoder().encode(original).write(to: file)
        let validation = try result(cli(["config", "validate", "--file", file.path]))
        check(validation.objectValue?["errors"]?.arrayValue?.isEmpty == true, "Exported configuration validates")
        var stackConfiguration = config
        stackConfiguration.stacks = [.init(name: "CLI stack", isEnabled: true, startActions: [.init(kind: .holdModifiers, modifiers: [.option])], bindings: [.init(actions: [.init(kind: .openApplication, applicationBundleIdentifier: "com.apple.finder")])])]
        let v5Report = try result(call("config.validate", ["configuration": .object(["version": .number(5), "bindings": .array([])])]))
        check(v5Report.objectValue?["errors"]?.arrayValue?.isEmpty == true, "CLI accepts version 5 migration")
        let stackReport = try result(call("config.validate", ["configuration": try JSONValue(encoding: stackConfiguration)]))
        check(stackReport.objectValue?["errors"]?.arrayValue?.isEmpty == true, "Version 5 stack, held modifiers and Open App validate through CLI")
        var invalidStack = stackConfiguration
        invalidStack.stacks[0].bindings[0].gesture.corner = .topLeft
        let stackErrors = try result(call("config.validate", ["configuration": try JSONValue(encoding: invalidStack)]))
        check(stackErrors.objectValue?["errors"]?.arrayValue?.isEmpty == false, "Stack children cannot nest corner holds")
        let before = try Data(contentsOf: store.url)
        var bad = original.objectValue!; bad["displayModuleEnabld"] = .bool(false)
        let invalid = try result(call("config.validate", ["configuration": .object(bad)]))
        check(invalid.objectValue?["errors"]?.arrayValue?.isEmpty == false, "Unknown configuration keys are rejected")
        let invalidApply = try call("config.apply", ["configuration": .object(bad), "expectedRevision": .string(revision)])
        check(try !invalidApply.0.ok && invalidApply.1 != 0 && Data(contentsOf: store.url) == before, "Invalid apply does not write settings")

        // Whole-configuration trackpad editing must preserve unrelated modules and workflow data.
        var trackpad = config
        let group = ApplicationGroup(name: "CLI editors", applications: [.init("Xcode", "com.apple.dt.Xcode")])
        trackpad.applicationGroups.append(group)
        trackpad.bindings = [.init(gesture: .init(kind: .swipeLeft, fingers: 3),
                                  action: .init(system: .previousTab), applicationGroupID: group.id)]
        trackpad.bindings[0].showsToast = false
        trackpad.trackpadTuning.handAngleDegrees = -17
        trackpad.trackpadTuning.tapTravel = 0.04
        try JSONEncoder().encode(trackpad).write(to: file)
        let trackpadValidation = try result(cli(["config", "validate", "--file", file.path]))
        check(trackpadValidation.objectValue?["errors"]?.arrayValue?.isEmpty == true, "Trackpad binding, action, group and tuning validate")
        let trackpadApply = try result(cli(["config", "apply", "--file", file.path, "--revision", revision]))
        let trackpadRevision = trackpadApply.objectValue!["revision"]!.stringValue!
        let readBack = try result(cli(["config", "get"]))
        let savedTrackpad = try readBack.objectValue!["configuration"]!.decode(AppConfiguration.self)
        check(try savedTrackpad.revision() == trackpad.revision() && store.load().revision() == trackpad.revision(), "Real CLI roundtrip preserves complete trackpad and unrelated configuration")
        check(try savedTrackpad.automations == original.decode(AppConfiguration.self).automations && savedTrackpad.mouseTuning == original.decode(AppConfiguration.self).mouseTuning,
              "Trackpad edit preserves workflows and mouse tuning")
        check(!savedTrackpad.bindings[0].showsToast, "CLI roundtrip preserves per-binding toast opt-out")
        let gesture = trackpad.bindings[0].gesture
        check(savedTrackpad.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: "com.apple.dt.Xcode")?.action.system == .previousTab
              && savedTrackpad.match(device: .trackpad, gesture: gesture, frontmostBundleIdentifier: "com.apple.Safari") == nil,
              "CLI-edited scoped gesture matches inside its application group and stays inactive outside")
        let validBytes = try Data(contentsOf: store.url)
        var missingGroup = trackpad; missingGroup.bindings[0].applicationGroupID = UUID()
        var missingAutomation = trackpad; missingAutomation.bindings[0].action = .init(kind: .automation, automationID: UUID())
        var conflicting = trackpad
        var duplicate = trackpad.bindings[0]; duplicate.id = UUID(); conflicting.bindings.append(duplicate)
        for invalidConfig in [missingGroup, missingAutomation, conflicting] {
            let value = try JSONValue(encoding: invalidConfig)
            let report = try result(call("config.validate", ["configuration": value]))
            let rejected = try call("config.apply", ["configuration": value, "expectedRevision": .string(trackpadRevision)])
            check(try report.objectValue?["errors"]?.arrayValue?.isEmpty == false && rejected.0.error?.code == "invalid_configuration" && Data(contentsOf: store.url) == validBytes,
                  "Invalid references or duplicate enabled gesture reject without write")
        }
        var rawTuning = try JSONValue(encoding: trackpad).objectValue!
        var tuning = rawTuning["trackpadTuning"]!.objectValue!; tuning["handAngleDegrees"] = .number(61)
        rawTuning["trackpadTuning"] = .object(tuning)
        let tuningRejected = try call("config.apply", ["configuration": .object(rawTuning), "expectedRevision": .string(trackpadRevision)])
        check(try tuningRejected.0.error?.code == "invalid_configuration" && Data(contentsOf: store.url) == validBytes,
              "Raw out-of-range tuning rejects before Codable normalization")
        for parameters: JSONObject in [[:], ["configuration": .null], ["configuration": .array([])]] {
            let report = try result(call("config.validate", parameters))
            check(report.objectValue?["errors"]?.arrayValue?.isEmpty == false, "Malformed validation input remains a successful error report")
        }
        let outerInvalid = try call("config.validate", ["configuration": original, "extra": .bool(true)])
        check(outerInvalid.0.error?.code == "invalid_parameters", "Unknown outer validation parameter remains a command error")
        _ = try result(cli(["config", "undo", "--revision", trackpadRevision]))
        check(try config.revision() == revision && store.load().revision() == original.decode(AppConfiguration.self).revision(), "Trackpad apply undo restores all unrelated fields")

        var changed = config; changed.displayModuleEnabled = false
        try JSONEncoder().encode(changed).write(to: file)
        rejectSave = true
        let failedSave = try cli(["config", "apply", "--file", file.path, "--revision", revision])
        check(try !failedSave.0.ok && config.displayModuleEnabled && Data(contentsOf: store.url) == before, "Persistence failure preserves live state and file")
        rejectSave = false
        let applied = try result(cli(["config", "apply", "--file", file.path, "--revision", revision]))
        let newRevision = applied.objectValue!["revision"]!.stringValue!
        check(try !config.displayModuleEnabled && !store.load().displayModuleEnabled, "Apply updates live and saved state")
        let stale = try cli(["config", "apply", "--file", file.path, "--revision", revision])
        check(stale.0.error?.code == "revision_conflict" && stale.1 == 1, "Stale writer receives conflict and failure exit code")
        _ = try result(cli(["display", "toast", "No panel"]))
        _ = try result(cli(["display", "dismiss"]))
        let hidden = try result(cli(["display", "text", "No panel"]))
        check(hidden.objectValue?["displayed"] == .bool(false), "Disabled Display accepts text without showing it")
        _ = try result(cli(["config", "undo", "--revision", newRevision]))
        check(try config.displayModuleEnabled && config.revision() == revision, "Undo restores saved configuration")

        let progress = try result(cli(["display", "progress", "begin", "Build", "--steps", "Compile,Verify"]))
        let progressID = progress.objectValue!["id"]!.stringValue!
        check(progress.objectValue?["displayed"] == .bool(true), "Progress works with Trackpad disabled")
        _ = try result(call("config.apply", ["configuration": try .init(encoding: changed), "expectedRevision": .string(revision)]))
        let update = try result(cli(["display", "progress", "update", progressID, "--step", "1", "--state", "completed"]))
        check(update.objectValue?["displayed"] == .bool(false), "Progress update survives disabling Display")
        let finish = try result(cli(["display", "progress", "finish", progressID]))
        check(finish.objectValue?["displayed"] == .bool(false), "Progress can finish while Display is off")

        let listing = try result(cli(["automations", "list"]))
        check(listing.arrayValue?.count == 4, "Saved automations are discoverable")
        let run = try result(cli(["automations", "run", "Complete"]))
        let runID = UUID(uuidString: run.objectValue!["runID"]!.stringValue!)!
        try pump(until: { runner.status(runID)?.state == .completed })
        let completed = try result(cli(["automations", "status", runID.uuidString]))
        check(completed.objectValue?["state"] == .string("completed") && executed == ["Signal"], "Automation completes with both input and Display modules off")
        let waiting = try result(cli(["automations", "run", "Wait"]))
        let waitingID = waiting.objectValue!["runID"]!.stringValue!
        let busy = try cli(["automations", "run", "Complete"])
        check(!busy.0.ok, "Concurrent run is rejected")
        let cancelled = try result(cli(["automations", "cancel", waitingID]))
        check(cancelled.objectValue?["state"] == .string("cancelled") && executed.count == 1, "Cancellation stops waits and future steps")
        let held = try result(cli(["automations", "run", "Native"]))
        let heldID = held.objectValue!["runID"]!.stringValue!
        try pump(until: { nativeCompletion != nil })
        let cancelling = try result(cli(["automations", "cancel", heldID]))
        check(cancelling.objectValue?["state"] == .string("cancelling"), "Native action reports cancelling until callback")
        nativeCompletion?(.success("Returned")); nativeCompletion = nil
        let settled = try result(cli(["automations", "status", heldID]))
        check(settled.objectValue?["state"] == .string("cancelled") && executed.count == 2, "Native cancellation skips remaining actions")
        let failure = try result(cli(["automations", "run", "Failure"]))
        let failureID = UUID(uuidString: failure.objectValue!["runID"]!.stringValue!)!
        try pump(until: { runner.status(failureID)?.state == .failed })
        check(executed.count == 3, "Action failure stops later steps")
        _ = try result(cli(["automations", "run", "Wait"]))
        var paused = config; paused.displayModuleEnabled = false; paused.coffeeModuleEnabled = false
        _ = try result(call("config.apply", ["configuration": try .init(encoding: paused), "expectedRevision": .string(try config.revision())]))
        check(runner.active != nil && executed.count == 3, "Tool switches preserve independent automation runs")
        runner.stop()
        check(heldAssertions.isEmpty && !coffee.preventIdleSleep && !coffee.keepDisplayAwake, "Disabling Coffee through the CLI releases assertions and clears selections")
        let pausedCoffee = try call("coffee.set", ["preventIdleSleep": .bool(true)])
        check(pausedCoffee.0.error?.code == "unavailable" && heldAssertions.isEmpty, "CLI cannot activate Coffee while disabled")
        _ = try result(call("coffee.set", ["preventIdleSleep": .bool(false), "keepDisplayAwake": .bool(false)]))
        check(!coffee.preventIdleSleep && !coffee.keepDisplayAwake, "CLI can clear Coffee selections while disabled")

        // Simulate an intervening UI edit: undo must not erase it even when given
        // the caller's most recently observed revision.
        config.visualFeedbackEnabled.toggle(); try store.save(config)
        let newer = try config.revision()
        let unsafeUndo = try cli(["config", "undo", "--revision", newer])
        check(try unsafeUndo.0.error?.code == "revision_conflict" && config.revision() == newer, "Undo preserves subsequent UI edits")
        let unknown = try call("display.text", ["text": .string("Hello"), "duraton": .number(0.5)])
        check(unknown.0.error?.code == "invalid_parameters", "Unknown command parameters fail clearly")
        check(display.progress.sessions.isEmpty, "Disabled feedback leaves no visible progress sessions")
        check(covered == Set(ControlCommand.allCases), "Every command has a successful real CLI handler result: missing \(Set(ControlCommand.allCases).subtracting(covered))")
        check(preferences.allowed && control.available, "CLI config.apply never revokes local consent")
        let exported = try result(cli(["config", "get"]))
        check(exported.objectValue?["configuration"]?.objectValue?["allowCLIControl"] == nil, "Exported configuration excludes local consent")
        var consentPayload = try JSONValue(encoding: config).objectValue!
        consentPayload["allowCLIControl"] = .bool(false)
        let consentAttempt = try call("config.apply", ["configuration": .object(consentPayload), "expectedRevision": .string(try config.revision())])
        check(!consentAttempt.0.ok && preferences.allowed && control.available, "CLI configuration cannot smuggle a consent field")
        let consentValidation = try call("config.validate", ["configuration": .object(consentPayload)])
        check(consentValidation.0.ok && consentValidation.0.result?.objectValue?["errors"]?.arrayValue?.isEmpty == false && preferences.allowed, "CLI validation reports an injected consent field without changing consent")
        let testOverride = CLIControlModel(preferences: preferences, enabled: false, serverFactory: { _ in
            fatalError("Disabled test override must never create a server")
        })
        testOverride.start(handler: handler)
        check(testOverride.allowed && !testOverride.available, "Test override suppresses listener even with saved opt-in")
        testOverride.stop()
        // Queue a mutating request while the main queue is occupied, then disable.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        check(connected == 0, "Queued client connects to isolated endpoint")
        let request = ControlRequest(command: "automations.run", parameters: ["automation": .string("Complete")])
        var requestData = try JSONEncoder().encode(request); requestData.append(10)
        _ = requestData.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        Thread.sleep(forTimeInterval: 0.1) // Let the transport queue the handler without running the main queue.
        let beforeQueued = executed.count
        control.setAllowed(false)
        control.setAllowed(true) // Old queued requests must stay revoked after a quick re-enable.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15)); close(fd)
        check(executed.count == beforeQueued && runner.active == nil, "Disable/re-enable drops old queued CLI commands before they have effects")
        control.setAllowed(false)
        check(!control.available && !preferences.allowed && !FileManager.default.fileExists(atPath: socketPath), "Disable removes listener immediately")
        let unavailable = try cli(["status"])
        check(!unavailable.0.ok && unavailable.1 != 0, "New CLI requests fail after disable")
        _ = try service.apply(config, expectedRevision: config.revision())
        check(!preferences.allowed, "Imported/replaced configuration cannot grant consent")
        control.setAllowed(true)
        _ = try result(cli(["status"]))
        control.stop()
        check(preferences.allowed && !control.available, "Host stop preserves consent and closes listener")
        let restarted = CLIControlModel(preferences: LocalCLIControlPreferences(defaults: defaults), serverFactory: { ControlServer(socketPath: socketPath, handler: $0) })
        restarted.start(handler: handler)
        check(restarted.allowed && restarted.available, "Restart restores local opt-in")
        _ = try result(cli(["status"]))
        restarted.stop()
        // An ordinary file is an unsafe endpoint; Retry must recover after it is removed.
        try Data("occupied".utf8).write(to: URL(fileURLWithPath: socketPath))
        restarted.start(handler: handler)
        check(restarted.allowed && !restarted.available && restarted.error?.contains("Endpoint must be owned") == true, "Startup failure exposes actionable cause without claiming availability")
        try FileManager.default.removeItem(atPath: socketPath)
        restarted.retry()
        check(restarted.available && restarted.error == nil, "Retry starts listener and clears failure")
        _ = try result(cli(["status"]))
        // Disable does not cancel work already handed to the automation runner.
        let inFlight = try service.run("Complete")
        restarted.setAllowed(false)
        try pump(until: { runner.status(inFlight.id)?.state == .completed })
        check(!restarted.available && executed.count == beforeQueued + 1, "Disabling leaves already-started automation running")
        print("Control integration: \(count - failures.count)/\(count) checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
