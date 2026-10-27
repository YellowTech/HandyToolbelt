import Foundation
import HandyToolbeltCore

/// The supported local protocol. Additions require a specification and an exhaustive app handler.
public enum ControlCommand: String, CaseIterable, Sendable {
    case schema = "schema"
    case status = "status"
    case login_status = "login.status"
    case login_set = "login.set"
    case power_status = "power.status"
    case coffee_status = "coffee.status"
    case coffee_set = "coffee.set"
    case config_get = "config.get"
    case automations_list = "automations.list"
    case config_validate = "config.validate"
    case config_apply = "config.apply"
    case config_undo = "config.undo"
    case display_text = "display.text"
    case display_toast = "display.toast"
    case display_progress_begin = "display.progress.begin"
    case display_progress_update = "display.progress.update"
    case display_progress_finish = "display.progress.finish"
    case display_dismiss = "display.dismiss"
    case automations_run = "automations.run"
    case automations_status = "automations.status"
    case automations_cancel = "automations.cancel"

    public var specification: CommandSpecification {
        switch self {
        case .login_status:
            return .init(description: "Read macOS start-at-login registration and approval status.",
                input: object([:]), output: ref("LoginStatus"), example: .object([:]))
        case .login_set:
            return .init(description: "Enable or disable start at login using macOS. Approval may still be required in Login Items settings.",
                input: object(["enabled": boolean], required: ["enabled"]), output: ref("LoginStatus"),
                example: .object(["enabled": .bool(true)]))
        case .automations_cancel:
            return .init(
                description: "Cancel an automation run.",
                input: object([
                    "id": uuid
                ], required: ["id"]),
                output: ref("WorkflowProgress"),
                example: .object(["id": .string("00000000-0000-0000-0000-000000000001")] ))
        case .automations_list:
            return .init(
                description: "List saved automations.",
                input: object([:]),
                output: array(ref("Automation")),
                example: .object([:]))
        case .automations_run:
            return .init(
                description: "Run one saved automation by UUID or unique name.",
                input: object([
                    "automation": string(min: 1, max: ConfigurationLimits.maximumNameLength)
                ], required: ["automation"]),
                output: object([
                    "runID": uuid,
                    "state": enumeration(WorkflowState.allCases.map(\.rawValue))
                ], required: ["runID", "state"]),
                example: .object(["automation": .string("Prepare review")] ))
        case .automations_status:
            return .init(
                description: "Read recent automation run progress.",
                input: object([
                    "id": uuid
                ], required: ["id"]),
                output: ref("WorkflowProgress"),
                example: .object(["id": .string("00000000-0000-0000-0000-000000000001")] ))
        case .coffee_set:
            return .init(
                description: "Set one or both Coffee power settings.",
                input: object([
                    "keepDisplayAwake": boolean,
                    "preventIdleSleep": boolean
                ], minimumProperties: 1),
                output: ref("CoffeeStatus"),
                example: .object(["preventIdleSleep": .bool(true)] ))
        case .power_status:
            return .init(description: "Read built-in battery charge and power state. Unknown readings are null; this does not control charging.", input: object([:]), output: ref("PowerStatus"), example: .object([:]))
        case .coffee_status:
            return .init(
                description: "Read Coffee requested and effective power settings.",
                input: object([:]),
                output: ref("CoffeeStatus"),
                example: .object([:]))
        case .config_apply:
            return .init(
                description: "Apply a valid complete configuration if expectedRevision matches.",
                input: object([
                    "configuration": ref("AppConfiguration"),
                    "expectedRevision": string(min: 1, max: 64)
                ], required: ["configuration", "expectedRevision"]),
                output: object([
                    "revision": string()
                ], required: ["revision"]),
                example: .object(["configuration": .object(["version": .number(6), "bindings": .array([]), "trackpadModuleEnabled": .bool(false)] ), "expectedRevision": .string("REVISION")] ))
        case .config_get:
            return .init(
                description: "Read the complete configuration and its revision.",
                input: object([:]),
                output: object([
                    "configuration": object([:], additional: true),
                    "revision": string()
                ], required: ["configuration", "revision"]),
                example: .object([:]))
        case .config_undo:
            return .init(
                description: "Undo the last apply if its revision still matches.",
                input: object([
                    "expectedRevision": string(min: 1, max: 64)
                ], required: ["expectedRevision"]),
                output: object([
                    "revision": string()
                ], required: ["revision"]),
                example: .object(["expectedRevision": .string("REVISION")] ))
        case .config_validate:
            return .init(
                description: "Validate a configuration without saving it; errors are returned in a successful report.",
                input: object([
                    "configuration": ref("AppConfiguration")
                ], required: ["configuration"]),
                output: object([
                    "errors": array(string()),
                    "warnings": array(string())
                ], required: ["errors", "warnings"]),
                example: .object(["configuration": .object(["version": .number(6), "bindings": .array([]), "trackpadModuleEnabled": .bool(false)] )] ))
        case .display_dismiss:
            return .init(
                description: "Dismiss one progress session, or all sessions.",
                input: object([
                    "id": uuid
                ]),
                output: object([
                    "dismissed": boolean
                ], required: ["dismissed"]),
                example: .object([:]))
        case .display_progress_begin:
            return .init(
                description: "Begin progress with named steps.",
                input: object([
                    "steps": array(string(min: 1, max: ConfigurationLimits.maximumNameLength), min: 1, max: ConfigurationLimits.maximumAutomationSteps),
                    "title": string(min: 1, max: ConfigurationLimits.maximumNameLength)
                ], required: ["title", "steps"]),
                output: object([
                    "id": uuid,
                    "displayed": boolean
                ], required: ["id", "displayed"]),
                example: .object(["title": .string("Prepare review"), "steps": .array([.string("Open document"), .string("Arrange windows")])] ))
        case .display_progress_finish:
            return .init(
                description: "Complete or fail progress.",
                input: object([
                    "failed": boolean,
                    "id": uuid,
                    "message": string(min: 1, max: GestureAction.maximumTextLength)
                ], required: ["id"]),
                output: displayedResult,
                example: .object(["id": .string("00000000-0000-0000-0000-000000000001")] ))
        case .display_progress_update:
            return .init(
                description: "Update a progress step using a 1-based index.",
                input: object([
                    "id": uuid,
                    "message": string(min: 1, max: GestureAction.maximumTextLength),
                    "state": enumeration(WorkflowState.progressStepStates.map(\.rawValue)),
                    "step": number(integer: true, min: 1, max: Double(ConfigurationLimits.maximumAutomationSteps))
                ], required: ["id", "step", "state"]),
                output: displayedResult,
                example: .object(["id": .string("00000000-0000-0000-0000-000000000001"), "step": .number(1), "state": .string("running")] ))
        case .display_text:
            return .init(
                description: "Display brief text.",
                input: object([
                    "duration": displayDuration(defaulted: true),
                    "text": string(min: 1, max: GestureAction.maximumTextLength)
                ], required: ["text"]),
                output: displayedResult,
                example: .object(["text": .string("Ready")] ))
        case .display_toast:
            return .init(
                description: "Display a toast.",
                input: object([
                    "duration": displayDuration(defaulted: true),
                    "text": string(min: 1, max: GestureAction.maximumTextLength)
                ], required: ["text"]),
                output: displayedResult,
                example: .object(["text": .string("Ready")] ))
        case .schema:
            return .init(
                description: "Read the complete command and configuration contract.",
                input: object([:]),
                output: object([
                    "protocolVersion": number(integer: true),
                    "commands": object([:], additional: true),
                    "$defs": object([:], additional: true),
                    "results": object([:], additional: true)
                ], required: ["protocolVersion", "commands", "$defs", "results"], additional: true),
                example: .object([:]))
        case .status:
            return .init(
                description: "Read runtime status, module flags, revision, and current activity.",
                input: object([:]),
                output: object([
                    "version": string(),
                    "modules": object([
                        "trackpad": boolean,
                        "windows": boolean,
                        "snapping": boolean,
                        "display": boolean,
                        "coffee": boolean,
                        "power": boolean
                    ], required: ["trackpad", "windows", "snapping", "display", "coffee", "power"]),
                    "revision": string(),
                    "display": ref("DisplayStatus"),
                    "accessibility": boolean,
                    "trackpadRunning": boolean,
                    "inputError": nullable(string()),
                    "controlAvailable": boolean,
                    "switcher": ref("SwitcherStatus"),
                    "snapping": ref("SnappingStatus"),
                    "coffee": ref("CoffeeStatus"),
                    "power": ref("PowerStatus"),
                    "login": ref("LoginStatus"),
                    "automation": nullable(ref("WorkflowProgress"))
                ], required: ["version", "modules", "revision", "display", "coffee", "power", "automation"], additional: true),
                example: .object([:]))
        }
    }
    public func inputErrors(_ parameters: JSONObject) -> [String] {
        // Configuration shape errors belong to the validation report or invalid_configuration,
        // after envelope validation. Never let Codable sanitize raw configuration first.
        var schema = specification.input.objectValue!
        if self == .config_validate || self == .config_apply {
            var properties = schema["properties"]!.objectValue!
            properties["configuration"] = .object([:]); schema["properties"] = .object(properties)
            if self == .config_validate { schema["required"] = .array([]) }
        }
        return JSONShapeValidation.errors(.object(parameters), schema: .object(schema), root: ControlContract.value, path: "parameters")
    }
    public func outputErrors(_ value: JSONValue) -> [String] {
        JSONShapeValidation.errors(value, schema: specification.output, root: ControlContract.value, path: "result")
    }
}

public struct CommandSpecification: Sendable {
    public let description: String
    public let input: JSONValue
    public let output: JSONValue
    public let example: JSONValue
}

public enum ControlContract {
    public static var value: JSONValue {
        .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "protocolVersion": .number(1),
            "commands": .object(Dictionary(uniqueKeysWithValues: ControlCommand.allCases.map { ($0.rawValue, $0.specification.input) })),
            "results": .object(Dictionary(uniqueKeysWithValues: ControlCommand.allCases.map { ($0.rawValue, $0.specification.output) })),
            "descriptions": .object(Dictionary(uniqueKeysWithValues: ControlCommand.allCases.map { ($0.rawValue, .string($0.specification.description)) })),
            "$defs": .object(definitions),
            "configuration": .object(["$ref": .string("#/$defs/AppConfiguration")]),
            "notes": .array([.string("Use config.get, edit the configuration, then config.validate and config.apply with expectedRevision from config.get."), .string("All IDs must be unique within each kind. Group and automation references must exist."), .string("Force clicks require a Force Touch trackpad and use 1–5 fingers, or 1–4 with a corner or as a stack child. Native app clicks may also occur; a paired Click action waits for release and is discarded after Force click. Ordinary taps, clicks, and swipes without a corner require 2–5 fingers; corner gestures and stack children can use 1 finger. Left/right tip-taps and tip-swipes use 2–4 fingers: 1–3 resting fingers plus one active finger. Middle tip-taps use exactly 3 fingers. A corner modifier reserves one extra finger (maximum 5 total)."), .string("Enabled bindings with overlapping gesture and scope are errors. Incomplete disabled actions are warnings."), .string("display requests succeed with displayed:false when Overlays is off or unavailable."), .string("One automation runs at a time. Cancellation cannot interrupt a native AppleScript already in flight."), .string("Progress steps use 1-based indexes. External progress expires 30 seconds after an update; in-process automation progress remains until the run ends or feedback is dismissed; completion dismisses after 1 second, failure after 3.")]),
            "examples": .array(ControlCommand.allCases.map { .object(["command": .string($0.rawValue), "parameters": $0.specification.example]) })
        ])
    }
    public static var definitions: JSONObject {
        var definitions: JSONObject = [
            "SwitcherStatus": object([
                "showing": boolean, "loading": boolean, "keyboardAvailable": boolean,
                "activationDiagnostics": array(string(), max: 24)
            ], required: ["showing", "loading", "keyboardAvailable", "activationDiagnostics"]),
            "SnappingStatus": object([
                "enabled": boolean, "eligible": boolean, "monitoring": boolean,
                "status": string(), "diagnostics": nullable(ref("SnappingDiagnostics"))
            ], required: ["enabled", "eligible", "monitoring", "status", "diagnostics"]),
            "SnappingDiagnostics": object([
                "totalMouseDownCount": number(integer: true, min: 0),
                "totalMouseDragCount": number(integer: true, min: 0),
                "totalMouseUpCount": number(integer: true, min: 0),
                "latestInteraction": ref("SnappingInteraction"),
                "completedDrags": array(ref("SnappingInteraction"), max: 8)
            ], required: ["totalMouseDownCount", "totalMouseDragCount", "totalMouseUpCount", "latestInteraction", "completedDrags"]),
            "SnappingInteraction": object([
                "generation": number(integer: true, min: 0), "stage": string(), "reason": string(),
                "mouseDownCount": number(integer: true, min: 0), "mouseDragCount": number(integer: true, min: 0),
                "mouseUpCount": number(integer: true, min: 0), "processedDragCount": number(integer: true, min: 0),
                "selectedPID": number(integer: true), "firstContainingLayer": number(integer: true),
                "firstContainingPID": number(integer: true), "eventTargetPID": number(integer: true),
                "eventHandlingWindowID": number(integer: true, min: 0), "eventUnderPointerWindowID": number(integer: true, min: 0),
                "axHitError": number(integer: true), "routingMethod": string(), "resolutionMethod": string(),
                "axResults": object(Dictionary(uniqueKeysWithValues: ["AXRole", "AXWindow", "AXSubrole", "AXMinimized", "AXFullScreen", "AXPosition", "AXSize", "position_settable", "size_settable", "set_size", "set_position"].map { ($0, number(integer: true)) })),
                "resolved": boolean, "movementConfirmed": boolean, "targetFound": boolean,
                "commitSucceeded": boolean, "completed": boolean
            ], required: ["generation", "stage", "mouseDownCount", "mouseDragCount", "mouseUpCount", "processedDragCount", "axResults", "resolved", "movementConfirmed", "targetFound", "completed"]),
            "Action": object([
                "automationID": uuid,
                "applicationBundleIdentifier": string(max: 255),
                "kind": enumeration(ActionKind.allCases.map(\.rawValue)),
                "script": string(max: GestureAction.maximumScriptLength),
                "shortcut": ref("Shortcut"),
                "system": enumeration(SystemAction.allCases.map(\.rawValue)),
                "text": string(max: GestureAction.maximumTextLength),
                "textDuration": displayDuration()
            ], required: ["kind", "system", "script"]),
            "AppConfiguration": object([
                "applicationGroups": array(ref("ApplicationGroup")),
                "automations": array(ref("Automation")),
                "bindings": array(ref("Binding")),
                "stacks": array(ref("GestureStack")),
                "powerModuleEnabled": boolean,
                "coffeeModuleEnabled": boolean,
                "snappingModuleEnabled": boolean,
                "displayModuleEnabled": boolean,
                "hapticPattern": ref("Haptic"),
                "hapticsInPractice": boolean,
                "mouseTuning": ref("Tuning"),
                "trackpadModuleEnabled": boolean,
                "trackpadTuning": ref("Tuning"),
                "version": extending(number(integer: true), ["enum": .array([.number(6)])]),
                "visualFeedbackEnabled": boolean,
                "windowSwitcher": ref("WindowSwitcher")
            ], required: ["version", "bindings"]),
            "LegacyAppConfiguration": object([
                "applicationGroups": array(ref("ApplicationGroup")),
                "automations": array(ref("Automation")),
                "bindings": array(ref("Binding")),
                "coffeeModuleEnabled": boolean,
                "snappingModuleEnabled": boolean,
                "displayModuleEnabled": boolean,
                "hapticPattern": ref("Haptic"),
                "hapticsInPractice": boolean,
                "isEnabled": boolean,
                "mouseTuning": ref("Tuning"),
                "pauseAll": boolean,
                "trackpadModuleEnabled": boolean,
                "trackpadTuning": ref("Tuning"),
                "version": extending(number(integer: true), ["enum": .array([.number(1), .number(2), .number(3)])]),
                "visualFeedbackEnabled": boolean,
                "windowSwitcher": ref("WindowSwitcher")
            ], required: ["version", "bindings", "isEnabled"]),
            "ApplicationGroup": object([
                "applications": array(object([
                    "bundleIdentifier": string(min: 1, max: 255),
                    "name": string(min: 1, max: ConfigurationLimits.maximumNameLength)
                ], required: ["name", "bundleIdentifier"])),
                "id": uuid,
                "name": string(min: 1, max: ConfigurationLimits.maximumNameLength)
            ], required: ["id", "name", "applications"]),
            "Automation": object([
                "id": uuid,
                "name": string(min: 1, max: ConfigurationLimits.maximumNameLength),
                "steps": array(ref("AutomationStep"), min: 1, max: ConfigurationLimits.maximumAutomationSteps)
            ], required: ["id", "name", "steps"]),
            "AutomationStep": extending(object([
                "action": ref("Action"),
                "delay": number(min: ConfigurationLimits.automationDelayRange.lowerBound, max: ConfigurationLimits.automationDelayRange.upperBound),
                "id": uuid,
                "name": string(min: 1, max: ConfigurationLimits.maximumNameLength)
            ], required: ["id", "name"]), [
                "description": .string("Exactly one action or delay. Actions may not have kind automation."),
                "oneOf": .array([
                    .object(["required": .array([.string("action")]), "not": .object(["required": .array([.string("delay")])])]),
                    .object(["required": .array([.string("delay")]), "not": .object(["required": .array([.string("action")])])])
                ])
            ]),
            "Binding": object([
                "action": ref("Action"),
                "applicationGroupID": uuid,
                "device": enumeration(InputDevice.allCases.map(\.rawValue)),
                "gesture": ref("Gesture"),
                "hapticPattern": ref("Haptic"),
                "keyboardModifiers": ref("KeyboardModifierRequirement"),
                "showsToast": .object(["type": .string("boolean"), "default": .bool(true), "description": .string("Allow this binding to show gesture toasts when global gesture toasts and Overlays are enabled. Show Text actions use their own message.")]),
                "id": uuid,
                "isEnabled": boolean
            ], required: ["id", "device", "gesture", "action", "isEnabled"]),
            "KeyboardModifierRequirement": object([
                "mode": enumeration(["any", "exact"]),
                "modifiers": array(enumeration(KeyboardModifier.allCases.map(\.rawValue)), max: 4)
            ], required: ["mode", "modifiers"]),
            "GestureStackAction": object([
                "id": uuid, "kind": enumeration(GestureStackActionKind.allCases.map(\.rawValue)),
                "action": ref("Action"), "modifiers": array(enumeration(KeyboardModifier.allCases.map(\.rawValue)), max: 4)
            ], required: ["id", "kind", "action", "modifiers"]),
            "GestureStackBinding": object([
                "id": uuid, "gesture": ref("Gesture"), "keyboardModifiers": ref("KeyboardModifierRequirement"),
                "actions": array(ref("Action"), max: ConfigurationLimits.maximumStackActions), "isEnabled": boolean
            ], required: ["id", "gesture", "actions"]),
            "GestureStack": object([
                "id": uuid, "name": string(max: ConfigurationLimits.maximumNameLength),
                "device": enumeration(InputDevice.allCases.map(\.rawValue)), "corner": enumeration(Corner.allCases.map(\.rawValue)),
                "applicationGroupID": uuid, "keyboardModifiers": ref("KeyboardModifierRequirement"), "isEnabled": boolean,
                "startActions": array(ref("GestureStackAction"), max: ConfigurationLimits.maximumStackActions),
                "bindings": array(ref("GestureStackBinding"), max: ConfigurationLimits.maximumStackBindings),
                "releaseActions": array(ref("Action"), max: ConfigurationLimits.maximumStackActions)
            ], required: ["id", "name", "device", "corner", "startActions", "bindings", "releaseActions"]),
            "Gesture": object([
                "corner": enumeration(Corner.allCases.map(\.rawValue)),
                "fingers": number(integer: true, min: 1, max: 5),
                "kind": enumeration(GestureKind.allCases.map(\.rawValue))
            ], required: ["kind", "fingers", "corner"]),
            "Haptic": enumeration(HapticPattern.allCases.map(\.rawValue)),
            "Shortcut": object([
                "keyCode": number(integer: true, min: 0, max: 65535),
                "keyLabel": string(min: 1, max: ConfigurationLimits.maximumNameLength),
                "modifiers": number(integer: true, min: 0)
            ], required: ["keyCode", "modifiers", "keyLabel"]),
            "Tuning": object(GestureTuning.bounds.mapValues { number(min: $0.lowerBound, max: $0.upperBound) }, required: ["tapDuration", "tapTravel", "anchorHold", "cornerHold", "swipeTravel", "handAngleDegrees", "tipSeparation", "cornerSize"]),
            "WindowSwitcher": object([
                "currentAppOnly": boolean,
                "includeHidden": boolean,
                "includeMinimized": boolean,
                "isEnabled": boolean,
                "shortcut": enumeration(WindowShortcut.allCases.map(\.rawValue)),
                "layout": enumeration(WindowLayout.allCases.map(\.rawValue)),
                "showsPreviews": boolean,
                "snappingEnabled": .object(["type": .string("boolean"), "description": .string("Legacy import field. Used only when top-level snappingModuleEnabled is absent, and only if this Switcher was enabled. New configurations must use snappingModuleEnabled; exports omit this field.")]),
                "previewScale": number(min: 0.75, max: 1.5)
            ], required: ["isEnabled", "shortcut", "currentAppOnly", "includeMinimized", "includeHidden"]),
            "LoginStatus": object([
                "status": enumeration(["notRegistered", "enabled", "requiresApproval", "notFound"]),
                "enabled": boolean,
                "error": nullable(string())
            ], required: ["status", "enabled", "error"]),
            "DisplayStatus": object([
                        "available": boolean,
                        "enabled": boolean,
                        "sessions": array(ref("WorkflowProgress"))
                    ], required: ["available", "enabled", "sessions"]),
            "PowerStatus": object([
                "designCapacityMAh": nullable(number()),
                "fullChargeCapacityMAh": nullable(number()),
                "estimatedHealthPercent": nullable(number()),
                "nominalChargeCapacityMAh": nullable(number()),
                "healthEstimateSource": nullable(enumeration(["nominalCapacity", "fullChargeCapacity"])),
                "adapterWatts": nullable(number()),
                "batteryWatts": nullable(number()),
                "inputWatts": nullable(number()),
                "systemLoadWatts": nullable(number()),
                "estimatedMacWatts": nullable(number()),
                "cycleCount": nullable(number(integer: true)), "externalConnected": nullable(boolean), "adapterName": nullable(string()),
                "enabled": boolean, "running": boolean,
                "batteryPresent": nullable(boolean),
                "chargePercent": nullable(number(integer: true, min: 0, max: 100)),
                "isCharging": nullable(boolean), "isCharged": nullable(boolean),
                "powerSource": nullable(enumeration(["ac", "battery"])), "error": nullable(string())
            ], required: ["enabled", "running", "batteryPresent", "chargePercent", "isCharging", "isCharged", "powerSource", "error", "cycleCount", "designCapacityMAh", "fullChargeCapacityMAh", "nominalChargeCapacityMAh", "estimatedHealthPercent", "healthEstimateSource", "adapterWatts", "adapterName", "externalConnected", "batteryWatts", "inputWatts", "systemLoadWatts", "estimatedMacWatts"]),
            "CoffeeStatus": object([
                "enabled": boolean,
                "running": boolean,
                "isActive": boolean,
                "requested": object([
                    "preventIdleSleep": boolean,
                    "keepDisplayAwake": boolean
                ], required: ["preventIdleSleep", "keepDisplayAwake"]),
                "effective": object([
                    "preventIdleSleep": boolean,
                    "keepDisplayAwake": boolean
                ], required: ["preventIdleSleep", "keepDisplayAwake"]),
                "error": nullable(string())
            ], required: ["enabled", "running", "isActive", "requested", "effective", "error"]),
            "WorkflowProgress": object([
                "id": uuid,
                "title": string(),
                "state": enumeration(WorkflowState.allCases.map(\.rawValue)),
                "steps": array(object([
                    "name": string(),
                    "state": enumeration(WorkflowState.allCases.map(\.rawValue)),
                    "message": string()
                ], required: ["name", "state"])),
                "message": string()
            ], required: ["id", "title", "state", "steps"]),
        ]
        var legacy5 = definitions["AppConfiguration"]!.objectValue!
        var properties5 = legacy5["properties"]!.objectValue!
        properties5.removeValue(forKey: "powerModuleEnabled")
        properties5["version"] = extending(number(integer: true), ["enum": .array([.number(5)])])
        legacy5["properties"] = .object(properties5)
        definitions["Version5AppConfiguration"] = .object(legacy5)
        var legacy4 = definitions["AppConfiguration"]!.objectValue!
        var properties = legacy4["properties"]!.objectValue!
        properties.removeValue(forKey: "stacks")
        properties.removeValue(forKey: "powerModuleEnabled")
        properties["version"] = extending(number(integer: true), ["enum": .array([.number(4)])])
        legacy4["properties"] = .object(properties)
        definitions["Version4AppConfiguration"] = .object(legacy4)
        return definitions
    }
    public static var commandHelp: String {
        ControlCommand.allCases.map { "  call \($0.rawValue) — \($0.specification.description)" }.joined(separator: "\n")
    }
    public static func referenceMarkdown() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func json(_ value: JSONValue) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        var text = "# CLI command reference\n\n<!-- Generated from ControlContract. Run Scripts/verify.swift --generate-docs. -->\n\nThe CLI reads and configures trackpad bindings, actions, application groups, and detection tuning through config.get, config.validate, and config.apply. Gesture Gym and live contacts are available in the app UI.\n\nInput and successful result schemas below describe the supported protocol subset; configuration semantic checks also run on the server. Examples containing IDs or revisions require values from the current app. Configuration examples show shape only and are replacements, not merges: obtain config.get, edit its complete configuration while retaining unrelated fields, and validate before applying. Never apply a configuration example as a patch.\n"
        for command in ControlCommand.allCases {
            let spec = command.specification
            text += "\n## \(command.rawValue)\n\n\(spec.description)\n\nExample parameters:\n\n```json\n\(try json(spec.example))\n```\n\nInput:\n\n```json\n\(try json(spec.input))\n```\n\nSuccessful result:\n\n```json\n\(try json(spec.output))\n```\n"
        }
        text += "\n## Shared definitions\n\n```json\n\(try json(.object(definitions)))\n```\n"
        return text
    }
}

// Small schema builders. JSONShapeValidation implements precisely these keywords;
// the exported schemas are also readable by general JSON Schema tooling.
private func object(_ properties: JSONObject, required: [String] = [], additional: Bool = false, minimumProperties: Int? = nil) -> JSONValue {
    var value: JSONObject = ["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(additional)]
    if let minimumProperties { value["minProperties"] = .number(Double(minimumProperties)) }
    return .object(value)
}
private func string(min: Int? = nil, max: Int? = nil) -> JSONValue {
    var value: JSONObject = ["type": .string("string")]
    if let min { value["minLength"] = .number(Double(min)) }; if let max { value["maxLength"] = .number(Double(max)) }
    return .object(value)
}
private func number(integer: Bool = false, min: Double? = nil, max: Double? = nil, fallback: Double? = nil) -> JSONValue {
    var value: JSONObject = ["type": .string(integer ? "integer" : "number")]
    if let min { value["minimum"] = .number(min) }; if let max { value["maximum"] = .number(max) }; if let fallback { value["default"] = .number(fallback) }
    return .object(value)
}
private func array(_ items: JSONValue, min: Int? = nil, max: Int? = nil) -> JSONValue {
    var value: JSONObject = ["type": .string("array"), "items": items]
    if let min { value["minItems"] = .number(Double(min)) }; if let max { value["maxItems"] = .number(Double(max)) }
    return .object(value)
}
private func enumeration(_ values: [String]) -> JSONValue { extending(string(), ["enum": .array(values.map(JSONValue.string))]) }
private func ref(_ name: String) -> JSONValue { .object(["$ref": .string("#/$defs/" + name)]) }
private func extending(_ schema: JSONValue, _ fields: JSONObject) -> JSONValue { .object(schema.objectValue!.merging(fields) { _, new in new }) }
private let boolean = JSONValue.object(["type": .string("boolean")])
private let uuid = extending(string(), ["format": .string("uuid")])

private func displayDuration(defaulted: Bool = false) -> JSONValue {
    number(min: GestureAction.textDurationRange.lowerBound, max: GestureAction.textDurationRange.upperBound,
           fallback: defaulted ? GestureAction.defaultTextDuration : nil)
}
private func nullable(_ schema: JSONValue) -> JSONValue {
    .object(["oneOf": .array([schema, .object(["type": .string("null")])])])
}

private let displayedResult = object(["displayed": boolean], required: ["displayed"])
