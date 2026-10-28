#!/usr/bin/env swift
// Development-only checks with fake keyboard posting and fake action callbacks.
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let products = root.appendingPathComponent(".build/out/Products/Debug")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HandyToolbelt-stack-checks-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let binary = temporary.appendingPathComponent("checks")
func run(_ executable: String, _ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let sources = ["Sources/HandyToolbeltApp/DebugEventRecorder.swift", "Sources/HandyToolbeltApp/ActionExecutor.swift", "Sources/HandyToolbeltApp/GestureStackRuntime.swift", "Scripts/GestureStackRuntimeChecks.swift"].map { root.appendingPathComponent($0).path }
let result = try run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-I", products.path] + sources + [products.appendingPathComponent("HandyToolbeltCore.o").path, "-o", binary.path])
guard result == 0 else { exit(result) }
exit(try run(binary.path, []))
