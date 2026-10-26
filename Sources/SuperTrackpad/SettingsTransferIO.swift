import Foundation
import SuperTrackpadCore

/// Only called on a background queue. File coordination lets iCloud Drive and other
/// providers materialize placeholders and serialize edits without blocking AppKit.
struct SettingsTransferIO {
    var backupDirectory: URL = ConfigurationStore().url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    static func encoded(_ config: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        guard data.count <= ConfigurationDocumentDecoder.maximumBytes else { throw TransferError.message("Settings exceed the 1 MiB import limit. Reduce saved content before exporting.") }
        return data
    }
    func read(_ url: URL) throws -> Data {
        try coordinated(url, writing: false) { coordinatedURL in
            let handle = try FileHandle(forReadingFrom: coordinatedURL)
            defer { try? handle.close() }
            // Request at most limit+1, including files whose size changes during a read.
            var data = Data()
            while data.count <= ConfigurationDocumentDecoder.maximumBytes {
                let remaining = ConfigurationDocumentDecoder.maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= ConfigurationDocumentDecoder.maximumBytes else { throw TransferError.message("Settings files must be 1 MiB or smaller.") }
            return data
        }
    }
    func write(_ data: Data, to url: URL) throws {
        try coordinated(url, writing: true) { try data.write(to: $0, options: .atomic) }
    }
    func backup(_ config: AppConfiguration) throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = backupDirectory.appendingPathComponent("HandyToolbelt-settings-\(date)-\(UUID().uuidString).json")
        try write(Self.encoded(config), to: url)
        return url
    }
    private func coordinated<T>(_ url: URL, writing: Bool, body: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { item in result = Result { try body(item) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { item in result = Result { try body(item) } }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw TransferError.message("The file provider did not make this file available. Download it in Finder and try again.") }
        return try result.get()
    }
    enum TransferError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
