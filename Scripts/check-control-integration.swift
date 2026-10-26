#!/usr/bin/env swift
// Development-only end-to-end checks. Build with swift test first.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let products = root.appendingPathComponent(".build/out/Products/Debug")
let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("SuperTools-control-runner-\(UUID())")
try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
let binary = temporary.appendingPathComponent("control-checks")
let sourceRoot = root.appendingPathComponent("Sources/SuperTrackpad")
let sources = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SuperTrackpadApp.swift" }.map(\.path).sorted()
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = root
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let compile = try run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-I", products.path] + sources + [
    root.appendingPathComponent("Scripts/ControlIntegrationChecks.swift").path,
    products.appendingPathComponent("SuperTrackpadCore.o").path,
    products.appendingPathComponent("SuperToolsControl.o").path, "-o", binary.path
])
guard compile == 0 else { exit(compile) }
exit(try run(binary.path, [products.appendingPathComponent("supertools").path] + CommandLine.arguments.dropFirst()))
