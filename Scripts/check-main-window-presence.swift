#!/usr/bin/env swift
// Focused AppKit checks with injected native operations; does not change Dock policy or show windows.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let products = root.appendingPathComponent(".build/out/Products/Debug")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SuperTools-presence-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
func run(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    try process.run(); process.waitUntilExit()
    return process.terminationStatus
}
let binary = temporary.appendingPathComponent("presence-checks").path
let result = try run(["swiftc", "-parse-as-library", "-I", products.path,
    root.appendingPathComponent("Sources/SuperTrackpad/Host/MainWindowPresence.swift").path,
    root.appendingPathComponent("Scripts/MainWindowPresenceChecks.swift").path,
    products.appendingPathComponent("SuperTrackpadCore.o").path, "-o", binary])
guard result == 0 else { exit(result) }
let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
