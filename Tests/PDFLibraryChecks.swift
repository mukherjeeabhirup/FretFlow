// Independently authored synthetic fixtures only; all files and preferences are temporary.
// macOS (PDFKit/AppKit) standalone check command:
// swiftc -swift-version 5 -parse-as-library Sources/FretFlow/PDFLibraryModels.swift Sources/FretFlow/LibraryStore.swift Sources/FretFlow/PDFPracticeView.swift Tests/PDFLibraryChecks.swift -o /tmp/fretflow-pdf-library-checks
// /tmp/fretflow-pdf-library-checks
import Foundation
#if canImport(PDFKit) && canImport(AppKit)
import AppKit
import CoreGraphics
import PDFKit
#endif

@main
struct PDFLibraryChecks {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fretflow-pdf-checks-" + UUID().uuidString)
        let suite = "com.local.FretFlow.tests.pdfLibrary." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        var count = 0
        func require(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        let legacy = Data("""
        [{"id":"legacy","title":"Synthetic Study","artist":"Fixture Artist","filename":"fixture.pdf","kind":"pdf","isBundled":false}]
        """.utf8)
        let old = try JSONDecoder().decode([LibrarySong].self, from: legacy)[0]
        require(old.pageStart == nil && old.pageEnd == nil && old.collection == nil && old.contentHash == nil,
                "Missing optional fields must decode as nil")
        let oldCall = LibrarySong(id: "old-call", title: "Study", artist: "", filename: "fixture.gp", kind: "gp", isBundled: false)
        require(oldCall.pageStart == nil && oldCall.collection == nil, "Existing initializers must remain compatible")
        let nullFields = Data("""
        {"id":"nulls","title":"Study","artist":"","filename":"fixture.pdf","kind":"pdf","isBundled":false,"pageStart":null,"pageEnd":null,"collection":null,"contentHash":null}
        """.utf8)
        let nullSong = try JSONDecoder().decode(LibrarySong.self, from: nullFields)
        require(nullSong.pageStart == nil && nullSong.pageEnd == nil && nullSong.collection == nil && nullSong.contentHash == nil,
                "Explicit null additions must decode as nil")
        var extended = old
        extended.pageStart = 2
        extended.pageEnd = 4
        extended.collection = "Synthetic Collection"
        extended.contentHash = "fixture-hash"
        let encoded = try JSONEncoder().encode(extended)
        require(try JSONDecoder().decode(LibrarySong.self, from: encoded) == extended, "Optional additions failed round-trip")
        let oldFields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        require(oldFields["id"] as? String == old.id && oldFields["filename"] as? String == old.filename
                && oldFields["isBundled"] as? Bool == false, "Existing storage fields changed")

        let full = PDFPageRange(pageStart: nil, pageEnd: nil, pageCount: 6)!
        require(full.start == 1 && full.end == 6 && full.count == 6, "Whole-document range changed")
        let range = PDFPageRange(pageStart: 2, pageEnd: 4, pageCount: 6)!
        require(range.count == 3 && range.contains(2) && range.contains(4) && !range.contains(1), "Range is not inclusive")
        require(range.clamped(Int.min) == 2 && range.clamped(Int.max) == 4, "Restored pages must clamp to the section")
        require(PDFPageRange(pageStart: nil, pageEnd: 2, pageCount: 6)?.start == 1
                && PDFPageRange(pageStart: 2, pageEnd: nil, pageCount: 6)?.end == 6, "Open-ended ranges failed")
        for (start, end, pages) in [(0, 2, 6), (-1, 2, 6), (4, 2, 6), (1, 7, 6), (1, 1, 0), (Int.max, Int.max, 6)] {
            require(PDFPageRange(pageStart: start, pageEnd: end, pageCount: pages) == nil, "Invalid range was accepted")
        }

        let details = LibraryImportDetails(filename: "Fixture_Artist - Synthetic_Study.PDF")
        require(details.title == "Synthetic Study" && details.artist == "Fixture Artist", "Filename fallback failed")
        let metadata = LibraryImportDetails(filename: "fallback.pdf", metadataTitle: "  Metadata\nStudy  ", metadataArtist: " Fixture Author ")
        require(metadata.title == "Metadata Study" && metadata.artist == "Fixture Author", "Metadata priority/cleanup failed")
        require(LibraryImportDetails(filename: "Synthetic.pdf", metadataTitle: "Untitled").title == "Synthetic", "Generic metadata hid filename")
        require(LibraryImportDetails(filename: "Artist - Study - Variation.pdf").title == "Study - Variation", "Title separators were truncated")

        let bytes = folder.appendingPathComponent("synthetic.bytes")
        let renamed = folder.appendingPathComponent("renamed.bytes")
        try Data("abc".utf8).write(to: bytes)
        require(try LibraryFileIdentity.contentHash(at: bytes) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "Content identity is not SHA-256")
        try Data(repeating: 0xa4, count: 1_048_577).write(to: bytes)
        try FileManager.default.copyItem(at: bytes, to: renamed)
        let hash = try LibraryFileIdentity.contentHash(at: bytes)
        require(try LibraryFileIdentity.contentHash(at: renamed) == hash, "Renaming changed file identity")
        let handle = try FileHandle(forWritingTo: renamed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01]))
        try handle.close()
        require(try LibraryFileIdentity.contentHash(at: renamed) != hash, "Trailing edited bytes reused identity")
        do {
            _ = try LibraryFileIdentity.contentHash(at: folder.appendingPathComponent("missing.bytes"))
            preconditionFailure("Missing file was hashed")
        } catch { count += 1 }

        defaults.set(["parent": "synthetic-video"], forKey: "videoLinks")
        let calibration = Data([0x01, 0x02])
        defaults.set(calibration, forKey: "FretFlow.recordingSync.v1")
        let positions = PDFReadingStore(defaults: defaults)
        let otherReader = PDFReadingStore(defaults: defaults)
        let parentPosition = PDFReadingPosition(page: 3, zoom: 1.5, fit: false)
        let sectionPosition = PDFReadingPosition(page: 4, zoom: 1, fit: true)
        positions.save(parentPosition, for: "parent")
        otherReader.save(sectionPosition, for: "section")
        let reloaded = PDFReadingStore(defaults: defaults)
        require(reloaded.position(for: "parent") == parentPosition && reloaded.position(for: "section") == sectionPosition,
                "Concurrent readers lost independent persisted positions")
        require(positions.position(for: "section") == sectionPosition && otherReader.position(for: "parent") == parentPosition,
                "An existing reader did not see another window's latest saved state")
        require(reloaded.position(for: "other-section") == nil, "New section inherited another reader's state")
        for bad in [PDFReadingPosition(page: 0, zoom: 1, fit: false),
                    PDFReadingPosition(page: 1, zoom: .nan, fit: false),
                    PDFReadingPosition(page: 1, zoom: 0.09, fit: false),
                    PDFReadingPosition(page: 1, zoom: 8.1, fit: false)] {
            positions.save(bad, for: "parent")
            require(PDFReadingStore(defaults: defaults).position(for: "parent") == parentPosition, "Invalid position replaced saved state")
        }
        let transient = PDFReadingStore(defaults: defaults, persistenceEnabled: false)
        require(transient.position(for: "parent") == nil, "Transient reader loaded persisted state")
        transient.save(sectionPosition, for: "parent")
        require(transient.position(for: "parent") == sectionPosition
                && PDFReadingStore(defaults: defaults).position(for: "parent") == parentPosition,
                "Transient reader wrote preferences")
        require(defaults.dictionary(forKey: "videoLinks") as? [String: String] == ["parent": "synthetic-video"]
                && defaults.data(forKey: "FretFlow.recordingSync.v1") == calibration, "PDF reading changed existing preferences")

        #if canImport(PDFKit) && canImport(AppKit)
        try macChecks(folder: folder, defaults: defaults, require: require)
        print("PDF library checks passed (\(count)): synthetic migration, metadata, hashing, ranges, persistence and macOS PDFKit/store checks.")
        #else
        print("PDF model checks passed (\(count)); PDFKit/store checks require macOS and were not run.")
        #endif
    }

    #if canImport(PDFKit) && canImport(AppKit)
    @MainActor private static func macChecks(folder: URL, defaults: UserDefaults, require: (Bool, String) -> Void) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let source = folder.appendingPathComponent("Fixture Artist - Synthetic Study.PDF")
        try writePDF(to: source, pageCount: 6)
        // A synthetic link from page 2 to page 6 must not escape a 2–4 section.
        let linkedDocument = PDFDocument(url: source)!
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 50, height: 50), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: linkedDocument.page(at: 5)!, at: .zero))
        linkedDocument.page(at: 1)!.addAnnotation(link)
        try linkedDocument.dataRepresentation()!.write(to: source, options: .atomic)
        let originalBytes = try Data(contentsOf: source)
        let libraryFolder = folder.appendingPathComponent("library")
        let store = LibraryStore(folder: libraryFolder, defaults: defaults, loadBundledResources: false)
        let id = store.importTab(from: source)!
        let parent = store.songs.first { $0.id == id }!
        require(parent.title == "Synthetic Study" && parent.artist == "Fixture Artist" && parent.kind == "pdf", "Imported filename metadata failed")
        require(store.url(for: parent) != source && parent.contentHash != nil, "Import did not create its own file identity")
        require(try Data(contentsOf: source) == originalBytes && Data(contentsOf: store.url(for: parent)) == originalBytes,
                "Import changed the source or copied bytes")
        let renamed = folder.appendingPathComponent("Unrelated name.pdf")
        try fm.copyItem(at: source, to: renamed)
        require(store.importTab(from: renamed) == id && store.songs.count == 1, "Renamed PDF created a duplicate entry")

        store.saveVideo("parent-video", for: parent)
        require(store.updateDetails(for: parent, title: " Edited Study ", artist: "Edited Artist", collection: " Practice Book "), "Details edit failed")
        let sectionID = store.addPDFSection(for: parent, title: "First Section", startPage: 2, endPage: 4)!
        let siblingID = store.addPDFSection(for: parent, title: "Second Section", startPage: 4, endPage: 6)!
        let section = store.songs.first { $0.id == sectionID }!
        require(sectionID != id && sectionID != siblingID && section.filename == parent.filename
                && section.pageStart == 2 && section.pageEnd == 4 && section.collection == "Practice Book", "Section lost identity, range or shared source")
        require(store.videoLinks[sectionID] == nil && store.videoLinks[siblingID] == nil, "Section inherited its parent's video")
        store.saveVideo("section-video", for: section)
        require(store.videoLinks[id] == "parent-video" && store.videoLinks[siblingID] == nil, "Section video changed another entry")
        require(store.updateDetails(for: section, title: "Renamed Section", artist: "Section Artist", collection: ""), "Section edit failed")
        let changed = store.songs.first { $0.id == sectionID }!
        require(changed.collection == nil && changed.pageStart == 2 && changed.pageEnd == 4 && changed.id == sectionID,
                "Metadata edit lost the section range or ID")
        let savedCount = store.songs.count
        for (start, end) in [(0, 2), (3, 2), (2, 7)] {
            require(store.addPDFSection(for: parent, title: "Invalid Section", startPage: start, endPage: end) == nil,
                    "Invalid section was accepted")
        }
        require(store.addPDFSection(for: section, title: "Escaping Section", startPage: 1, endPage: 4) == nil,
                "Child section escaped its parent range")
        require(store.addPDFSection(for: parent, title: "  ", startPage: 1, endPage: 1) == nil && store.songs.count == savedCount,
                "Rejected sections changed the library")
        require(!store.updateDetails(for: parent, title: "  ", artist: "", collection: ""), "Empty title was accepted")

        let loaded = try PDFPracticeDocument.load(url: store.url(for: section), pageStart: section.pageStart, pageEnd: section.pageEnd)
        require(loaded.document.pageCount == 3 && loaded.range.start == 2 && loaded.range.end == 4 && loaded.totalPages == 6,
                "Reader did not restrict its document to the inclusive section")
        require(loaded.document.documentURL == nil && loaded.document.page(at: 3) == nil, "Section retained access to adjacent source pages")
        require(loaded.document.page(at: 0)!.annotations.allSatisfy { !($0.action is PDFActionGoTo) },
                "Copied source link could navigate outside the section")
        let whole = try PDFPracticeDocument.load(url: source, pageStart: nil, pageEnd: nil)
        require(whole.document.pageCount == 6 && whole.range.start == 1, "Whole-book reader lost pages")
        do {
            _ = try PDFPracticeDocument.load(url: source, pageStart: 2, pageEnd: 7)
            preconditionFailure("Reader accepted a range beyond the document")
        } catch { require(true, "Invalid reader range was rejected") }
        require(try Data(contentsOf: source) == originalBytes && Data(contentsOf: store.url(for: parent)) == originalBytes,
                "Section creation or reading modified a source PDF")

        // Exercise restoration and persistence through the actual PDFView controller.
        let reading = PDFReadingStore(defaults: defaults)
        reading.save(PDFReadingPosition(page: 3, zoom: 1.5, fit: false), for: sectionID)
        let reader = PDFPracticeController(positions: reading)
        reader.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        reader.open(url: store.url(for: section), songID: sectionID, pageStart: 2, pageEnd: 4)
        require(reader.failure == nil && reader.page == 3 && reader.pageEntry == "3" && reader.view.document?.pageCount == 3,
                "Reader did not restore the section's original page number")
        require(!reader.view.autoScales && abs(Double(reader.view.scaleFactor) - 1.5) < 0.001,
                "Reader did not restore manual zoom")
        reader.pageEntry = "6"
        reader.goToEnteredPage()
        require(reader.page == 3 && reader.pageEntry == "3" && reader.navigationMessage != nil,
                "Page entry escaped the section")
        reader.pageEntry = "not a page"
        reader.goToEnteredPage()
        require(reader.page == 3 && reader.pageEntry == "3", "Invalid page input changed the reading page")
        reader.go(to: 4)
        require(reader.page == 4 && reader.pageEntry == "4", "Next-page navigation lost original page numbers")
        reader.go(to: 2)
        require(reader.page == 2 && reader.pageEntry == "2", "Previous-page navigation lost original page numbers")
        reader.pageEntry = " 3 "
        reader.goToEnteredPage()
        require(reader.page == 3 && reader.navigationMessage == nil, "Valid page entry did not navigate")
        reader.adjustZoom(by: 1.2)
        reader.persistPosition()
        let restored = PDFReadingStore(defaults: defaults).position(for: sectionID)!
        require(restored.page == 3 && !restored.fit && abs(restored.zoom - 1.8) < 0.001,
                "Reader did not persist its page and adjusted zoom")
        reader.fitPage()
        require(PDFReadingStore(defaults: defaults).position(for: sectionID)?.fit == true,
                "Fit mode did not persist")
        reading.save(PDFReadingPosition(page: 6, zoom: 1, fit: true), for: siblingID)
        reader.open(url: store.url(for: section), songID: siblingID, pageStart: 2, pageEnd: 4)
        require(reader.page == 4 && reader.view.autoScales, "Restored page was not clamped to the current range")
        reader.open(url: store.url(for: section), songID: "invalid-range", pageStart: 2, pageEnd: 7)
        require(reader.failure != nil && reader.range == nil && reader.view.document == nil,
                "Invalid reader range left a navigable document")
        require(PDFReadingStore(defaults: defaults).position(for: "invalid-range") == nil,
                "An invalid document created reading state")

        let metadataSource = folder.appendingPathComponent("Filename fallback.pdf")
        try writePDF(to: metadataSource, pageCount: 2, title: "Synthetic Metadata", author: "Synthetic Author")
        let metadataID = store.importTab(from: metadataSource)!
        let metadataSong = store.songs.first { $0.id == metadataID }!
        require(metadataSong.title == "Synthetic Metadata" && metadataSong.artist == "Synthetic Author", "PDF document metadata was ignored")
        let gp = folder.appendingPathComponent("Synthetic.gp")
        try Data("independently authored test bytes".utf8).write(to: gp)
        let gpID = store.importTab(from: gp)!
        require(store.addPDFSection(for: store.songs.first { $0.id == gpID }!, title: "Invalid", startPage: 1, endPage: 1) == nil,
                "Guitar Pro entry accepted PDF page ranges")

        // Persisted hashes must not hide subsequent changes to a local imported copy.
        let identityStore = LibraryStore(folder: folder.appendingPathComponent("identity"), defaults: defaults, loadBundledResources: false)
        let identityID = identityStore.importTab(from: source)!
        let identitySong = identityStore.songs[0]
        try Data(contentsOf: metadataSource).write(to: identityStore.url(for: identitySong), options: .atomic)
        let replacementID = identityStore.importTab(from: renamed)
        require(replacementID != nil && replacementID != identityID && identityStore.songs.count == 2,
                "A stale saved hash hid changed imported bytes")
        require(identityStore.importTab(from: metadataSource) == identityID && identityStore.songs.count == 2,
                "Deduplication ignored the actual current file contents")

        let reopened = LibraryStore(folder: libraryFolder, defaults: defaults, loadBundledResources: false)
        require(reopened.songs == store.songs && reopened.videoLinks[sectionID] == "section-video", "Reload lost metadata, sections or independent videos")
        let sharedFile = store.url(for: parent)
        require(store.removeEntry(parent) && fm.fileExists(atPath: sharedFile.path), "Removing a parent deleted a shared PDF")
        require(store.songs.contains { $0.id == sectionID } && store.songs.contains { $0.id == siblingID }, "Removing a parent removed its sections")
        require(store.importTab(from: renamed) != nil && store.songs.count == savedCount + 1,
                "Deduplication failed when only sections retained the shared file")
        require(store.removeEntry(section) && fm.fileExists(atPath: sharedFile.path) && store.songs.contains { $0.id == siblingID },
                "Removing a section deleted a sibling or source")

        // Migration: an existing imported file has no hash or page fields yet.
        let legacyFolder = folder.appendingPathComponent("legacy")
        try fm.createDirectory(at: legacyFolder.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: legacyFolder.appendingPathComponent("Imports/fixture.pdf"))
        try Data("""
        [{"id":"legacy","title":"Synthetic Study","artist":"Fixture Artist","filename":"fixture.pdf","kind":"pdf","isBundled":false}]
        """.utf8).write(to: legacyFolder.appendingPathComponent("library.json"))
        let migrated = LibraryStore(folder: legacyFolder, defaults: defaults, loadBundledResources: false)
        require(migrated.importTab(from: renamed) == "legacy" && migrated.songs.count == 1, "Legacy unhashed entries were not deduplicated")
        let legacySong = migrated.songs[0]
        require(migrated.updateDetails(for: legacySong, title: "Edited legacy title", artist: legacySong.artist, collection: "Legacy collection"),
                "Editing legacy metadata failed")
        let migratedReload = LibraryStore(folder: legacyFolder, defaults: defaults, loadBundledResources: false)
        require(migratedReload.songs.first?.id == legacySong.id && migratedReload.songs.first?.filename == legacySong.filename
                && migratedReload.songs.first?.collection == "Legacy collection", "Saving legacy metadata lost its identity or source")

        // A deterministic write failure after successful loading must leave memory and files intact.
        let manifest = libraryFolder.appendingPathComponent("library.json")
        let backup = folder.appendingPathComponent("saved-library.json")
        let beforeFailure = store.songs
        let beforeImports = try fm.contentsOfDirectory(atPath: libraryFolder.appendingPathComponent("Imports").path).sorted()
        try fm.moveItem(at: manifest, to: backup)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        require(!store.updateDetails(for: metadataSong, title: "Must not save", artist: "", collection: ""), "Failed write reported success")
        require(!store.removeEntry(metadataSong), "Failed removal reported success")
        require(store.addPDFSection(for: metadataSong, title: "Must not save", startPage: 1, endPage: 1) == nil, "Failed section save reported success")
        let newSource = folder.appendingPathComponent("New synthetic.pdf")
        try writePDF(to: newSource, pageCount: 3)
        require(store.importTab(from: newSource) == nil && store.songs == beforeFailure, "Failed persistence changed in-memory library")
        require(try fm.contentsOfDirectory(atPath: libraryFolder.appendingPathComponent("Imports").path).sorted() == beforeImports,
                "Failed import left an orphaned copy")
        require(fm.fileExists(atPath: newSource.path) && fm.fileExists(atPath: sharedFile.path), "Failed save removed a source file")
        try fm.removeItem(at: manifest)
        try fm.moveItem(at: backup, to: manifest)
        require(LibraryStore(folder: libraryFolder, defaults: defaults, loadBundledResources: false).songs == beforeFailure,
                "Failed writes damaged the saved library")

        let brokenFolder = folder.appendingPathComponent("unreadable")
        try fm.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        let corrupt = Data("not a library".utf8)
        try corrupt.write(to: brokenFolder.appendingPathComponent("library.json"))
        let broken = LibraryStore(folder: brokenFolder, defaults: defaults, loadBundledResources: false)
        require(broken.error != nil && broken.importTab(from: source) == nil, "Unreadable library allowed a destructive replacement")
        require(try Data(contentsOf: brokenFolder.appendingPathComponent("library.json")) == corrupt, "Unreadable saved data was overwritten")

        let duplicateFolder = folder.appendingPathComponent("duplicate-ids")
        try fm.createDirectory(at: duplicateFolder, withIntermediateDirectories: true)
        let duplicateManifest = try JSONEncoder().encode([legacySong, legacySong])
        try duplicateManifest.write(to: duplicateFolder.appendingPathComponent("library.json"))
        let ambiguous = LibraryStore(folder: duplicateFolder, defaults: defaults, loadBundledResources: false)
        require(ambiguous.error != nil && ambiguous.importTab(from: source) == nil,
                "Ambiguous saved IDs allowed the existing manifest to be overwritten")
        require(try Data(contentsOf: duplicateFolder.appendingPathComponent("library.json")) == duplicateManifest,
                "Ambiguous saved IDs changed the original manifest")

        require(defaults.dictionary(forKey: "videoLinks") as? [String: String] == store.videoLinks
                && store.videoLinks["parent"] == "synthetic-video"
                && defaults.data(forKey: "FretFlow.recordingSync.v1") == Data([0x01, 0x02]),
                "Library changes discarded existing videos or calibrations")

        let smokeFolder = folder.appendingPathComponent("transient")
        let smoke = LibraryStore(folder: smokeFolder, defaults: defaults, persistenceEnabled: false, loadBundledResources: false)
        require(smoke.videoLinks.isEmpty && smoke.importTab(from: source) != nil, "Transient library loaded saved videos or could not import")
        require(!fm.fileExists(atPath: smokeFolder.appendingPathComponent("library.json").path), "Transient library wrote a manifest")
    }

    /// Vector rectangles only: no music, external documents, screenshots or OCR.
    private static func writePDF(to url: URL, pageCount: Int, title: String? = nil, author: String? = nil) throws {
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 420)
        var metadata: [String: String] = [:]
        metadata[kCGPDFContextTitle as String] = title
        metadata[kCGPDFContextAuthor as String] = author
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, metadata as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(red: CGFloat(index + 1) / CGFloat(pageCount + 1), green: 0.4, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: 20, y: 20, width: CGFloat(50 + index * 10), height: 80))
            context.endPDFPage()
        }
        context.closePDF()
    }
    #endif
}
