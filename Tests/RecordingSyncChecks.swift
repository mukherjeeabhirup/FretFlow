// Offline persistence/identity checks. Uses only a unique temporary preferences
// suite and temporary score fixtures; never touches FretFlow's real settings.
import Foundation

@main
struct RecordingSyncChecks {
    @MainActor static func main() throws {
        let suite = "com.local.FretFlow.tests.recordingSync." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fretflow-sync-" + UUID().uuidString)
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
        let firstScore = folder.appendingPathComponent("first.gp")
        let copiedScore = folder.appendingPathComponent("copy.GPX")
        let pdf = folder.appendingPathComponent("book.pdf")
        try Data("test score revision 1".utf8).write(to: firstScore)
        try FileManager.default.copyItem(at: firstScore, to: copiedScore)
        try Data("This is not a GP file".utf8).write(to: pdf)

        let store = RecordingSyncStore(defaults: defaults)
        let first = store.key(songID: "song-a", videoID: "video-a", scoreURL: firstScore)!
        let anotherSong = store.key(songID: "song-b", videoID: "video-a", scoreURL: firstScore)!
        let anotherVideo = store.key(songID: "song-a", videoID: "video-b", scoreURL: firstScore)!
        require(first != anotherSong, "Different songs shared an adjustment key")
        require(first != anotherVideo, "A replacement video inherited the old recording identity")
        require(first == store.key(songID: "song-a", videoID: "video-a", scoreURL: copiedScore),
                "Moving or copying the same score changed its content identity")
        try Data("test score revision 2".utf8).write(to: copiedScore)
        let changedScore = store.key(songID: "song-a", videoID: "video-a", scoreURL: copiedScore)!
        require(first != changedScore, "Edited score bytes reused a previous alignment")
        require(store.key(songID: "song-a", videoID: "video-a", scoreURL: pdf) == nil, "PDFs must not be hashed")
        require(store.key(songID: "song-a", videoID: "video-a", scoreURL: folder.appendingPathComponent("missing.gp")) == nil,
                "Missing scores should have no identity")
        require(store.key(songID: "", videoID: "video-a", scoreURL: firstScore) == nil, "Missing song IDs should have no identity")
        require(store.key(songID: "song-a", videoID: " ", scoreURL: firstScore) == nil, "Missing video IDs should have no identity")
        require(store.key(songID: "a|b", videoID: "c", scoreURL: firstScore)
                    != store.key(songID: "a", videoID: "b|c", scoreURL: firstScore), "Identity separators caused a collision")

        require(store.setting(for: nil) == nil && store.setting(for: first) == nil,
                "Unset alignment must default to no setting, allowing a zero correction")
        require(store.save(adjustment: 0.75, for: first), "Valid adjustment was rejected")
        let saved = store.setting(for: first)!
        require(saved.adjustment == 0.75 && saved.source == "manual" && saved.confidence == nil,
                "Manual adjustment metadata was lost")
        require(store.setting(for: anotherSong) == nil && store.setting(for: anotherVideo) == nil
                    && store.setting(for: changedScore) == nil, "A saved correction leaked to another recording or score")
        let roundtrip = RecordingSyncStore(defaults: defaults)
        require(roundtrip.setting(for: first) == saved, "Saved correction did not survive reloading")
        require(roundtrip.save(adjustment: -0.4, source: "automatic", confidence: 0.93, for: anotherVideo),
                "Valid automatic alignment metadata was rejected")
        let automatic = RecordingSyncStore(defaults: defaults).setting(for: anotherVideo)
        require(automatic?.adjustment == -0.4 && automatic?.source == "automatic" && automatic?.confidence == 0.93,
                "Automatic alignment metadata did not round-trip")

        for invalid in [Double.nan, .infinity, -.infinity, -30.001, 120.001] {
            require(!roundtrip.save(adjustment: invalid, for: first), "Invalid adjustment was accepted")
            require(roundtrip.setting(for: first) == saved, "Rejected adjustment changed an existing setting")
        }
        for invalid in [Double.nan, .infinity, -0.001, 1.001] {
            require(!roundtrip.save(adjustment: 0.2, source: "automatic", confidence: invalid, for: first),
                    "Invalid confidence was accepted")
        }
        require(!roundtrip.save(adjustment: 0.2, source: "guessed", for: first), "Unknown source was accepted")
        require(!roundtrip.save(adjustment: 0.2, for: "invalid-key"), "Malformed identity was accepted")
        require(roundtrip.save(adjustment: -30, for: first) && roundtrip.save(adjustment: 120, for: first),
                "Valid adjustment boundaries were rejected")
        roundtrip.remove(for: first)
        require(RecordingSyncStore(defaults: defaults).setting(for: first) == nil, "Reset did not persist")
        require(RecordingSyncStore(defaults: defaults).setting(for: anotherVideo) == automatic,
                "Reset removed another video's correction")

        let transient = RecordingSyncStore(persistenceEnabled: false, defaults: defaults)
        require(transient.setting(for: anotherVideo) == nil, "Smoke/in-memory store loaded real persisted data")
        require(transient.save(adjustment: 1.25, for: first), "In-memory correction failed")
        require(transient.setting(for: first)?.adjustment == 1.25, "In-memory correction was not retained")
        require(RecordingSyncStore(defaults: defaults).setting(for: first) == nil, "In-memory correction was persisted")

        // Valid-looking external preferences still need semantic validation.
        let badRecords: [String: RecordingSyncSetting] = [
            first: .init(adjustment: 0.75, source: "manual", confidence: nil),
            anotherVideo: .init(adjustment: 121, source: "manual", confidence: nil),
            changedScore: .init(adjustment: 0.3, source: "automatic", confidence: 1.2),
            anotherSong: .init(adjustment: 0.3, source: "unknown", confidence: nil)
        ]
        defaults.set(try JSONEncoder().encode(badRecords), forKey: "FretFlow.recordingSync.v1")
        let validated = RecordingSyncStore(defaults: defaults)
        require(validated.setting(for: first)?.adjustment == 0.75, "Valid persisted correction was discarded")
        require(validated.setting(for: anotherVideo) == nil && validated.setting(for: changedScore) == nil
                    && validated.setting(for: anotherSong) == nil, "Invalid persisted corrections were accepted")
        defaults.set(Data("not JSON".utf8), forKey: "FretFlow.recordingSync.v1")
        require(RecordingSyncStore(defaults: defaults).setting(for: first) == nil, "Corrupt preferences should fail closed")
        print("Recording sync checks passed (\(count)): recording/score identity, isolated persistence, reset, metadata and bounds.")
    }
}
