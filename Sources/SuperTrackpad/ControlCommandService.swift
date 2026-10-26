import Foundation
import SuperTrackpadCore
import SuperToolsControl

/// State operations are shared by local controls and the socket handler; no listeners start here.
final class ControlCommandService {
    let power: PowerModel
    let coffee: CoffeeModel
    let display: DisplayModel
    let runner: AutomationRunner
    let loginItem: LoginItemModel
    private let getConfiguration: () -> AppConfiguration
    private let saveConfiguration: (AppConfiguration) throws -> Void
    private let runtimeStatus: () -> JSONObject
    private var undo: (configuration: AppConfiguration, appliedRevision: String)?
    init(display: DisplayModel, runner: AutomationRunner, coffee: CoffeeModel = CoffeeModel(), power: PowerModel = PowerModel(), loginItem: LoginItemModel = LoginItemModel(), getConfiguration: @escaping () -> AppConfiguration,
         saveConfiguration: @escaping (AppConfiguration) throws -> Void, runtimeStatus: @escaping () -> JSONObject = { [:] }) {
        self.power = power; self.coffee = coffee; self.display = display; self.runner = runner; self.loginItem = loginItem; self.getConfiguration = getConfiguration
        self.saveConfiguration = saveConfiguration; self.runtimeStatus = runtimeStatus
    }
    func handle(_ request: ControlRequest) -> ControlResponse {
        do { return .success(id: request.id, result: try perform(request.command, request.parameters)) }
        catch let error as ControlError { return .failure(id: request.id, code: error.code, message: error.message) }
        catch { return .failure(id: request.id, code: "operation_failed", message: error.localizedDescription) }
    }
    func apply(_ config: AppConfiguration, expectedRevision: String) throws -> String {
        let current = getConfiguration()
        guard try current.revision() == expectedRevision else { throw fail("revision_conflict", "Configuration changed. Read config.get and retry with its revision.") }
        let validation = config.validation()
        guard validation.isValid else { throw fail("invalid_configuration", validation.errors.joined(separator: " ")) }
        try saveConfiguration(config)
        let revision = try config.revision()
        undo = (current, revision)
        return revision
    }
    func run(_ selector: String) throws -> WorkflowProgress {
        let candidates = getConfiguration().automations.filter { $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame || $0.name == selector }
        guard candidates.count == 1 else { throw fail(candidates.isEmpty ? "not_found" : "ambiguous_name", candidates.isEmpty ? "Automation not found." : "More than one automation has this name. Use its UUID.") }
        return try runner.start(candidates[0])
    }
    private func powerStatus() -> JSONValue {
        power.refreshForStatus()
        let value = power.reading
        return .object(["enabled": .bool(getConfiguration().powerModuleEnabled), "running": .bool(power.running),
            "batteryPresent": value.batteryPresent.map(JSONValue.bool) ?? .null,
            "chargePercent": value.chargePercent.map { .number(Double($0)) } ?? .null,
            "isCharging": value.isCharging.map(JSONValue.bool) ?? .null,
            "isCharged": value.isCharged.map(JSONValue.bool) ?? .null,
            "powerSource": value.powerSource.map(JSONValue.string) ?? .null,
            "designCapacityMAh": value.designCapacityMAh.map(JSONValue.number) ?? .null,
            "fullChargeCapacityMAh": value.fullChargeCapacityMAh.map(JSONValue.number) ?? .null,
            "estimatedHealthPercent": value.estimatedHealthPercent.map(JSONValue.number) ?? .null,
            "nominalChargeCapacityMAh": value.nominalChargeCapacityMAh.map(JSONValue.number) ?? .null,
            "healthEstimateSource": value.healthEstimateSource.map(JSONValue.string) ?? .null,
            "adapterWatts": value.adapterWatts.map(JSONValue.number) ?? .null,
            "batteryWatts": value.batteryWatts.map(JSONValue.number) ?? .null,
            "inputWatts": value.inputWatts.map(JSONValue.number) ?? .null,
            "systemLoadWatts": value.systemLoadWatts.map(JSONValue.number) ?? .null,
            "estimatedMacWatts": value.estimatedMacWatts.map(JSONValue.number) ?? .null,
            "cycleCount": value.cycleCount.map { .number(Double($0)) } ?? .null,
            "externalConnected": value.externalConnected.map(JSONValue.bool) ?? .null,
            "adapterName": value.adapterName.map(JSONValue.string) ?? .null,
            "error": power.errorMessage.map(JSONValue.string) ?? .null])
    }
    private func coffeeStatus() -> JSONValue {
        .object(["enabled": .bool(getConfiguration().coffeeModuleEnabled), "running": .bool(coffee.running),
            "isActive": .bool(coffee.isActive),
            "requested": .object(["preventIdleSleep": .bool(coffee.preventIdleSleep), "keepDisplayAwake": .bool(coffee.keepDisplayAwake)]),
            "effective": .object(["preventIdleSleep": .bool(coffee.isEffective(.preventIdleSleep)), "keepDisplayAwake": .bool(coffee.isEffective(.keepDisplayAwake))]),
            "error": coffee.errorMessage.map(JSONValue.string) ?? .null])
    }
    private func loginStatus() -> JSONValue {
        loginItem.refresh()
        return .object(["status": .string(loginItem.status.rawValue), "enabled": .bool(loginItem.enabled),
                        "error": loginItem.errorMessage.map(JSONValue.string) ?? .null])
    }
    private func perform(_ command: String, _ p: JSONObject) throws -> JSONValue {
        guard let command = ControlCommand(rawValue: command) else { throw fail("unknown_command", "Unknown command: \(command). Use schema for supported commands.") }
        let inputErrors = command.inputErrors(p)
        guard inputErrors.isEmpty else { throw fail("invalid_parameters", inputErrors.joined(separator: " ")) }
        let config = getConfiguration()
        switch command {
        case .schema: return try ControlSchema.value()
        case .status:
            var status = runtimeStatus()
            status["version"] = .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.10.0")
            status["modules"] = .object(["trackpad": .bool(config.trackpadModuleEnabled), "windows": .bool(config.windowSwitcher.isEnabled), "snapping": .bool(config.snappingModuleEnabled), "display": .bool(config.displayModuleEnabled), "coffee": .bool(config.coffeeModuleEnabled), "power": .bool(config.powerModuleEnabled)])
            status["revision"] = .string(try config.revision())
            status["display"] = .object(["available": .bool(display.available), "enabled": .bool(display.enabled), "sessions": try .init(encoding: display.progress.sessions.map(\.progress))])
            status["coffee"] = coffeeStatus()
            status["power"] = powerStatus()
            status["login"] = loginStatus()
            status["automation"] = try runner.active.map { try JSONValue(encoding: $0) } ?? .null
            return .object(status)
        case .login_status: return loginStatus()
        case .login_set:
            loginItem.setEnabled(try boolean(p, "enabled", default: false))
            if let error = loginItem.errorMessage { throw fail("login_registration_failed", error) }
            return loginStatus()
        case .power_status: return powerStatus()

        case .coffee_status: return coffeeStatus()
        case .coffee_set:
            let idle = try p["preventIdleSleep"].map { _ in try boolean(p, "preventIdleSleep", default: false) }
            let screen = try p["keepDisplayAwake"].map { _ in try boolean(p, "keepDisplayAwake", default: false) }
            guard !(idle == true || screen == true) || (coffee.controlsAvailable && config.coffeeModuleEnabled) else {
                throw fail("unavailable", "Start HandyToolbelt and enable Coffee before activating Coffee.")
            }
            coffee.set(preventIdleSleep: idle, keepDisplayAwake: screen)
            if let error = coffee.errorMessage { throw fail("power_assertion_failed", error) }
            return coffeeStatus()
        case .config_get: return .object(["configuration": try .init(encoding: config), "revision": .string(try config.revision())])
        case .config_validate:
            do { return try .init(encoding: decodeConfiguration(p).validation()) }
            catch let error as ControlError { return .object(["errors": .array([.string(error.message)]), "warnings": .array([])]) }
            catch { return .object(["errors": .array([.string(error.localizedDescription)]), "warnings": .array([])]) }
        case .config_apply:
            return .object(["revision": .string(try apply(decodeConfiguration(p), expectedRevision: string(p, "expectedRevision")))])
        case .config_undo:
            let expected = try string(p, "expectedRevision")
            guard let undo else { throw fail("no_undo", "There is no configuration apply to undo.") }
            guard expected == undo.appliedRevision, try config.revision() == expected else { throw fail("revision_conflict", "Configuration changed after the last apply; undo would overwrite newer edits.") }
            try saveConfiguration(undo.configuration)
            self.undo = nil
            return .object(["revision": .string(try undo.configuration.revision())])
        case .display_text, .display_toast:
            let text = try string(p, "text"), duration = try number(p, "duration", default: GestureAction.defaultTextDuration)
            return .object(["displayed": .bool(command == .display_text ? display.text(text, duration: duration) : display.toast(text, duration: duration))])
        case .display_progress_begin:
            let title = try string(p, "title")
            guard let steps = p["steps"]?.arrayValue else { throw fail("invalid_parameters", "steps must be an array of 1–32 names.") }
            let names = try steps.map { value -> String in try string(["name": value], "name") }
            let value = WorkflowProgress(title: title, steps: names)
            let displayed = display.begin(value)
            // Keep bounded metadata even while disabled, without showing it on re-enable.
            external.begin(value)
            return .object(["id": .string(value.id.uuidString), "displayed": .bool(displayed)])
        case .display_progress_update:
            let id = try uuid(p), rawStep = try number(p, "step")
            var value = try progress(id)
            let index = Int(rawStep) - 1
            guard value.steps.indices.contains(index), let state = WorkflowState(rawValue: try string(p, "state")) else { throw fail("invalid_parameters", "Invalid step or state.") }
            value.steps[index].state = state
            value.steps[index].message = try optionalString(p, "message")
            let displayed = display.update(value)
            _ = external.update(value)
            return .object(["displayed": .bool(displayed)])
        case .display_progress_finish:
            let id = try uuid(p); var value = try progress(id)
            let failed = try boolean(p, "failed", default: false)
            value.state = failed ? .failed : .completed
            value.message = try optionalString(p, "message")
            let displayed = display.update(value); external.dismiss(id)
            return .object(["displayed": .bool(displayed)])
        case .display_dismiss:
            let id = p["id"] == nil ? nil : try uuid(p)
            display.dismiss(id)
            if let id { external.dismiss(id) } else { external.dismiss() }
            return .object(["dismissed": .bool(true)])
        case .automations_list: return try .init(encoding: config.automations)
        case .automations_run: let progress = try run(string(p, "automation"))
            return .object(["runID": .string(progress.id.uuidString), "state": .string(progress.state.rawValue)])
        case .automations_status: let id = try uuid(p)
            guard let value = runner.status(id) else { throw fail("not_found", "Run not found in recent history.") }
            return try .init(encoding: value)
        case .automations_cancel: let id = try uuid(p)
            guard let value = runner.cancel(id) else { throw fail("not_found", "Run not found in recent history.") }
            return try .init(encoding: value)
        }
    }
    private var external = ProgressSessions()
    private func progress(_ id: UUID) throws -> WorkflowProgress {
        external.expire()
        guard let value = external.sessions.first(where: { $0.progress.id == id })?.progress else { throw fail("not_found", "Progress session expired or was dismissed.") }
        return value
    }
    private func decodeConfiguration(_ p: JSONObject) throws -> AppConfiguration {
        guard let value = p["configuration"], value.objectValue != nil else { throw fail("invalid_parameters", "configuration must be an object.") }
        return try ConfigurationDocumentDecoder.decode(value)
    }

    private func string(_ p: JSONObject, _ key: String) throws -> String {
        guard let value = p[key]?.stringValue else { throw fail("invalid_parameters", "\(key) must be a string.") }; return value
    }
    private func optionalString(_ p: JSONObject, _ key: String) throws -> String? { p[key] == nil ? nil : try string(p, key) }
    private func number(_ p: JSONObject, _ key: String, default fallback: Double? = nil) throws -> Double {
        if p[key] == nil, let fallback { return fallback }
        guard let value = p[key]?.numberValue else { throw fail("invalid_parameters", "\(key) must be a number.") }; return value
    }
    private func boolean(_ p: JSONObject, _ key: String, default fallback: Bool) throws -> Bool {
        guard let value = p[key] else { return fallback }; guard let bool = value.boolValue else { throw fail("invalid_parameters", "\(key) must be Boolean.") }; return bool
    }
    private func uuid(_ p: JSONObject) throws -> UUID {
        guard let id = UUID(uuidString: try string(p, "id")) else { throw fail("invalid_parameters", "id must be a UUID.") }; return id
    }
    private func fail(_ code: String, _ message: String) -> ControlError { .init(code: code, message: message) }
}
