import Foundation
import HandyToolbeltCore
import HandyToolbeltControl

/// The same strict shape and migration contract for CLI parameters and settings files.
enum ConfigurationDocumentDecoder {
    static let maximumBytes = 1_048_576
    static func decode(_ data: Data) throws -> AppConfiguration {
        guard data.count <= maximumBytes else { throw failure("Settings files must be 1 MiB or smaller.") }
        do { return try decode(JSONDecoder().decode(JSONValue.self, from: data)) }
        catch let error as ControlError { throw error }
        catch { throw failure("Could not read settings JSON: \(error.localizedDescription)") }
    }
    static func decode(_ value: JSONValue) throws -> AppConfiguration {
        guard value.objectValue != nil else { throw failure("Settings must be a JSON object.") }
        do {
            let schema = try ControlSchema.value()
            let version = value.objectValue?["version"]
            let definition = version == .number(6) ? "AppConfiguration" : (version == .number(5) ? "Version5AppConfiguration" : (version == .number(4) ? "Version4AppConfiguration" : "LegacyAppConfiguration"))
            let errors = JSONShapeValidation.errors(value, schema: schema.objectValue?["$defs"]?.objectValue?[definition] ?? .null, root: schema)
            guard errors.isEmpty else { throw failure(errors.joined(separator: " ")) }
            return try value.decode(AppConfiguration.self)
        } catch let error as ControlError { throw error }
        catch { throw failure("Could not decode configuration: \(error.localizedDescription)") }
    }
    static func validated(_ data: Data) throws -> AppConfiguration {
        let config = try decode(data)
        let validation = config.validation()
        guard validation.isValid else { throw failure(validation.errors.joined(separator: " ")) }
        return config
    }
    private static func failure(_ text: String) -> ControlError { .init(code: "invalid_configuration", message: text) }
}
