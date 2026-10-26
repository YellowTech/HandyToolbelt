import AppKit
import Combine
import UniformTypeIdentifiers
import SuperTrackpadCore
import SuperToolsControl

struct SettingsImportReview: Identifiable {
    let id = UUID()
    let filename: String
    let configuration: AppConfiguration
    let revision: String
    let warnings: [String]
    let contents: String
}

/// Main-thread owned state. Injected jobs perform all provider I/O off the main thread.
final class SettingsTransferModel: ObservableObject {
    typealias Work = (@escaping () -> Void) -> Void
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var isError = false
    @Published private(set) var review: SettingsImportReview?
    @Published private(set) var backupURL: URL?
    private var generation = UUID()
    private var panel: NSSavePanel?
    private let current: () throws -> AppConfiguration
    private let gate: () throws -> Void
    private let authorize: (AppConfiguration) throws -> Void
    private let apply: (AppConfiguration, String) throws -> Void
    private let read: (URL) throws -> Data
    private let write: (Data, URL) throws -> Void
    private let backup: (AppConfiguration) throws -> URL
    private let work: Work
    private let deliver: Work
    init(current: @escaping () throws -> AppConfiguration, gate: @escaping () throws -> Void,
         authorize: @escaping (AppConfiguration) throws -> Void, apply: @escaping (AppConfiguration, String) throws -> Void,
         io: SettingsTransferIO = .init(), read: ((URL) throws -> Data)? = nil,
         write: ((Data, URL) throws -> Void)? = nil, backup: ((AppConfiguration) throws -> URL)? = nil,
         work: @escaping Work = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         deliver: @escaping Work = { DispatchQueue.main.async(execute: $0) }) {
        self.current = current; self.gate = gate; self.authorize = authorize; self.apply = apply
        self.read = read ?? io.read; self.write = write ?? { try io.write($0, to: $1) }; self.backup = backup ?? io.backup
        self.work = work; self.deliver = deliver
    }
    func chooseExport() {
        guard !busy, review == nil else { return }
        do { _ = try current() } catch { fail(error); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "HandyToolbelt-settings.json"
        panel.title = "Export Settings"; panel.prompt = "Export"
        present(panel, importing: false)
    }
    func chooseImport() {
        guard !busy, review == nil else { return }
        do { try gate(); _ = try current() } catch { fail(error); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canDownloadUbiquitousContents = true
        panel.title = "Import Settings"; panel.prompt = "Review Settings"
        present(panel, importing: true)
    }
    private func present(_ panel: NSSavePanel, importing: Bool) {
        let token = begin(importing ? "Choose a settings file…" : "Choose where to save settings…")
        self.panel = panel
        panel.begin { [weak self, weak panel] response in
            guard let self, self.generation == token else { return }
            let selectedURL = panel?.url
            self.panel = nil; self.busy = false
            guard response == .OK, let url = selectedURL else { self.cancel(); return }
            if importing { self.prepareImport(from: url) } else { self.export(to: url) }
        }
    }
    func export(to url: URL) {
        guard !busy else { return }
        do {
            let saved = try current()
            let token = begin("Saving settings file…")
            work { [self] in
                let result = Result { try write(SettingsTransferIO.encoded(saved), url) }
                deliver { [self] in
                    guard generation == token else { return }
                    busy = false
                    switch result {
                    case .success: status = "Settings file saved. iCloud Drive manages any upload."
                    case let .failure(error): fail(error)
                    }
                }
            }
        } catch { fail(error) }
    }
    func prepareImport(from url: URL) {
        guard !busy else { return }
        do {
            try gate()
            let revision = try current().revision()
            let token = begin("Reading settings file…")
            work { [self] in
                let result = Result { try ConfigurationDocumentDecoder.validated(read(url)) }
                deliver { [self] in
                    guard generation == token else { return }
                    busy = false
                    do {
                        let config = try result.get()
                        try gate(); try checkRevision(revision)
                        review = SettingsImportReview(filename: url.lastPathComponent, configuration: config, revision: revision,
                            warnings: config.validation().warnings,
                            contents: String(decoding: try SettingsTransferIO.encoded(config), as: UTF8.self))
                        status = "Review the file before replacing your settings."
                    } catch { fail(error) }
                }
            }
        } catch { fail(error) }
    }
    func replaceReviewedSettings() {
        guard !busy, let pending = review else { return }
        do {
            try gate(); try checkRevision(pending.revision); try authorize(pending.configuration)
            let old = try current()
            let token = begin("Backing up current settings…", retainingReview: true)
            work { [self] in
                let result = Result { try backup(old) }
                deliver { [self] in
                    guard generation == token else { return }
                    busy = false
                    do {
                        let url = try result.get()
                        // A provider may take seconds. Recheck every condition immediately before apply.
                        try gate(); try checkRevision(pending.revision); try authorize(pending.configuration)
                        try apply(pending.configuration, pending.revision)
                        backupURL = url; review = nil
                        status = "Settings replaced. Your previous settings were backed up locally."
                    } catch { review = nil; fail(error) }
                }
            }
        } catch { review = nil; fail(error) }
    }
    func cancel() {
        generation = UUID()
        let closingPanel = panel; panel = nil
        closingPanel?.cancel(nil); closingPanel?.orderOut(nil)
        busy = false; review = nil; isError = false
        status = "Canceled. Settings were not replaced."
    }
    func cancelIfActive() { if busy || review != nil { cancel() } }
    func revealBackup() { if let backupURL { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) } }
    private func begin(_ text: String, retainingReview: Bool = false) -> UUID {
        generation = UUID(); busy = true; status = text; isError = false
        if !retainingReview { review = nil }
        return generation
    }
    private func checkRevision(_ expected: String) throws {
        guard try current().revision() == expected else {
            throw SettingsTransferIO.TransferError.message("Settings changed since this import was opened. Import the file again to review it against your current settings.")
        }
    }
    private func fail(_ error: Error) {
        busy = false; isError = true
        let message = (error as? ControlError)?.message ?? error.localizedDescription
        status = message + " No settings were replaced."
    }
}
