import Foundation
import HandyToolbeltCore

struct ConfigurationStore {
    let url: URL
    // Recovery-only fault injection keeps normal persistence behavior unchanged.
    private let recoverySave: ((AppConfiguration) throws -> Void)?
    init(url: URL? = nil, recoverySave: ((AppConfiguration) throws -> Void)? = nil) {
        self.recoverySave = recoverySave
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HandyToolbelt/settings.json")
    }
    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
        guard config.version == 7 else { throw StorageError.unsupportedVersion }
        return config
    }
    func save(_ config: AppConfiguration) throws {
        try save(config, preservingLegacy: true)
    }
    private func save(_ config: AppConfiguration, preservingLegacy: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let files = FileManager.default
        let legacyBackup = url.appendingPathExtension("pre-v7")
        if preservingLegacy, !files.fileExists(atPath: legacyBackup.path), files.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            if let header = try? JSONDecoder().decode(VersionHeader.self, from: previous), (1...6).contains(header.version) {
                do { try previous.write(to: legacyBackup, options: .withoutOverwriting) }
                catch CocoaError.fileWriteFileExists {}
            }
        }
        try data.write(to: url, options: .atomic)
    }
    func preserveUnreadableFile() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backup)
        }
    }
    /// Preserve the original before atomically replacing it. Failed writes leave
    /// the original path readable and allow the caller to retain recovery state.
    func recover(with config: AppConfiguration) throws {
        try preserveUnreadableFile()
        if let recoverySave { try recoverySave(config) }
        else { try save(config, preservingLegacy: false) }
    }
    private struct VersionHeader: Decodable {
        var version: Int
    }

    enum StorageError: LocalizedError {
        case unsupportedVersion
        var errorDescription: String? { "These settings were created by a newer app version." }
    }
}
