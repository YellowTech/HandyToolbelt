#!/usr/bin/env swift
// Build tooling only. The shipped app never launches subprocesses.
import Foundation
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let bundle = root.appendingPathComponent("dist/HandyToolbelt.app")
let previousBundles = ["SuperTools.app", "SuperTrackpad.app"].map { root.appendingPathComponent("dist/\($0)") }
func requireStoppedApp() {
    for candidate in [bundle] + previousBundles where fm.fileExists(atPath: candidate.path) {
        guard Bundle(url: candidate)?.bundleIdentifier == "local.SuperTrackpad" else {
            fatalError("Refusing to replace an unrelated bundle at \(candidate.path). Move it aside explicitly before building.")
        }
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.SuperTrackpad")
    let managedPaths = ([bundle] + previousBundles).map { $0.resolvingSymlinksInPath() }
    guard !running.contains(where: { app in app.bundleURL.map { managedPaths.contains($0.resolvingSymlinksInPath()) } ?? false }) else {
        fatalError("Quit HandyToolbelt (including any older repository copy) from its menu bar before building. Replacing a running app can leave macOS checking the old code signature.")
    }
}
func capture(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
    let output = Pipe(); task.standardOutput = output
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { fatalError("Could not inspect available signing identities.") }
    return String(decoding: data, as: UTF8.self)
}
// A normal certificate keeps the designated requirement stable across changed binaries.
// Pin the first selected identity locally; never silently switch teams or fall back to ad-hoc.
let identityFile = root.appendingPathComponent(".local-signing-identity")
let override = ProcessInfo.processInfo.environment["SUPERTRACKPAD_SIGN_IDENTITY"]
let identity: String
if let override, !override.isEmpty { identity = override }
else if fm.fileExists(atPath: identityFile.path) {
    identity = try String(contentsOf: identityFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identity.isEmpty else { fatalError("The local signing identity is empty. Set SUPERTRACKPAD_SIGN_IDENTITY explicitly.") }
} else {
    let available = try capture("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
    let pattern = #"\b([A-Fa-f0-9]{40})\s+\"(?:Apple Development|Mac Developer):[^\"]+\""#
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: available, range: NSRange(available.startIndex..., in: available))
    guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: available) else {
        fatalError("Choose a stable code-signing identity with SUPERTRACKPAD_SIGN_IDENTITY. Found \(matches.count) development identities. Use '-' explicitly only for disposable ad-hoc builds; their permissions may break on rebuild.")
    }
    identity = String(available[range])
}
requireStoppedApp()
func run(_ executable: String, _ arguments: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.currentDirectoryURL = root
    try task.run(); task.waitUntilExit()
    if task.terminationStatus != 0 { exit(task.terminationStatus) }
}
try run("/usr/bin/xcrun", ["swift", "Scripts/verify.swift"])
try run("/usr/bin/xcrun", ["swift", "build", "-c", "release"])
let pathQuery = Process()
pathQuery.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
pathQuery.arguments = ["swift", "build", "-c", "release", "--show-bin-path"]
pathQuery.currentDirectoryURL = root
let pathOutput = Pipe(); pathQuery.standardOutput = pathOutput
try pathQuery.run()
let pathData = pathOutput.fileHandleForReading.readDataToEndOfFile()
pathQuery.waitUntilExit()
guard pathQuery.terminationStatus == 0, let path = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
    fatalError("Could not locate the compiled app")
}
requireStoppedApp()
if !fm.fileExists(atPath: bundle.path), let previousBundle = previousBundles.first(where: { fm.fileExists(atPath: $0.path) }) {
    try fm.moveItem(at: previousBundle, to: bundle)
}
let contents = bundle.appendingPathComponent("Contents")
try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
func replace(_ source: URL, _ target: URL) throws {
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    try fm.copyItem(at: source, to: target)
}
try replace(URL(fileURLWithPath: path).appendingPathComponent("SuperTrackpad"), contents.appendingPathComponent("MacOS/SuperTrackpad"))
try replace(URL(fileURLWithPath: path).appendingPathComponent("supertools"), contents.appendingPathComponent("MacOS/handytoolbelt"))
let legacyCLI = contents.appendingPathComponent("MacOS/supertools")
if (try? fm.attributesOfItem(atPath: legacyCLI.path)) != nil { try fm.removeItem(at: legacyCLI) }
try fm.createSymbolicLink(atPath: legacyCLI.path, withDestinationPath: "handytoolbelt")
try replace(root.appendingPathComponent("Resources/Info.plist"), contents.appendingPathComponent("Info.plist"))

// The same PDF backs the menu-bar template and every app icon resolution.
try replace(root.appendingPathComponent("Sources/SuperTrackpad/Resources/Toolbelt.pdf"), contents.appendingPathComponent("Resources/Toolbelt.pdf"))
try run("/usr/bin/xcrun", ["swift", "Scripts/render-icon.swift", contents.appendingPathComponent("Resources/AppIcon.icns").path])
try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", contents.appendingPathComponent("MacOS/handytoolbelt").path])
try run("/usr/bin/codesign", ["--verify", "--strict", contents.appendingPathComponent("MacOS/handytoolbelt").path])
try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", bundle.path])
try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
if identity != "-" { try identity.write(to: identityFile, atomically: true, encoding: .utf8) }
else { print("Warning: ad-hoc signing changes the app identity on rebuild and can invalidate Accessibility access.") }
print("Built \(bundle.path)")
