import Combine
import Foundation

@MainActor
final class RecordingAutoSync: ObservableObject {
    @Published var enabled = true {
        didSet {
            if !enabled { cancel() }
            if persistenceEnabled { UserDefaults.standard.set(enabled, forKey: "FretFlow.autoSync.enabled") }
        }
    }
    @Published private(set) var isAnalyzing = false
    @Published private(set) var status = "Play from the beginning to match this video."
    @Published private(set) var error: String?
    private(set) var lastDiagnostics = [String: Any]()
    var onRestart: (() -> Void)?
    var onMatch: ((String, RecordingOnsetMatch) -> Void)?
    var onAnalysisStarted: (() -> Void)?
    private let capture = PlaybackAudioCapture()
    private let persistenceEnabled: Bool
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var identity: String?
    private var referenceAttacks = [Double]()
    private var scale = 1.0
    private var inferredOffset = 0.0
    private var saved = false
    private var attempted = false
    private var waitingForStart = false
    private var restartIssued = false
    private var startedAt = 0.0
    private var lastFresh = 0.0
    private var listeningRevision: UInt64?
    private var listeningHost = 0.0
    private var mediaLimit = 15.0
    private var clock = RecordingPlaybackClock()
    private var pendingWindows = [PlaybackAudioWindow]()
    private var matcher: RecordingOnsetMatcher?

    init(persistenceEnabled: Bool = true) {
        self.persistenceEnabled = persistenceEnabled
        if persistenceEnabled, let value = UserDefaults.standard.object(forKey: "FretFlow.autoSync.enabled") as? Bool { enabled = value }
        capture.onWindow = { [weak self] in self?.receive($0) }
        capture.onFailure = { [weak self] in self?.fail($0) }
    }

    func configure(identity: String?, referenceAttacks: [Double], scale: Double,
                   inferredOffset: Double, hasSavedAlignment: Bool) {
        let changed = self.identity != identity || self.referenceAttacks != referenceAttacks
            || (saved && !hasSavedAlignment)
        if changed { cancel(); attempted = false }
        self.identity = identity
        self.referenceAttacks = referenceAttacks
        self.scale = scale
        self.inferredOffset = inferredOffset
        saved = hasSavedAlignment
        if saved {
            cancel()
            status = "Using the saved alignment for this video."
        } else if changed {
            status = referenceAttacks.isEmpty ? "This score has no usable note attacks for matching."
                : "Play from the beginning to match this video."
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        if isAnalyzing { status = "Matching stopped. Alignment unchanged." }
        error = nil
        isAnalyzing = false
        waitingForStart = false
        restartIssued = false
        matcher = nil
        listeningRevision = nil
        clock.reset()
        pendingWindows.removeAll(keepingCapacity: true)
        capture.cancel()
    }

    func playbackClockDidReset() {
        clock.reset()
        pendingWindows.removeAll(keepingCapacity: true)
        if isAnalyzing && !waitingForStart && listeningRevision != nil {
            fail("Playback changed during matching. Press Match start to try again.")
        }
    }

    func retry() {
        attempted = false
        begin()
    }

    func observe(position: Double, rate: Double, fresh: Bool, revision: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        if !isAnalyzing {
            // Some videos expose a usable clock only after their first half
            // second. Matching restarts playback, so allow that startup delay
            // without interpreting an ordinary mid-song play as a new attempt.
            if enabled && !saved && !attempted && fresh && position < 3 { begin() }
            return
        }
        guard capture.isCapturing && restartIssued else {
            // Permission may be awaiting a user response; don't time it out.
            return
        }
        if waitingForStart {
            if fresh && position < 0.4 {
                waitingForStart = false
                listeningRevision = revision
                listeningHost = now
                lastFresh = now
                status = "Matching the recording…"
            } else if now - startedAt > 15 {
                fail("The video did not restart. Press Match start to try again.")
                return
            } else { return }
        }
        guard fresh, listeningRevision == revision else {
            if now - lastFresh > 0.6 || (fresh && listeningRevision != revision) {
                fail("Playback changed during matching. Press Match start to try again.")
            }
            return
        }
        lastFresh = now
        clock.observe(position: position, rate: rate, host: now, revision: revision)
        if !clock.isReady && now - listeningHost > 2.8 {
            fail("The video clock did not settle. Press Match start to try again.")
            return
        }
        if position >= mediaLimit {
            if let match = matcher?.finish() { accept(match) }
            else { fail("No confident match found. Try again or use Fine adjustment.") }
        }
    }

    private func begin() {
        guard enabled, !isAnalyzing, let identity, !referenceAttacks.isEmpty,
              scale.isFinite, scale > 0, inferredOffset.isFinite else { return }
        generation &+= 1
        let ticket = generation
        attempted = true
        isAnalyzing = true
        waitingForStart = true
        restartIssued = false
        startedAt = 0
        error = nil
        lastDiagnostics = [:]
        status = "Preparing playback analysis… Allow audio access if macOS asks."
        clock.reset()
        pendingWindows.removeAll(keepingCapacity: true)
        listeningRevision = nil
        matcher = RecordingOnsetMatcher(referenceAttacks: referenceAttacks, alignmentScale: scale, inferredOffset: inferredOffset)
        let requiredAttack = referenceAttacks[min(7, referenceAttacks.count - 1)] * scale + max(0, inferredOffset)
        mediaLimit = min(55, max(15, requiredAttack + 4))
        onAnalysisStarted?()
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == ticket, self.identity == identity else { return }
            do {
                try await self.capture.start()
                guard !Task.isCancelled, self.generation == ticket, self.identity == identity else { return }
                self.startedAt = ProcessInfo.processInfo.systemUptime
                self.restartIssued = true
                self.status = "Listening from the beginning…"
                self.onRestart?()
            } catch {
                guard self.generation == ticket else { return }
                self.fail(error is CancellationError ? "Matching was interrupted. Press Match start to try again."
                    : (self.capture.error ?? error.localizedDescription))
            }
        }
    }

    private func receive(_ window: PlaybackAudioWindow) {
        guard isAnalyzing, !waitingForStart, window.hostTime >= listeningHost else { return }
        // Retain only short energy summaries while the video clock settles.
        // Replay the opening against one calibrated clock so its initial
        // silence is preserved without baking a startup snapshot's jitter into
        // the saved recording offset. No raw audio is buffered here.
        pendingWindows.append(window)
        guard pendingWindows.count <= 300 else {
            fail("The video clock did not settle. Press Match start to try again.")
            return
        }
        guard clock.isReady else { return }
        let ready = pendingWindows
        pendingWindows.removeAll(keepingCapacity: true)
        let now = ProcessInfo.processInfo.systemUptime
        for item in ready {
            guard isAnalyzing else { break }
            if let time = clock.mediaTime(for: item.hostTime, now: now),
               let match = matcher?.observe(time: time, rms: item.rms, peak: item.peak) { accept(match) }
        }
    }

    private func accept(_ match: RecordingOnsetMatch) {
        guard let identity, isAnalyzing, match.adjustment.isFinite,
              (-30...120).contains(match.adjustment) else { return }
        lastDiagnostics = matcher?.diagnostics ?? [:]
        cancel()
        saved = true
        status = String(format: "Matched and saved · %+.2f s", match.adjustment)
        onMatch?(identity, match)
    }

    private func fail(_ message: String) {
        lastDiagnostics = matcher?.diagnostics ?? [:]
        cancel()
        attempted = true
        error = message
        status = "Alignment unchanged."
    }
}
