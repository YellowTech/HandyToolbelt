#!/usr/bin/env swift
// Exercises production event capture, worker scheduling, generation guards, and commit with fake native boundaries.
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HandyToolbelt-snap-pipeline-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
let products = root.appendingPathComponent(".build/out/Products/Debug")
let binary = temporary.appendingPathComponent("snap-pipeline-checks").path
try run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-I", products.path,
    products.appendingPathComponent("HandyToolbeltCore.o").path,
    root.appendingPathComponent("Sources/HandyToolbeltApp/DebugEventRecorder.swift").path,
    root.appendingPathComponent("Sources/HandyToolbeltApp/Windows/WindowSnapMonitor.swift").path,
    root.appendingPathComponent("Scripts/WindowSnapPipelineChecks.swift").path, "-o", binary])
try run(binary, [])
