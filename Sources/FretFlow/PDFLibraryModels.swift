import CryptoKit
import Foundation

struct LibrarySong: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var filename: String
    var kind: String
    var isBundled: Bool
    // Missing keys in existing libraries decode as nil. Pages are 1-based and inclusive.
    var pageStart: Int? = nil
    var pageEnd: Int? = nil
    var collection: String? = nil
    var contentHash: String? = nil
}

struct PDFPageRange: Equatable {
    let start: Int
    let end: Int
    var count: Int { end - start + 1 }

    init?(pageStart: Int?, pageEnd: Int?, pageCount: Int) {
        let start = pageStart ?? 1
        let end = pageEnd ?? pageCount
        guard pageCount > 0, start >= 1, start <= end, end <= pageCount else { return nil }
        self.start = start
        self.end = end
    }

    func contains(_ page: Int) -> Bool { (start...end).contains(page) }
    func clamped(_ page: Int) -> Int { max(start, min(end, page)) }
}

enum LibraryFileIdentity {
    /// Stream bytes so large books do not require a second full in-memory copy.
    static func contentHash(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct LibraryImportDetails: Equatable {
    let title: String
    let artist: String

    init(filename: String, metadataTitle: String? = nil, metadataArtist: String? = nil) {
        let stem = Self.clean(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " "))
        let parts = stem.components(separatedBy: " - ")
        let filenameArtist = parts.count > 1 ? Self.clean(parts[0]) : ""
        let filenameTitle = parts.count > 1 ? Self.clean(parts.dropFirst().joined(separator: " - ")) : stem
        let suppliedTitle = Self.clean(metadataTitle ?? "")
        let meaningfulTitle = ["untitled", "untitled document", "document"].contains(suppliedTitle.lowercased())
            ? "" : suppliedTitle
        title = meaningfulTitle.isEmpty ? (filenameTitle.isEmpty ? "Untitled PDF" : filenameTitle) : meaningfulTitle
        let suppliedArtist = Self.clean(metadataArtist ?? "")
        artist = suppliedArtist.isEmpty ? filenameArtist : suppliedArtist
    }

    static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct PDFReadingPosition: Codable, Equatable {
    var page: Int
    var zoom: Double
    var fit: Bool

    var isValid: Bool { page >= 1 && zoom.isFinite && (0.1...8).contains(zoom) }
}

/// Uses a separate preferences key; video links and recording calibrations are untouched.
final class PDFReadingStore {
    private static let key = "FretFlow.pdfReading.v1"
    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private var positions: [String: PDFReadingPosition] = [:]

    init(defaults: UserDefaults = .standard, persistenceEnabled: Bool = true) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        if persistenceEnabled { positions = read() }
    }

    func position(for songID: String) -> PDFReadingPosition? {
        // A reader can stay alive while another window updates this song.
        if persistenceEnabled { positions = read() }
        return positions[songID]
    }

    func save(_ position: PDFReadingPosition, for songID: String) {
        guard !songID.isEmpty, position.isValid else { return }
        // A second reader window must not overwrite another song's latest position.
        if persistenceEnabled { positions = read() }
        positions[songID] = position
        if persistenceEnabled, let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func read() -> [String: PDFReadingPosition] {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([String: PDFReadingPosition].self, from: data) else { return [:] }
        return saved.filter { !$0.key.isEmpty && $0.value.isValid }
    }
}
