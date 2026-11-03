import Foundation

@main struct PracticeStateChecks {
    static func main() throws {
        let suite = "FretFlow.synthetic.practice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["existing": "abcdefghijk"], forKey: "videoLinks")
        defaults.set(Data([1, 2, 3]), forKey: "FretFlow.recordingSync.v1")
        let store = PracticeStateStore(defaults: defaults)
        let key = PracticeStateStore.key(songID: "synthetic-section", videoID: "abcdefghijk")
        let loop = NamedPracticeLoop(name: "Warmup", start: 12, end: 18)
        store.save(SavedPracticeState(position: 14, rate: 0.75, loops: [loop]), for: key)
        let restored = PracticeStateStore(defaults: defaults).state(for: key)
        precondition(restored.position == 14 && restored.rate == 0.75 && restored.loops == [loop])
        let replacement = PracticeStateStore.key(songID: "synthetic-section", videoID: "lmnopqrstuv")
        precondition(store.state(for: replacement) == SavedPracticeState())
        precondition(PracticeStateStore.key(songID: "a/b", videoID: "c") != PracticeStateStore.key(songID: "a", videoID: "b/c"))
        store.save(SavedPracticeState(position: -.infinity, rate: .nan,
            loops: [NamedPracticeLoop(name: "", start: 0, end: 1), NamedPracticeLoop(name: "Invalid", start: 5, end: 2)]), for: key)
        precondition(store.state(for: key) == SavedPracticeState())
        precondition(defaults.dictionary(forKey: "videoLinks") as? [String: String] == ["existing": "abcdefghijk"])
        precondition(defaults.data(forKey: "FretFlow.recordingSync.v1") == Data([1, 2, 3]))
        defaults.set(Data("invalid".utf8), forKey: PracticeStateStore.preferenceKey)
        precondition(PracticeStateStore(defaults: defaults).state(for: key) == SavedPracticeState())
        let disabled = PracticeStateStore(defaults: defaults, enabled: false)
        disabled.save(restored, for: key)
        precondition(defaults.data(forKey: PracticeStateStore.preferenceKey) == Data("invalid".utf8))
        precondition(!PracticeRestorePolicy.isAcknowledged(target: 100, position: 0, playbackIsAdvancing: false),
                     "A cue's frozen zero must not overwrite saved progress")
        precondition(PracticeRestorePolicy.isAcknowledged(target: 100, position: 100.1, playbackIsAdvancing: false),
                     "A paused seek acknowledgement must release restore protection")
        precondition(!PracticeRestorePolicy.isAcknowledged(target: 100, position: 101, playbackIsAdvancing: false))
        precondition(PracticeRestorePolicy.isAcknowledged(target: 100, position: 101, playbackIsAdvancing: true),
                     "An off-target seek followed by confirmed playback must allow later saves")
        precondition(PracticeRestorePolicy.isAcknowledged(target: 100, position: 2, playbackIsAdvancing: true),
                     "A refused seek must not block saving deliberate advancing playback forever")
        precondition(!PracticeRestorePolicy.isAcknowledged(target: 100, position: .nan, playbackIsAdvancing: true))
        precondition(PracticeCountIn(beats: 4, bpm: 80).isValid)
        precondition(PracticeCountIn(beats: 4, bpm: 80).interval == 0.75)
        precondition(!PracticeCountIn(beats: 4, bpm: 0).isValid)
        print("Practice state checks passed (synthetic persistence, recording isolation, validation, count-in).")
    }
}
