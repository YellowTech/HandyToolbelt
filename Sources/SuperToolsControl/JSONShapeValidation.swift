import Foundation

/// Checks the IPC configuration shape before Codable can discard a misspelled key.
public enum JSONShapeValidation {
    public static func errors(_ value: JSONValue, schema: JSONValue, root: JSONValue, path: String = "configuration") -> [String] {
        guard let shape = schema.objectValue else { return ["\(path): invalid contract schema."] }
        if let reference = shape["$ref"]?.stringValue {
            guard reference.hasPrefix("#/$defs/"), reference.split(separator: "/").count == 3,
                  let name = reference.split(separator: "/").last,
                  let target = root.objectValue?["$defs"]?.objectValue?[String(name)] else {
                return ["\(path): unresolved contract reference \(reference)."]
            }
            return errors(value, schema: target, root: root, path: path)
        }
        var result: [String] = []
        if let alternatives = shape["oneOf"]?.arrayValue {
            let matches = alternatives.filter { errors(value, schema: $0, root: root, path: path).isEmpty }.count
            if matches != 1 { result.append("\(path): must match exactly one alternative.") }
        }
        if let excluded = shape["not"], errors(value, schema: excluded, root: root, path: path).isEmpty {
            result.append("\(path): matches an excluded shape.")
        }
        if let choices = shape["enum"]?.arrayValue, !choices.contains(value) { result.append("\(path): unsupported value.") }
        if let kind = shape["type"]?.stringValue {
            let valid: Bool
            switch kind {
            case "null": valid = value == .null
            case "object": valid = value.objectValue != nil
            case "array": valid = value.arrayValue != nil
            case "string": valid = value.stringValue != nil
            case "boolean": valid = value.boolValue != nil
            case "number": valid = value.numberValue?.isFinite == true
            case "integer": valid = value.numberValue.map { $0.isFinite && $0.rounded() == $0 } ?? false
            default: return ["\(path): unsupported contract type \(kind)."]
            }
            if !valid { return ["\(path): expected \(kind)."] }
        }
        if let object = value.objectValue {
            let properties = shape["properties"]?.objectValue ?? [:]
            if shape["additionalProperties"]?.boolValue == false {
                for key in object.keys.sorted() where properties[key] == nil { result.append("\(path).\(key): unknown field.") }
            }
            for key in shape["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil { result.append("\(path).\(key): required field.") }
            for (key, item) in object.sorted(by: { $0.key < $1.key }) { if let child = properties[key] { result += errors(item, schema: child, root: root, path: path + "." + key) } }
            if let minimum = shape["minProperties"]?.numberValue, Double(object.count) < minimum { result.append("\(path): too few properties.") }
        }
        if let items = value.arrayValue {
            if let minimum = shape["minItems"]?.numberValue, Double(items.count) < minimum { result.append("\(path): too few items.") }
            if let maximum = shape["maxItems"]?.numberValue, Double(items.count) > maximum { result.append("\(path): too many items.") }
            if let child = shape["items"] { for (index, item) in items.enumerated() { result += errors(item, schema: child, root: root, path: "\(path)[\(index)]") } }
        }
        if let text = value.stringValue {
            if let minimum = shape["minLength"]?.numberValue, Double(text.count) < minimum || (minimum > 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { result.append("\(path): text is too short.") }
            if let maximum = shape["maxLength"]?.numberValue, Double(text.count) > maximum { result.append("\(path): text is too long.") }
            if shape["format"]?.stringValue == "uuid", UUID(uuidString: text) == nil { result.append("\(path): expected UUID.") }
        }
        if let number = value.numberValue {
            if let minimum = shape["minimum"]?.numberValue, number < minimum { result.append("\(path): below minimum \(minimum).") }
            if let maximum = shape["maximum"]?.numberValue, number > maximum { result.append("\(path): above maximum \(maximum).") }
        }
        return result
    }
}
