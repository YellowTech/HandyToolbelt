import HandyToolbeltControl

enum ControlSchema {
    static func value() throws -> JSONValue { ControlContract.value }
}
