import Combine
import CryptoKit
import Foundation

/// An additive adjustment in recording/content seconds, before playback speed.
struct RecordingSyncSetting: Codable, Equatable {
    let adjustment: Double
    let source: String
    let confidence: Double?

    var isValid: Bool {
        adjustment.isFinite && (-30...120).contains(adjustment)
            && ["manual", "automatic"].contains(source)
            && (confidence == nil || (confidence!.isFinite && (0...1).contains(confidence!)))
    }
}

/// Each recording and exact score revision has its own correction. Replacing
/// a video or editing a score must never inherit an unrelated recording offset.
@MainActor
final class RecordingSyncStore: ObservableObject {
    private static let preferenceKey = "FretFlow.recordingSync.v1"
    @Published private var settings: [String: RecordingSyncSetting] = [:]
    private let persistenceEnabled: Bool
    private let defaults: UserDefaults

    init(persistenceEnabled: Bool = true, defaults: UserDefaults = .standard) {
        self.persistenceEnabled = persistenceEnabled
        self.defaults = defaults
        guard persistenceEnabled,
              let data = defaults.data(forKey: Self.preferenceKey),
              let decoded = try? JSONDecoder().decode([String: RecordingSyncSetting].self, from: data) else { return }
        settings = decoded.filter { Self.isValidKey($0.key) && $0.value.isValid }
    }

    func key(songID: String, videoID: String, scoreURL: URL) -> String? {
        // PDFs are reference material; don't hash a potentially large tab book.
        guard scoreURL.isFileURL,
              ["gp", "gp3", "gp4", "gp5", "gpx"].contains(scoreURL.pathExtension.lowercased()),
              !songID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !videoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let values = try? scoreURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= 64 * 1024 * 1024,
              let bytes = try? Data(contentsOf: scoreURL, options: .mappedIfSafe),
              bytes.count <= 64 * 1024 * 1024 else { return nil }
        let scoreHash = Self.hex(SHA256.hash(data: bytes))
        // An encoded tuple avoids ambiguity between IDs containing separators.
        guard let identity = try? JSONEncoder().encode([songID, videoID, scoreHash]) else { return nil }
        return "v1." + Self.hex(SHA256.hash(data: identity))
    }

    func setting(for key: String?) -> RecordingSyncSetting? {
        guard let key else { return nil }
        return settings[key]
    }

    /// Invalid inputs are ignored and leave a previously saved value intact.
    @discardableResult
    func save(adjustment: Double, source: String = "manual", confidence: Double? = nil, for key: String) -> Bool {
        let setting = RecordingSyncSetting(adjustment: adjustment, source: source, confidence: confidence)
        guard Self.isValidKey(key), setting.isValid else { return false }
        var updated = settings
        updated[key] = setting
        return commit(updated)
    }

    func remove(for key: String) {
        guard settings[key] != nil else { return }
        var updated = settings
        updated.removeValue(forKey: key)
        _ = commit(updated)
    }

    private func commit(_ updated: [String: RecordingSyncSetting]) -> Bool {
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        settings = updated
        if persistenceEnabled { defaults.set(data, forKey: Self.preferenceKey) }
        return true
    }

    private static func isValidKey(_ value: String) -> Bool {
        value.count == 67 && value.hasPrefix("v1.")
            && value.dropFirst(3).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func hex(_ hash: SHA256.Digest) -> String {
        hash.map { String(format: "%02x", $0) }.joined()
    }
}
