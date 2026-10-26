#!/usr/bin/env swift
// Development-only verification. All stages are sequential to avoid SwiftPM product races.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
func run(_ arguments: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    task.arguments = ["swift"] + arguments
    task.currentDirectoryURL = root
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
}
if CommandLine.arguments.dropFirst().elementsEqual(["--generate-docs"]) {
    try run(["build"])
    try run(["Scripts/check-control-integration.swift", "--generate-docs"])
} else {
    guard CommandLine.arguments.count == 1 else { fatalError("Usage: Scripts/verify.swift [--generate-docs]") }
    try run(["test"])
    try run(["Scripts/check-model-navigation.swift"])
    try run(["Scripts/check-main-window-presence.swift"])
    try run(["Scripts/check-window-activation.swift"])
    try run(["Scripts/check-window-switcher-flow.swift"])
    try run(["Scripts/check-window-snap-pipeline.swift"])
    try run(["Scripts/check-gesture-performance.swift"])
    try run(["Scripts/check-gym-transition.swift"])
    try run(["Scripts/check-control-integration.swift"])
    try run(["Scripts/check-gesture-stack-runtime.swift"])
    try run(["Scripts/check-force-click-model.swift"])
    try run(["Scripts/check-temporal-gesture-model.swift"])
    try run(["Scripts/check-settings-transfer.swift"])
    let loginCheck = Process()
    loginCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
    loginCheck.arguments = [root.appendingPathComponent("Scripts/check-login-item-model.sh").path]
    try loginCheck.run(); loginCheck.waitUntilExit()
    guard loginCheck.terminationStatus == 0 else { exit(loginCheck.terminationStatus) }
}
