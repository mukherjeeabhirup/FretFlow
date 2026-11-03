import AppKit
import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published var songs: [LibrarySong] = []
    @Published var error: String?
    @Published var videoLinks: [String: String] = [:]
    private let folder: URL
    private let persistenceEnabled: Bool
    private let defaults: UserDefaults
    private var imported: [LibrarySong] = []
    private var bundledIDs: Set<String> = []
    private var libraryReadFailed = false
    var bookURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Library/Plini - An Unnameable Desire.pdf")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    init(folder: URL? = nil, defaults: UserDefaults = .standard,
         persistenceEnabled: Bool? = nil, loadBundledResources: Bool = true) {
        let enabled = persistenceEnabled ?? !ProcessInfo.processInfo.arguments.contains("--smoke-test")
        self.persistenceEnabled = enabled
        self.defaults = defaults
        self.folder = folder ?? (enabled
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FretFlow", isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("FretFlow-" + UUID().uuidString, isDirectory: true))
        if loadBundledResources, let url = Bundle.main.resourceURL?.appendingPathComponent("Library/library.json"),
           let data = try? Data(contentsOf: url),
           let seeded = try? JSONDecoder().decode([LibrarySong].self, from: data) {
            // Personal scores are optional resources and are not distributed
            // with the source repository. Keep a fresh checkout's library usable.
            songs = seeded.filter { song in
                FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
                    .appendingPathComponent(song.filename).path)
            }
            bundledIDs = Set(songs.map(\.id))
        }
        if loadBundledResources, let url = Bundle.main.resourceURL?.appendingPathComponent("Library/videos.json"),
           let data = try? Data(contentsOf: url),
           let seeded = try? JSONDecoder().decode([String: String].self, from: data) { videoLinks = seeded }
        if enabled {
            let libraryURL = self.folder.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: libraryURL.path) {
                do {
                    let saved = try JSONDecoder().decode([LibrarySong].self, from: Data(contentsOf: libraryURL))
                    guard Set(saved.map(\.id)).count == saved.count else { throw LibraryWriteError.unreadableLibrary }
                    imported = saved
                    // Saved bundled metadata overrides its seed, rather than duplicating its ID.
                    for song in saved {
                        if let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song }
                        else { songs.append(song) }
                    }
                } catch {
                    libraryReadFailed = true
                    self.error = "The saved library could not be read. It has been kept intact; restore it before making library changes."
                }
            }
            let savedLinks = defaults.dictionary(forKey: "videoLinks") as? [String: String] ?? [:]
            videoLinks.merge(savedLinks) { _, saved in saved }
        }
    }

    func url(for song: LibrarySong) -> URL {
        if song.isBundled {
            return (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Library").appendingPathComponent(song.filename)
        }
        return folder.appendingPathComponent("Imports").appendingPathComponent(song.filename)
    }

    func saveVideo(_ id: String, for song: LibrarySong) {
        videoLinks[song.id] = id
        if persistenceEnabled { defaults.set(videoLinks, forKey: "videoLinks") }
    }

    func importTabs() {
        let panel = NSOpenPanel()
        panel.title = "Add Guitar Pro scores or PDF tabs"
        panel.prompt = "Add tabs"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["gp", "gp3", "gp4", "gp5", "gpx", "pdf"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        for source in panel.urls {
            // Stop after a failure so a later success cannot hide its error.
            if importTab(from: source) == nil { break }
        }
    }

    /// Returns an existing entry for identical bytes, even if the source was renamed.
    @discardableResult
    func importTab(from source: URL) -> String? {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            guard !libraryReadFailed else { throw LibraryWriteError.unreadableLibrary }
            let ext = source.pathExtension.lowercased()
            guard ["gp", "gp3", "gp4", "gp5", "gpx", "pdf"].contains(ext),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LibraryWriteError.unsupportedFile
            }
            let hash = try LibraryFileIdentity.contentHash(at: source)
            var knownHashes: [URL: String] = [:]
            // Prefer the whole book if both the book and sections share these bytes.
            for song in songs.sorted(by: {
                ($0.pageStart == nil && $0.pageEnd == nil ? 0 : 1)
                    < ($1.pageStart == nil && $1.pageEnd == nil ? 0 : 1)
            }) {
                let existingURL = url(for: song)
                let existingHash = knownHashes[existingURL] ?? (try? LibraryFileIdentity.contentHash(at: existingURL))
                knownHashes[existingURL] = existingHash
                if existingHash == hash { error = nil; return song.id }
            }
            let document = ext == "pdf" ? PDFDocument(url: source) : nil
            if ext == "pdf", document == nil { throw LibraryWriteError.invalidPDF }
            let details = LibraryImportDetails(filename: source.lastPathComponent,
                metadataTitle: document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                metadataArtist: document?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
            let id = UUID().uuidString
            let filename = id + "." + ext
            let destination = folder.appendingPathComponent("Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let copy = destination.appendingPathComponent(filename)
            // copyItem refuses to overwrite any existing file, including an original.
            try FileManager.default.copyItem(at: source, to: copy)
            let song = LibrarySong(id: id, title: details.title, artist: details.artist,
                filename: filename, kind: ext == "pdf" ? "pdf" : "gp", isBundled: false, contentHash: hash)
            do {
                // Detect a source that changed between hashing and copying.
                guard try LibraryFileIdentity.contentHash(at: copy) == hash else { throw LibraryWriteError.changedSource }
                try persist(imported + [song])
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            imported.append(song)
            songs.append(song)
            error = nil
            return id
        } catch {
            self.error = "Could not import tabs: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func updateDetails(for song: LibrarySong, title: String, artist: String, collection: String) -> Bool {
        guard var updated = songs.first(where: { $0.id == song.id }) else { return false }
        let title = LibraryImportDetails.clean(title)
        guard !title.isEmpty else { error = "Enter a title before saving."; return false }
        updated.title = title
        updated.artist = LibraryImportDetails.clean(artist)
        let collection = LibraryImportDetails.clean(collection)
        updated.collection = collection.isEmpty ? nil : collection
        return saveEntry(updated)
    }

    /// Sections reference the same file; they never extract or write PDF pages.
    func addPDFSection(for song: LibrarySong, title: String, startPage: Int, endPage: Int) -> String? {
        guard let parent = songs.first(where: { $0.id == song.id }), parent.kind == "pdf",
              let document = PDFDocument(url: url(for: parent)), !document.isLocked,
              let parentRange = PDFPageRange(pageStart: parent.pageStart, pageEnd: parent.pageEnd, pageCount: document.pageCount),
              let range = PDFPageRange(pageStart: startPage, pageEnd: endPage, pageCount: document.pageCount),
              parentRange.contains(range.start), parentRange.contains(range.end) else {
            error = "Choose a valid page range within this PDF entry. Locked or unreadable PDFs cannot have sections added."
            return nil
        }
        let title = LibraryImportDetails.clean(title)
        guard !title.isEmpty else { error = "Enter a title for the section."; return nil }
        var section = parent
        section.id = UUID().uuidString
        section.title = title
        section.pageStart = range.start
        section.pageEnd = range.end
        section.collection = parent.collection ?? parent.title
        // A new ID intentionally starts without a video or reading position.
        return saveEntry(section) ? section.id : nil
    }

    /// Removes only the entry. Source files are retained, including shared books.
    @discardableResult
    func removeEntry(_ song: LibrarySong) -> Bool {
        guard songs.contains(where: { $0.id == song.id }) else { return false }
        guard !bundledIDs.contains(song.id) else {
            error = "Bundled library entries cannot be removed."
            return false
        }
        let updated = imported.filter { $0.id != song.id }
        do {
            try persist(updated)
            imported = updated
            songs.removeAll { $0.id == song.id }
            error = nil
            return true
        } catch {
            self.error = "Could not remove the entry: \(error.localizedDescription)"
            return false
        }
    }

    private func saveEntry(_ song: LibrarySong) -> Bool {
        var updated = imported
        if let index = updated.firstIndex(where: { $0.id == song.id }) { updated[index] = song }
        else { updated.append(song) }
        do {
            try persist(updated)
            imported = updated
            if let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song }
            else { songs.append(song) }
            error = nil
            return true
        } catch {
            self.error = "Could not save the library: \(error.localizedDescription)"
            return false
        }
    }

    private func persist(_ updated: [LibrarySong]) throws {
        guard !libraryReadFailed else { throw LibraryWriteError.unreadableLibrary }
        guard persistenceEnabled else { return }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("library.json"), options: .atomic)
    }
}

private enum LibraryWriteError: LocalizedError {
    case unreadableLibrary, unsupportedFile, invalidPDF, changedSource
    var errorDescription: String? {
        switch self {
        case .unreadableLibrary: return "The existing saved library is unreadable and has been kept intact."
        case .unsupportedFile: return "Choose a regular PDF or Guitar Pro file."
        case .invalidPDF: return "This file could not be opened as a PDF."
        case .changedSource: return "The source changed during import. Try again once it has finished saving."
        }
    }
}

func formatTime(_ value: Double) -> String {
    guard value.isFinite else { return "0:00" }
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func javascriptJSON(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}
