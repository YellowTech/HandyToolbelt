#!/usr/bin/env swift
// Focused AppKit/SwiftUI checks; briefly orders a native test window without activating it.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let products = root.appendingPathComponent(".build/out/Products/Debug")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HandyToolbelt-presence-\(UUID())")
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
    root.appendingPathComponent("Sources/HandyToolbeltApp/Host/MainWindowPresence.swift").path,
    root.appendingPathComponent("Sources/HandyToolbeltApp/WorkspaceHostingSurface.swift").path,
    root.appendingPathComponent("Scripts/MainWindowPresenceChecks.swift").path,
    products.appendingPathComponent("HandyToolbeltCore.o").path, "-o", binary])
guard result == 0 else { exit(result) }
let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
