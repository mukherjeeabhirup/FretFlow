import AppKit
import Foundation
import UniformTypeIdentifiers

struct LibrarySong: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var filename: String
    var kind: String
    var isBundled: Bool
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var songs: [LibrarySong] = []
    @Published var error: String?
    @Published var videoLinks: [String: String] = [:]
    private let folder: URL
    private let persistenceEnabled: Bool
    private var imported: [LibrarySong] = []
    var bookURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Library/Plini - An Unnameable Desire.pdf")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    init() {
        persistenceEnabled = !ProcessInfo.processInfo.arguments.contains("--smoke-test")
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FretFlow", isDirectory: true)
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Library/library.json"),
           let data = try? Data(contentsOf: url),
           let seeded = try? JSONDecoder().decode([LibrarySong].self, from: data) {
            // Personal scores are optional resources and are not distributed
            // with the source repository. Keep a fresh checkout's library usable.
            songs = seeded.filter { song in
                FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
                    .appendingPathComponent(song.filename).path)
            }
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Library/videos.json"),
           let data = try? Data(contentsOf: url),
           let seeded = try? JSONDecoder().decode([String: String].self, from: data) { videoLinks = seeded }
        if persistenceEnabled {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
               let saved = try? JSONDecoder().decode([LibrarySong].self, from: data) {
                imported = saved
                songs += saved
            }
            let savedLinks = UserDefaults.standard.dictionary(forKey: "videoLinks") as? [String: String] ?? [:]
            videoLinks.merge(savedLinks) { _, saved in saved }
        }
    }

    func url(for song: LibrarySong) -> URL {
        if song.isBundled {
            return Bundle.main.resourceURL!.appendingPathComponent("Library").appendingPathComponent(song.filename)
        }
        return folder.appendingPathComponent("Imports").appendingPathComponent(song.filename)
    }

    func saveVideo(_ id: String, for song: LibrarySong) {
        videoLinks[song.id] = id
        if persistenceEnabled { UserDefaults.standard.set(videoLinks, forKey: "videoLinks") }
    }

    func importTabs() {
        let panel = NSOpenPanel()
        panel.title = "Add Guitar Pro scores or PDF tabs"
        panel.prompt = "Add tabs"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["gp", "gp3", "gp4", "gp5", "gpx", "pdf"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        do {
            let destination = folder.appendingPathComponent("Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in panel.urls {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let id = UUID().uuidString
                let file = id + "." + source.pathExtension.lowercased()
                try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(file))
                let song = LibrarySong(id: id, title: source.deletingPathExtension().lastPathComponent,
                    artist: "Imported tab", filename: file, kind: source.pathExtension.lowercased() == "pdf" ? "pdf" : "gp", isBundled: false)
                let updated = imported + [song]
                do {
                    try JSONEncoder().encode(updated).write(to: folder.appendingPathComponent("library.json"), options: .atomic)
                } catch {
                    try? FileManager.default.removeItem(at: destination.appendingPathComponent(file))
                    throw error
                }
                imported = updated
                songs.append(song)
            }
        } catch { self.error = "Could not import tabs: \(error.localizedDescription)" }
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
