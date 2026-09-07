import AppKit
import TeleprompterKit

@MainActor final class LocalStore {
    private let folder: URL
    private let draftURL: URL
    private let bookmarkURL: URL
    private var accessedFolder: URL?

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Teleprompter", isDirectory: true)
        draftURL = folder.appendingPathComponent("draft.json")
        bookmarkURL = folder.appendingPathComponent("recording-folder.bookmark")
    }

    func load() throws -> SavedDraft {
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return SavedDraft() }
        let draft = try JSONDecoder().decode(SavedDraft.self, from: Data(contentsOf: draftURL))
        guard draft.version == 1 else { throw TeleprompterError.message("This draft was saved by a newer version. The original file has been preserved.") }
        return draft
    }

    func save(_ draft: SavedDraft) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic)
    }

    func preserveUnreadableDraft() throws {
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return }
        let backup = folder.appendingPathComponent("draft-preserved-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: draftURL, to: backup)
    }

    func restoreFolder() throws -> URL? {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: Data(contentsOf: bookmarkURL), options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else {
            throw TeleprompterError.message("Access to your recording folder expired. Select the folder again.")
        }
        accessedFolder?.stopAccessingSecurityScopedResource(); accessedFolder = url
        if stale { try persistFolder(url) }
        return url
    }

    func chooseFolder() throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for your recordings"
        panel.prompt = "Use this folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = accessedFolder ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        accessedFolder?.stopAccessingSecurityScopedResource(); accessedFolder = url
        try persistFolder(url)
        return url
    }

    private func persistFolder(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: bookmarkURL, options: .atomic)
    }

    func partialTakes(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasSuffix(".partial.mp4") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
