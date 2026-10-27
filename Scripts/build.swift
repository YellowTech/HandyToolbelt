#!/usr/bin/env swift
// Build tooling only. The shipped app never launches subprocesses.
import Foundation
import AppKit

// BEGIN SIGNING POLICY (also exercised by check-build-signing.swift)
struct BuildFailure: Error, CustomStringConvertible {
    let description: String
    let status: Int32
    init(_ description: String, status: Int32 = 1) {
        self.description = description
        self.status = status
    }
}
func reportBuildFailure(_ error: Error) -> Int32 {
    let message = (error as? BuildFailure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("Build failed: \(message)\n".utf8))
    return (error as? BuildFailure)?.status ?? 1
}
struct SigningSelection {
    let identity: String
    let persist: Bool
}
func selectSigningIdentity(override: String?, pin: String?, pinExists: Bool, hasExistingApp: Bool,
                           available: () throws -> String) throws -> SigningSelection {
    if let override, !override.isEmpty {
        // Preserve existing pins for disposable ad-hoc overrides; pin fresh ones for rebuilds.
        return SigningSelection(identity: override, persist: override != "-" || !pinExists)
    }
    if let pin {
        let identity = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else {
            throw BuildFailure("The local signing identity is empty. Set HANDYTOOLBELT_SIGN_IDENTITY explicitly.")
        }
        return SigningSelection(identity: identity, persist: false)
    }
    let output = try available()
    let regex = try NSRegularExpression(pattern: #"\b([A-Fa-f0-9]{40})\s+"(?:Apple Development|Mac Developer):[^"]+""#)
    let identities = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
        Range($0.range(at: 1), in: output).map { String(output[$0]) }
    }
    if identities.count == 1 {
        return SigningSelection(identity: identities[0], persist: true)
    }
    guard identities.isEmpty else {
        throw BuildFailure("Found \(identities.count) development identities. Choose one with HANDYTOOLBELT_SIGN_IDENTITY='YOUR_SIGNING_IDENTITY' swift Scripts/build.swift.")
    }
    guard !hasExistingApp else {
        throw BuildFailure("No development signing identity found and a repository app already exists. Set HANDYTOOLBELT_SIGN_IDENTITY to its signing identity, or explicitly use '-' for an ad-hoc build that may require granting macOS permissions again.")
    }
    return SigningSelection(identity: "-", persist: true)
}
// END SIGNING POLICY

func build() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    let bundle = root.appendingPathComponent("dist/HandyToolbelt.app")
    func requireStoppedApp() throws {
        if fm.fileExists(atPath: bundle.path) {
            let installed = Bundle(url: bundle)
            // Early builds used a different identifier but already had this product name.
            let matchesProduct = installed?.object(forInfoDictionaryKey: "CFBundleName") as? String == "HandyToolbelt"
                && installed?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
            guard installed?.bundleIdentifier == "local.HandyToolbelt" || matchesProduct else {
                throw BuildFailure("Refusing to replace an unrelated bundle at \(bundle.path). Move it aside explicitly before building.")
            }
        }
        // Match the installed path so this also catches an early build's running process.
        let managedPath = bundle.resolvingSymlinksInPath()
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.resolvingSymlinksInPath() == managedPath
        }) else {
            throw BuildFailure("Quit HandyToolbelt (including any older repository copy) from its menu bar before building. Replacing a running app can leave macOS checking the old code signature.")
        }
    }
    func capture(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let output = Pipe(); task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw BuildFailure("Could not inspect available signing identities.") }
        return String(decoding: data, as: UTF8.self)
    }
    // Keep the chosen identity stable across builds, including automatic ad-hoc signing.
    let identityFile = root.appendingPathComponent(".local-signing-identity")
    let override = ProcessInfo.processInfo.environment["HANDYTOOLBELT_SIGN_IDENTITY"]
    let pinExists = fm.fileExists(atPath: identityFile.path)
    let pin = (override?.isEmpty ?? true) && pinExists
        ? try String(contentsOf: identityFile, encoding: .utf8) : nil
    let selection = try selectSigningIdentity(
        override: override,
        pin: pin,
        pinExists: pinExists,
        hasExistingApp: fm.fileExists(atPath: bundle.path),
        available: { try capture("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) })
    let identity = selection.identity
    if identity == "-" {
        FileHandle.standardError.write(Data("Warning: ad-hoc signing; macOS privacy permissions may need to be granted again after rebuilding.\n".utf8))
    }
    try requireStoppedApp()
    func run(_ executable: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = root
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw BuildFailure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (exit \(task.terminationStatus)). See the command output above.", status: task.terminationStatus > 0 ? task.terminationStatus : 1)
        }
    }
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
        throw BuildFailure("Could not locate the compiled app")
    }
    try requireStoppedApp()
    let contents = bundle.appendingPathComponent("Contents")
    let previousExecutable = Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
    if let previousExecutable {
        guard !previousExecutable.isEmpty, ![".", ".."].contains(previousExecutable),
              !previousExecutable.contains("/"), !previousExecutable.contains("\\") else {
            throw BuildFailure("The installed app has an invalid executable name. Move it aside before rebuilding.")
        }
    }
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    func replace(_ source: URL, _ target: URL) throws {
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
    }
    try replace(URL(fileURLWithPath: path).appendingPathComponent("HandyToolbeltApp"), contents.appendingPathComponent("MacOS/HandyToolbeltApp"))
    try replace(URL(fileURLWithPath: path).appendingPathComponent("handytoolbelt"), contents.appendingPathComponent("MacOS/handytoolbelt"))
    if let previousExecutable, !["handytoolbeltapp", "handytoolbelt"].contains(previousExecutable.lowercased()) {
        let obsolete = contents.appendingPathComponent("MacOS/\(previousExecutable)")
        if (try? fm.attributesOfItem(atPath: obsolete.path)) != nil { try fm.removeItem(at: obsolete) }
    }
    // Remove obsolete CLI aliases without following or removing their targets.
    for entry in try fm.contentsOfDirectory(at: contents.appendingPathComponent("MacOS"), includingPropertiesForKeys: nil)
        where entry.lastPathComponent != "handytoolbelt" {
        if (try? fm.destinationOfSymbolicLink(atPath: entry.path)) == "handytoolbelt" {
            try fm.removeItem(at: entry)
        }
    }
    try replace(root.appendingPathComponent("Resources/Info.plist"), contents.appendingPathComponent("Info.plist"))

    // The same PDF backs the menu-bar template and every app icon resolution.
    try replace(root.appendingPathComponent("Sources/HandyToolbeltApp/Resources/Toolbelt.pdf"), contents.appendingPathComponent("Resources/Toolbelt.pdf"))
    try run("/usr/bin/xcrun", ["swift", "Scripts/render-icon.swift", contents.appendingPathComponent("Resources/AppIcon.icns").path])
    try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", contents.appendingPathComponent("MacOS/handytoolbelt").path])
    try run("/usr/bin/codesign", ["--verify", "--strict", contents.appendingPathComponent("MacOS/handytoolbelt").path])
    try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", bundle.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
    if selection.persist { try identity.write(to: identityFile, atomically: true, encoding: .utf8) }
    print("Built \(bundle.path)")
}

do {
    try build()
} catch {
    exit(reportBuildFailure(error))
}
