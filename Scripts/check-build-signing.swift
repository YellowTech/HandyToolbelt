#!/usr/bin/env swift
// Compile the production policy in isolation. Never query Keychain or touch the app/pin.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Scripts/build.swift"), encoding: .utf8)
let start = source.range(of: "// BEGIN SIGNING POLICY")!.lowerBound
let end = source.range(of: "// END SIGNING POLICY")!.upperBound
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("build-signing-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let checks = #"""
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
if CommandLine.arguments.count > 1 {
    let error: Error = CommandLine.arguments[1] == "unexpected"
        ? NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture I/O failure"])
        : BuildFailure("fixture selection failure")
    exit(reportBuildFailure(error))
}
let hash = String(repeating: "A", count: 40)
let one = "  1) \(hash) \"Apple Development: Fixture (TEAM)\"\n"
let two = one + "  2) \(String(repeating: "B", count: 40)) \"Mac Developer: Other (TEAM)\"\n"
func select(_ override: String? = nil, _ pin: String? = nil, _ existing: Bool = false,
            _ output: String = "0 valid identities found") throws -> SigningSelection {
    try selectSigningIdentity(override: override, pin: pin, pinExists: pin != nil, hasExistingApp: existing, available: { output })
}
func rejects(_ body: () throws -> SigningSelection, containing text: String) {
    do { _ = try body(); fatalError("Expected rejection") }
    catch { expect(String(describing: error).contains(text), "Wrong rejection: \(error)") }
}
let fresh = try select()
expect(fresh.identity == "-" && fresh.persist, "Fresh checkout must pin ad-hoc after success")
let cert = try select(nil, nil, false, one)
expect(cert.identity == hash && cert.persist, "Sole development identity must be pinned")
rejects({ try select(nil, nil, false, two) }, containing: "Found 2")
rejects({ try select(nil, nil, true) }, containing: "repository app already exists")
rejects({ try select(nil, " \n") }, containing: "empty")
for pin in [hash, "-", "missing identity"] {
    let selected = try selectSigningIdentity(override: nil, pin: " \(pin)\n", pinExists: true, hasExistingApp: true,
                                            available: { fatalError("Must not query identities for a pin") })
    expect(selected.identity == pin && !selected.persist, "Pins must win without discovery/fallback")
}
let disposable = try select("-", hash, true, two)
expect(disposable.identity == "-" && !disposable.persist, "Disposable override must preserve certificate pin")
let freshExplicit = try select("-")
expect(freshExplicit.identity == "-" && freshExplicit.persist, "Fresh explicit ad-hoc builds must pin for rebuilds")
let unreadablePinOverride = try selectSigningIdentity(override: "-", pin: nil, pinExists: true,
    hasExistingApp: true, available: { fatalError("Override must skip discovery") })
expect(!unreadablePinOverride.persist, "Explicit ad-hoc override must preserve even an unreadable pin")
let explicit = try select("chosen identity", "", true, two)
expect(explicit.identity == "chosen identity" && explicit.persist, "Explicit certificate must win and pin")
let emptyOverride = try select("", nil, false, one)
expect(emptyOverride.identity == hash, "Empty override keeps automatic selection")
print("Build signing policy checks passed")
"""#
let testSource = "import Foundation\n" + source[start..<end] + "\n" + checks
let fixture = temporary.appendingPathComponent("main.swift")
try testSource.write(to: fixture, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("checks")
func run(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    if capture { process.standardError = output; process.standardOutput = output }
    try process.run()
    let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
let compile = try run("/usr/bin/xcrun", ["swiftc", fixture.path, "-o", binary.path])
guard compile.0 == 0 else { exit(compile.0) }
let result = try run(binary.path, [])
guard result.0 == 0 else { exit(result.0) }
for mode in ["expected", "unexpected"] {
    let error = try run(binary.path, [mode], capture: true)
    guard error.0 == 1, error.1.hasPrefix("Build failed: fixture "),
          error.1.split(separator: "\n").count == 1,
          !error.1.contains("Stack dump"), !error.1.contains("Fatal error") else {
        FileHandle.standardError.write(Data("Invalid error output: \(error)\n".utf8)); exit(1)
    }
}
print("Build error output checks passed")
