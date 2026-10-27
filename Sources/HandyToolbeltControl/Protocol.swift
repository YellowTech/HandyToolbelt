import Foundation

public typealias JSONObject = [String: JSONValue]
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object(JSONObject)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode(JSONObject.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var objectValue: JSONObject? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public init<T: Encodable>(encoding value: T) throws { self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}
public struct ControlRequest: Codable, Sendable {
    public var id: String
    public var command: String
    public var parameters: JSONObject
    public init(id: String = UUID().uuidString, command: String, parameters: JSONObject = [:]) { self.id = id; self.command = command; self.parameters = parameters }
}
public struct ControlResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: ControlError?
    public static func success(id: String, result: JSONValue) -> Self { Self(id: id, ok: true, result: result, error: nil) }
    public static func failure(id: String, code: String, message: String) -> Self { Self(id: id, ok: false, result: nil, error: ControlError(code: code, message: message)) }
}
public struct ControlError: Error, Codable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
