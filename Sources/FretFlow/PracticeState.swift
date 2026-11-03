import Foundation

struct NamedPracticeLoop: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var start: Double
    var end: Double
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && start.isFinite && end.isFinite && start >= 0 && end > start
    }
}

/// Recording seconds and accepted playback speed, independent of score format.
struct SavedPracticeState: Codable, Equatable {
    var position: Double = 0
    var rate: Double = 1
    var loops: [NamedPracticeLoop] = []

    var sanitized: SavedPracticeState {
        SavedPracticeState(position: position.isFinite ? max(0, position) : 0,
                           rate: rate.isFinite && (0.125...4).contains(rate) ? rate : 1,
                           loops: loops.filter(\.isValid))
    }
}

/// A separate versioned preference leaves libraries, video links and recording
/// calibrations untouched. A replacement recording starts a new practice state.
final class PracticeStateStore {
    static let preferenceKey = "FretFlow.practice.v1"
    private let defaults: UserDefaults
    private let enabled: Bool
    private var states: [String: SavedPracticeState]

    init(defaults: UserDefaults = .standard, enabled: Bool = true) {
        self.defaults = defaults
        self.enabled = enabled
        if enabled, let data = defaults.data(forKey: Self.preferenceKey),
           let decoded = try? JSONDecoder().decode([String: SavedPracticeState].self, from: data) {
            states = decoded.mapValues(\.sanitized)
        } else { states = [:] }
    }

    static func key(songID: String, videoID: String?) -> String {
        // Encode the tuple so separators in imported IDs cannot collide.
        let data = try! JSONEncoder().encode([songID, videoID ?? ""])
        return data.base64EncodedString()
    }

    func state(for key: String) -> SavedPracticeState { states[key] ?? SavedPracticeState() }

    func save(_ state: SavedPracticeState, for key: String) {
        let value = state.sanitized
        guard states[key] != value else { return }
        var updated = states
        updated[key] = value
        guard let data = try? JSONEncoder().encode(updated) else { return }
        if enabled { defaults.set(data, forKey: Self.preferenceKey) }
        states = updated
    }
}

struct PracticeCountIn {
    let beats: Int
    let bpm: Double
    var interval: Double { 60 / bpm }
    var isValid: Bool { (1...8).contains(beats) && bpm.isFinite && (30...240).contains(bpm) }
}

/// A seek can settle on a nearby keyframe or be refused. Fresh observed motion
/// establishes the actual position; a frozen cued/offline zero does not.
enum PracticeRestorePolicy {
    static func isAcknowledged(target: Double, position: Double, playbackIsAdvancing: Bool) -> Bool {
        guard target.isFinite, target >= 0, position.isFinite, position >= 0 else { return false }
        return abs(position - target) < 0.5 || playbackIsAdvancing
    }
}
