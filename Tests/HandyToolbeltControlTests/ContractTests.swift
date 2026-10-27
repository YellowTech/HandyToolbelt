import XCTest
import Foundation
import HandyToolbeltCore
@testable import HandyToolbeltControl
@testable import HandyToolbeltCLI

final class ContractTests: XCTestCase {
    func testSwitcherDiagnosticsContract() {
        let schema = ControlContract.definitions["SwitcherStatus"]!
        var status: JSONObject = ["showing": .bool(false), "loading": .bool(false),
            "keyboardAvailable": .bool(true), "activationDiagnostics": .array([.string("result: verified success")])]
        XCTAssertEqual(JSONShapeValidation.errors(.object(status), schema: schema, root: ControlContract.value), [])
        status["activationDiagnostics"] = .array(Array(repeating: .string("stage"), count: 25))
        XCTAssertFalse(JSONShapeValidation.errors(.object(status), schema: schema, root: ControlContract.value).isEmpty)
    }
    func testSnappingDiagnosticsContract() throws {
        var snapshot = WindowSnapDiagnosticsSnapshot()
        var interaction = WindowSnapDiagnostics()
        interaction.mouseDownCount = 1; interaction.mouseDragCount = 12; interaction.mouseUpCount = 1
        interaction.completed = true; interaction.selectedPID = 42; interaction.firstContainingLayer = 1500
        interaction.firstContainingPID = 43; interaction.eventTargetPID = 42
        interaction.eventHandlingWindowID = 17; interaction.eventUnderPointerWindowID = 18
        interaction.axHitError = 0; interaction.axResults = ["AXRole": 0, "AXWindow": -25205]
        interaction.routingMethod = "event_handling_window"; interaction.resolutionMethod = "app_hit"
        interaction.stage = "rejected"; interaction.reason = "ax_window_unavailable"; interaction.commitSucceeded = false
        snapshot.latestInteraction = interaction; snapshot.recordCompletedDrag(interaction)
        let schema = ControlContract.definitions["SnappingDiagnostics"]!
        let value = try JSONValue(encoding: snapshot)
        XCTAssertEqual(JSONShapeValidation.errors(value, schema: schema, root: ControlContract.value), [])
        var invalid = value.objectValue!
        invalid["completedDrags"] = .array(Array(repeating: try JSONValue(encoding: interaction), count: 9))
        XCTAssertFalse(JSONShapeValidation.errors(.object(invalid), schema: schema, root: ControlContract.value).isEmpty)
    }
    func testWindowSnappingOptionalBooleanContract() throws {
        var value = try JSONValue(encoding: WindowSwitcherSettings()).objectValue!
        let shape = ControlContract.definitions["WindowSwitcher"]!
        value.removeValue(forKey: "snappingEnabled")
        XCTAssertEqual(JSONShapeValidation.errors(.object(value), schema: shape, root: ControlContract.value), [])
        XCTAssertFalse(try JSONValue.object(value).decode(WindowSwitcherSettings.self).snappingEnabled)
        value["snappingEnabled"] = .bool(true)
        XCTAssertEqual(JSONShapeValidation.errors(.object(value), schema: shape, root: ControlContract.value), [])
        XCTAssertTrue(try JSONValue.object(value).decode(WindowSwitcherSettings.self).snappingEnabled)
        value["snappingEnabled"] = .string("true")
        XCTAssertFalse(JSONShapeValidation.errors(.object(value), schema: shape, root: ControlContract.value).isEmpty)
    }
    func testBindingToastPreferenceMigrationRoundTripAndStrictSchema() throws {
        var binding = GestureBinding(gesture: .init(kind: .tipTapLeft), action: .init(system: .previousTab))
        let data = try JSONEncoder().encode(binding)
        var json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
        json.removeValue(forKey: "showsToast")
        XCTAssertTrue(try JSONValue.object(json).decode(GestureBinding.self).showsToast)
        let captured = binding
        binding.showsToast = false
        XCTAssertNotEqual(binding, captured, "Queued callbacks reject a binding changed after recognition")
        var config = AppConfiguration(); config.bindings = [binding]
        XCTAssertEqual(config.match(device: .trackpad, gesture: binding.gesture), binding, "Toast opt-out does not disable gesture matching")
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding))
        XCTAssertFalse(try value.decode(GestureBinding.self).showsToast)
        let shape = ControlContract.definitions["Binding"]!
        XCTAssertEqual(JSONShapeValidation.errors(value, schema: shape, root: ControlContract.value), [])
        var invalid = value.objectValue!
        invalid["showsToast"] = .string("false")
        XCTAssertFalse(JSONShapeValidation.errors(.object(invalid), schema: shape, root: ControlContract.value).isEmpty)
    }
    func testTemporalTuningAcceptsLegacyAndRejectsInvalidNewValues() throws {
        var tuning = try JSONValue(encoding: GestureTuning()).objectValue!
        tuning.removeValue(forKey: "longTouchDuration"); tuning.removeValue(forKey: "doubleTapInterval")
        let shape = ControlContract.definitions["Tuning"]!
        XCTAssertEqual(JSONShapeValidation.errors(.object(tuning), schema: shape, root: ControlContract.value), [])
        XCTAssertEqual(try JSONValue.object(tuning).decode(GestureTuning.self).longTouchDuration, 0.55)
        tuning["doubleTapInterval"] = .number(0.61)
        XCTAssertFalse(JSONShapeValidation.errors(.object(tuning), schema: shape, root: ControlContract.value).isEmpty)
        tuning["doubleTapInterval"] = .number(0.28); tuning["longTouchDuration"] = .number(0.29)
        XCTAssertFalse(JSONShapeValidation.errors(.object(tuning), schema: shape, root: ControlContract.value).isEmpty)
    }
    func testMetadataExamplesAndReferences() throws {
        let root = ControlContract.value
        let commands = root.objectValue!["commands"]!.objectValue!
        XCTAssertEqual(Set(commands.keys), Set(ControlCommand.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(root.objectValue!["results"]!.objectValue!.keys), Set(commands.keys))
        for command in ControlCommand.allCases {
            XCTAssertFalse(command.specification.description.isEmpty)
            XCTAssertTrue(CLIParser.help.contains(command.rawValue))
            XCTAssertTrue(CLIParser.help.contains(command.specification.description))
            let errors = JSONShapeValidation.errors(command.specification.example, schema: command.specification.input, root: root)
            XCTAssertEqual(errors, [], command.rawValue)
            try lint(command.specification.input, root: root)
            try lint(command.specification.output, root: root)
        }
        for shape in ControlContract.definitions.values { try lint(shape, root: root) }
    }
    // Explicit subset: a new schema keyword must be implemented or deliberately metadata-only.
    func lint(_ schema: JSONValue, root: JSONValue) throws {
        let shape = try XCTUnwrap(schema.objectValue)
        let supported: Set<String> = ["type", "properties", "required", "additionalProperties", "minProperties", "items", "minItems", "maxItems", "minLength", "maxLength", "format", "enum", "minimum", "maximum", "default", "$ref", "oneOf", "not", "description"]
        XCTAssertEqual(Set(shape.keys).subtracting(supported), [])
        if let reference = shape["$ref"]?.stringValue {
            XCTAssertTrue(reference.hasPrefix("#/$defs/"))
            XCTAssertEqual(reference.split(separator: "/").count, 3)
            XCTAssertNotNil(root.objectValue?["$defs"]?.objectValue?[String(reference.split(separator: "/").last!)])
        }
        if let type = shape["type"]?.stringValue { XCTAssertTrue(["object", "array", "string", "number", "integer", "boolean", "null"].contains(type)) }
        if let format = shape["format"]?.stringValue { XCTAssertEqual(format, "uuid") }
        for child in shape["properties"]?.objectValue?.values ?? Dictionary<String, JSONValue>().values { try lint(child, root: root) }
        if let child = shape["items"] { try lint(child, root: root) }
        if let child = shape["not"] { try lint(child, root: root) }
        for child in shape["oneOf"]?.arrayValue ?? [] { try lint(child, root: root) }
    }
    func testGeneratedReferenceIsCurrentAndDeterministic() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected = try ControlContract.referenceMarkdown()
        XCTAssertEqual(expected, try ControlContract.referenceMarkdown())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Docs/CLI-reference.md"), encoding: .utf8), expected, "Run swift Scripts/verify.swift --generate-docs")
    }
    func testValidatorAlternativesAndInvalidReferences() {
        let root = ControlContract.value
        let alternative: JSONValue = .object(["oneOf": .array([
            .object(["type": .string("number"), "minimum": .number(0)]),
            .object(["type": .string("number"), "maximum": .number(10)])
        ])])
        XCTAssertTrue(JSONShapeValidation.errors(.number(-1), schema: alternative, root: root).isEmpty)
        XCTAssertFalse(JSONShapeValidation.errors(.number(5), schema: alternative, root: root).isEmpty)
        XCTAssertFalse(JSONShapeValidation.errors(.string("x"), schema: alternative, root: root).isEmpty)
        XCTAssertFalse(JSONShapeValidation.errors(.null, schema: .object(["$ref": .string("#/$defs/Missing")]), root: root).isEmpty)
        XCTAssertFalse(JSONShapeValidation.errors(.null, schema: .null, root: root).isEmpty)
        XCTAssertFalse(ControlCommand.display_text.inputErrors(["text": .string(" \n ")]).isEmpty)
        XCTAssertFalse(ControlCommand.display_text.inputErrors(["text": .string("x"), "duration": .number(.infinity)]).isEmpty)
        XCTAssertFalse(ControlCommand.coffee_set.inputErrors([:]).isEmpty)
        XCTAssertFalse(ControlCommand.display_progress_update.inputErrors(["id": .string(UUID().uuidString), "step": .number(1.5), "state": .string("running")]).isEmpty)
    }
    func testWindowChooserOptionalSettingsValidateAndRoundTrip() throws {
        let root = ControlContract.value, schema = ControlContract.definitions["WindowSwitcher"]!
        var legacy = try JSONValue(encoding: WindowSwitcherSettings()).objectValue!
        legacy.removeValue(forKey: "layout"); legacy.removeValue(forKey: "showsPreviews")
        XCTAssertEqual(JSONShapeValidation.errors(.object(legacy), schema: schema, root: root), [])
        for layout in WindowLayout.allCases {
            for previews in [false, true] {
                var value = legacy; value["layout"] = .string(layout.rawValue); value["showsPreviews"] = .bool(previews)
                XCTAssertEqual(JSONShapeValidation.errors(.object(value), schema: schema, root: root), [])
                let decoded = try JSONValue.object(value).decode(WindowSwitcherSettings.self)
                XCTAssertEqual(decoded.layout, layout); XCTAssertEqual(decoded.showsPreviews, previews)
            }
        }
        var invalid = legacy; invalid["layout"] = .string("carousel")
        XCTAssertFalse(JSONShapeValidation.errors(.object(invalid), schema: schema, root: root).isEmpty)
    }
        func testRawConfigurationAndLegacyShapes() throws {
        let root = ControlContract.value, schema = ControlContract.definitions["LegacyAppConfiguration"]!
        for version in 1...3 {
            let legacy: JSONValue = .object(["version": .number(Double(version)), "bindings": .array([]), "isEnabled": .bool(true)])
            XCTAssertEqual(JSONShapeValidation.errors(legacy, schema: schema, root: root), [])
            XCTAssertTrue(try legacy.decode(AppConfiguration.self).validation().isValid)
        }
        let version5: JSONValue = .object(["version": .number(5), "bindings": .array([]), "coffeeModuleEnabled": .bool(false)])
        XCTAssertEqual(JSONShapeValidation.errors(version5, schema: ControlContract.definitions["Version5AppConfiguration"]!, root: root), [])
        let migrated5 = try version5.decode(AppConfiguration.self)
        XCTAssertEqual(migrated5.version, 6)
        XCTAssertTrue(migrated5.powerModuleEnabled)
        XCTAssertFalse(migrated5.coffeeModuleEnabled)
        let current = ControlContract.definitions["AppConfiguration"]!
        let minimal: JSONValue = .object(["version": .number(6), "bindings": .array([])])
        XCTAssertEqual(JSONShapeValidation.errors(minimal, schema: current, root: root), [])
        for obsolete in ["isEnabled", "pauseAll", "unknownSetting"] {
            var invalid = minimal.objectValue!; invalid[obsolete] = .bool(true)
            XCTAssertFalse(JSONShapeValidation.errors(.object(invalid), schema: current, root: root).isEmpty)
        }
        let step: JSONObject = ["id": .string(UUID().uuidString), "name": .string("Wait"), "delay": .number(1)]
        let stepSchema = ControlContract.definitions["AutomationStep"]!
        XCTAssertEqual(JSONShapeValidation.errors(.object(step), schema: stepSchema, root: root), [])
        var both = step; both["action"] = try .init(encoding: GestureAction(kind: .showText, text: "Ready"))
        XCTAssertFalse(JSONShapeValidation.errors(.object(both), schema: stepSchema, root: root).isEmpty)
        var neither = step; neither.removeValue(forKey: "delay")
        XCTAssertFalse(JSONShapeValidation.errors(.object(neither), schema: stepSchema, root: root).isEmpty)
        let tuningKeys = Set(try JSONValue(encoding: GestureTuning()).objectValue!.keys)
        let tuningSchema = ControlContract.definitions["Tuning"]!.objectValue!
        XCTAssertEqual(tuningKeys, Set(GestureTuning.bounds.keys))
        XCTAssertEqual(tuningKeys, Set(tuningSchema["properties"]!.objectValue!.keys))
        XCTAssertEqual(tuningKeys.subtracting(["longTouchDuration", "doubleTapInterval"]), Set(tuningSchema["required"]!.arrayValue!.compactMap(\.stringValue)))
        for (key, bounds) in GestureTuning.bounds {
            let exported = ControlContract.definitions["Tuning"]!.objectValue!["properties"]!.objectValue![key]!.objectValue!
            XCTAssertEqual(exported["minimum"], .number(bounds.lowerBound))
            XCTAssertEqual(exported["maximum"], .number(bounds.upperBound))
        }
    }
    func testStackContractRejectsUnknownAndHoldOutsideStart() throws {
        let root = ControlContract.value
        var config = AppConfiguration(); config.bindings = []; config.stacks = [.init()]
        let raw = try JSONValue(encoding: config)
        XCTAssertEqual(JSONShapeValidation.errors(raw, schema: ControlContract.definitions["AppConfiguration"]!, root: root), [])
        let hold = try JSONValue(encoding: GestureStackAction(kind: .holdModifiers))
        XCTAssertFalse(JSONShapeValidation.errors(hold, schema: ControlContract.definitions["Action"]!, root: root).isEmpty)
        var unknown = raw.objectValue!; unknown["nestedStacks"] = .array([])
        XCTAssertFalse(JSONShapeValidation.errors(.object(unknown), schema: ControlContract.definitions["AppConfiguration"]!, root: root).isEmpty)
        let legacy: JSONValue = .object(["version": .number(4), "bindings": .array([])])
        XCTAssertEqual(JSONShapeValidation.errors(legacy, schema: ControlContract.definitions["Version4AppConfiguration"]!, root: root), [])
    }

}
