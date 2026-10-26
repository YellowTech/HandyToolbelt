#!/usr/bin/env swift
// Production orchestration integration checks with injected native boundaries; no real activation or AX calls.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SuperTools-activation-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let binary = temporary.appendingPathComponent("activation-checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-parse-as-library",
    root.appendingPathComponent("Sources/SuperTrackpad/Windows/WindowActivationVerification.swift").path,
    root.appendingPathComponent("Sources/SuperTrackpad/Windows/WindowActivationCoordinator.swift").path,
    root.appendingPathComponent("Scripts/WindowActivationChecks.swift").path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let check = Process(); check.executableURL = binary
try check.run(); check.waitUntilExit(); exit(check.terminationStatus)
