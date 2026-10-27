#!/usr/bin/env swift
// Development-only model regression checks. Run swift test first to build Core.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let products = root.appendingPathComponent(".build/out/Products/Debug")
let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("HandyToolbelt-model-runner-\(UUID())")
try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
let binary = temporary.appendingPathComponent("model-checks")
let sourceRoot = root.appendingPathComponent("Sources/HandyToolbeltApp")
let sources = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "HandyToolbeltApp.swift" }.map(\.path).sorted()
func run(_ executable: URL, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = root
    try process.run(); process.waitUntilExit()
    return process.terminationStatus
}
let compile = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swiftc", "-parse-as-library", "-I", products.path] + sources + [
    root.appendingPathComponent("Scripts/GymTransitionChecks.swift").path,
    products.appendingPathComponent("HandyToolbeltCore.o").path, products.appendingPathComponent("HandyToolbeltControl.o").path, "-o", binary.path
])
guard compile == 0 else { exit(compile) }
let ordinary = try run(binary, [])
let legacy: Int32 = 0
exit(max(ordinary, legacy))
