import AppKit
import HandyToolbeltCore
import HandyToolbeltControl

@main struct SettingsTransferChecks {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1; precondition(value, message)
    }
    static func rejects(_ body: () throws -> Void, _ message: String) {
        do { try body(); fatalError(message) } catch { checks += 1 }
    }
    static func same(_ lhs: AppConfiguration?, _ rhs: AppConfiguration) -> Bool {
        guard let lhs else { return false }; return (try? lhs.revision()) == (try? rhs.revision())
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Transfer-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = SettingsTransferIO(backupDirectory: directory.appendingPathComponent("Backups"))
        let inputURL = directory.appendingPathComponent("settings.json")
        var fixture = AppConfiguration()
        fixture.bindings = [GestureBinding(gesture: .init(kind: .doubleTap, fingers: 3), action: .init(kind: .appleScript, script: "error \"must never execute\""))]
        fixture.stacks = [GestureStack(name: "Disabled draft", isEnabled: false)]
        let data = try SettingsTransferIO.encoded(fixture)
        check(try same(ConfigurationDocumentDecoder.validated(data), fixture), "Roundtrip preserves temporal gestures and stacks")
        for version in 1...6 {
            let legacy = Data("{\"version\":\(version),\"bindings\":[]\(version < 4 ? ",\"isEnabled\":true" : "")}".utf8)
            check(try ConfigurationDocumentDecoder.validated(legacy).version == 6, "Legacy migration")
        }
        rejects({ _ = try ConfigurationDocumentDecoder.validated(Data("{\"version\":99,\"bindings\":[]}".utf8)) }, "Future version")
        rejects({ _ = try ConfigurationDocumentDecoder.validated(Data("{\"version\":6,\"bindings\":[],\"surprise\":true}".utf8)) }, "Unknown field")
        rejects({ _ = try ConfigurationDocumentDecoder.validated(Data("{bad".utf8)) }, "Malformed JSON")
        var invalid = fixture
        invalid.bindings[0].action.script = ""
        rejects({ _ = try ConfigurationDocumentDecoder.validated(SettingsTransferIO.encoded(invalid)) }, "Semantically invalid enabled action")
        rejects({ _ = try ConfigurationDocumentDecoder.validated(Data(repeating: 0, count: 1_048_577)) }, "Oversize data")
        try Data(repeating: 0, count: 1_048_577).write(to: inputURL)
        rejects({ _ = try io.read(inputURL) }, "Bounded oversized file read")
        rejects({ _ = try io.read(directory.appendingPathComponent("missing")) }, "Missing file")
        try io.write(data, to: inputURL)
        check(try io.read(inputURL) == data, "Coordinated I/O roundtrip")

        var current = AppConfiguration(), calls = 0, backedUp: AppConfiguration?
        var blocked = false, permitted = true, failBackup = false, failSave = false
        var jobs: [() -> Void] = [], callbacks: [() -> Void] = []
        let backupURL = directory.appendingPathComponent("old.json")
        let model = SettingsTransferModel(current: { current }, gate: {
            if blocked { throw SettingsTransferIO.TransferError.message("Finish current work") }
        }, authorize: { _ in if !permitted { throw SettingsTransferIO.TransferError.message("Review Accessibility") } }, apply: { config, revision in
            check(try current.revision() == revision, "Apply revision")
            if failSave { throw SettingsTransferIO.TransferError.message("Save failed") }
            current = config; calls += 1
        }, read: { _ in data }, backup: { old in
            if failBackup { throw SettingsTransferIO.TransferError.message("Backup failed") }
            backedUp = old; try SettingsTransferIO.encoded(old).write(to: backupURL); return backupURL
        }, work: { jobs.append($0) }, deliver: { callbacks.append($0) })
        func finish() { jobs.removeFirst()(); callbacks.removeFirst()() }
        func prepare() { model.prepareImport(from: inputURL); finish(); check(model.review != nil, "Prepared review") }
        model.prepareImport(from: inputURL); model.cancel(); finish()
        check(model.review == nil && calls == 0, "Canceled read cannot review or apply")
        model.prepareImport(from: inputURL); current.coffeeModuleEnabled.toggle(); finish()
        check(model.review == nil && model.isError, "Stale read rejected")
        prepare(); current.coffeeModuleEnabled.toggle(); model.replaceReviewedSettings()
        check(model.review == nil && calls == 0 && jobs.isEmpty, "Stale review rejected")
        prepare(); model.replaceReviewedSettings(); current.coffeeModuleEnabled.toggle(); finish()
        check(calls == 0 && model.isError, "Revision race during backup rejected")
        prepare(); model.replaceReviewedSettings(); model.cancel(); finish()
        check(calls == 0, "Canceled commit cannot apply")
        prepare(); blocked = true; model.replaceReviewedSettings(); blocked = false
        check(calls == 0 && jobs.isEmpty, "Active runtime work blocks commit")
        blocked = true; model.prepareImport(from: inputURL); blocked = false
        check(jobs.isEmpty && model.review == nil, "Active runtime work blocks read")
        prepare(); model.replaceReviewedSettings(); blocked = true; finish(); blocked = false
        check(calls == 0, "Runtime gate checked after backup")
        prepare(); permitted = false; model.replaceReviewedSettings(); permitted = true
        check(calls == 0 && jobs.isEmpty, "Permissions cannot be bypassed")
        prepare(); model.replaceReviewedSettings(); permitted = false; finish(); permitted = true
        check(calls == 0, "Permissions rechecked after backup")
        prepare(); failBackup = true; model.replaceReviewedSettings(); finish(); failBackup = false
        check(calls == 0 && model.isError, "Failed backup prevents apply")
        prepare(); failSave = true; model.replaceReviewedSettings(); finish(); failSave = false
        check(calls == 0 && model.isError, "Failed save prevents publication")
        let old = current
        prepare(); model.replaceReviewedSettings(); finish()
        check(calls == 1 && same(current, fixture) && same(backedUp, old), "Confirmed import replaces once with old-settings backup")
        check(try same(ConfigurationDocumentDecoder.validated(Data(contentsOf: backupURL)), old), "Durable backup contains prior settings")
        check(model.backupURL == backupURL && model.review == nil, "Successful import reveals backup")
        // No execution closure exists in the transfer model; AppleScript survives as data.
        check(current.bindings.first?.action.script.contains("must never execute") == true, "Imported script remains inert data")
        let actualBackup = try io.backup(old)
        check(try same(ConfigurationDocumentDecoder.validated(io.read(actualBackup)), old), "Timestamped local backup is reimportable")
        var writeCalls = 0
        let exporting = SettingsTransferModel(current: { current }, gate: {}, authorize: { _ in }, apply: { _, _ in fatalError("Export must never apply") },
            write: { bytes, _ in writeCalls += 1; check(try same(ConfigurationDocumentDecoder.validated(bytes), current), "Export captures saved configuration") },
            work: { jobs.append($0) }, deliver: { callbacks.append($0) })
        exporting.export(to: inputURL); finish()
        check(writeCalls == 1 && !exporting.isError, "Export succeeds without mutation")
        exporting.export(to: inputURL); exporting.cancelIfActive(); finish()
        check(exporting.status.hasPrefix("Canceled"), "Stopped export cannot overwrite canceled status")
        let failingExport = SettingsTransferModel(current: { current }, gate: {}, authorize: { _ in }, apply: { _, _ in fatalError("No apply") },
            write: { _, _ in throw SettingsTransferIO.TransferError.message("Disk full") }, work: { jobs.append($0) }, deliver: { callbacks.append($0) })
        failingExport.export(to: inputURL); finish()
        check(failingExport.isError && failingExport.status.contains("Disk full"), "Export write errors are actionable")
        let unreadable = SettingsTransferModel(current: { throw SettingsTransferIO.TransferError.message("Recover unreadable settings") }, gate: {}, authorize: { _ in }, apply: { _, _ in fatalError("No apply") },
            work: { jobs.append($0) }, deliver: { callbacks.append($0) })
        unreadable.export(to: inputURL); unreadable.prepareImport(from: inputURL)
        check(unreadable.isError && jobs.isEmpty, "Unreadable current settings cannot export fallback or import")
        var disabled = AppConfiguration(); disabled.trackpadModuleEnabled = false; disabled.windowSwitcher.isEnabled = false
        var enabling = disabled; enabling.trackpadModuleEnabled = true
        rejects({ try ModulePermissionPolicy.validateTransition(from: disabled, to: enabling, hasAccessibility: false) }, "Missing Accessibility blocks new enabling")
        try ModulePermissionPolicy.validateTransition(from: enabling, to: disabled, hasAccessibility: false)
        check(true, "Disabling remains permitted")
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let brokenIO = SettingsTransferIO(backupDirectory: blocker.appendingPathComponent("Backups"))
        rejects({ _ = try brokenIO.backup(old) }, "Real backup directory failure")
        print("Settings transfer: \(checks) checks passed")
    }
}
