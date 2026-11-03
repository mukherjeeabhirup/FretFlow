import Foundation

// This executable deliberately excludes PlaybackAudioCapture.swift. Its fake
// suspends capture startup under test control; it never requests permissions,
// opens a device, plays audio, or touches user preferences.
struct PlaybackAudioWindow {
    let hostTime: TimeInterval
    let duration: Double
    let rms: Double
    let peak: Double
    let flux: Double
}

@MainActor
final class PlaybackAudioCapture {
    static var latest: PlaybackAudioCapture?
    var onWindow: ((PlaybackAudioWindow) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var isCapturing = false
    private(set) var error: String?
    private(set) var startCalls = 0
    private(set) var cancelledTasksEnteringStart = 0
    private(set) var completedStarts = 0
    private var generation = 0
    private var starts = [Int: CheckedContinuation<Void, Never>]()

    init() { Self.latest = self }

    func start() async throws {
        // Count entry before checking cancellation so the test can detect a
        // stale AutoSync task even if the real capture also guards itself.
        startCalls += 1
        if Task.isCancelled { cancelledTasksEnteringStart += 1 }
        generation += 1
        let ticket = generation
        let call = startCalls
        isCapturing = false
        await withCheckedContinuation { starts[call] = $0 }
        completedStarts += 1
        guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
        isCapturing = true
    }

    func cancel() {
        generation += 1
        isCapturing = false
    }

    func completeStart(_ call: Int) {
        guard let continuation = starts.removeValue(forKey: call) else {
            preconditionFailure("Capture start \(call) is not suspended")
        }
        continuation.resume()
    }

    func fail(_ message: String) {
        error = message
        cancel()
        onFailure?(message)
    }
}

@main
@MainActor
struct RecordingAutoSyncChecks {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    private static func configured(saved: Bool = false) -> (RecordingAutoSync, PlaybackAudioCapture) {
        let sync = RecordingAutoSync(persistenceEnabled: false)
        sync.configure(identity: "song/video/score", referenceAttacks: [0, 0.6, 1.3, 2.1, 2.8, 3.5, 4.2, 5],
                       scale: 1, inferredOffset: 0, hasSavedAlignment: saved)
        return (sync, PlaybackAudioCapture.latest!)
    }

    private static func drainTasks() async {
        for _ in 0..<16 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }

    private static func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(predicate(), message)
    }

    static func main() async {
        // Cancel without yielding: the queued start task has not begun yet.
        do {
            let (sync, capture) = configured()
            var restarts = 0
            sync.onRestart = { restarts += 1 }
            sync.retry()
            sync.cancel()
            await drainTasks()
            check(capture.startCalls == 0, "Cancel before task execution must never enter capture.start")
            check(restarts == 0 && !sync.isAnalyzing && !capture.isCapturing,
                  "Cancel before startup must leave playback and capture stopped")
        }

        // A second attempt is queued before the cancelled first task can run.
        do {
            let (sync, capture) = configured()
            var restarts = 0
            sync.onRestart = { restarts += 1 }
            sync.retry()
            sync.cancel()
            sync.retry()
            await waitUntil("The replacement attempt never started") { capture.startCalls >= 1 }
            await drainTasks()
            check(capture.startCalls == 1 && capture.cancelledTasksEnteringStart == 0,
                  "A cancelled queued task must not enter capture or disrupt its replacement")
            capture.completeStart(1)
            await waitUntil("The replacement attempt never restarted playback") { restarts == 1 }
            check(sync.isAnalyzing && capture.isCapturing && sync.error == nil,
                  "The replacement attempt must remain active")
            sync.cancel()
        }

        // Release an old permission/start completion after a newer attempt has
        // already started playback. It must not clear or restart the new one.
        do {
            let (sync, capture) = configured()
            var restarts = 0
            sync.onRestart = { restarts += 1 }
            sync.retry()
            await waitUntil("First startup never suspended") { capture.startCalls == 1 }
            sync.cancel()
            sync.retry()
            await waitUntil("Second startup never suspended") { capture.startCalls == 2 }
            capture.completeStart(2)
            await waitUntil("Second attempt did not restart playback") { restarts == 1 }
            capture.completeStart(1)
            await waitUntil("Old startup did not finish") { capture.completedStarts == 2 }
            await drainTasks()
            check(restarts == 1, "An old capture completion must not restart playback again")
            check(sync.isAnalyzing && capture.isCapturing && sync.error == nil,
                  "An old cancelled startup must not cancel or fail a newer attempt")
            sync.cancel()
        }

        // Simulate Stop matching, a selection change, or an explicit pause
        // while the OS capture request is still awaiting completion.
        do {
            let (sync, capture) = configured()
            var restarts = 0
            sync.onRestart = { restarts += 1 }
            sync.retry()
            await waitUntil("Startup never suspended") { capture.startCalls == 1 }
            sync.cancel()
            capture.completeStart(1)
            await waitUntil("Cancelled startup did not finish") { capture.completedStarts == 1 }
            await drainTasks()
            check(restarts == 0, "A late capture permission/start completion must never resume cancelled playback")
            check(!sync.isAnalyzing && !capture.isCapturing && sync.error == nil,
                  "Cancellation must remain final after the asynchronous startup returns")
        }

        do {
            let (sync, capture) = configured(saved: true)
            for position in [0.0, 0.05, 0.2, 0.35] {
                sync.observe(position: position, rate: 1, fresh: true, revision: 1)
            }
            await drainTasks()
            check(capture.startCalls == 0 && !sync.isAnalyzing,
                  "Playing an already aligned video must not automatically start capture")
            check(sync.status == "Using the saved alignment for this video.",
                  "Saved alignment status must survive ordinary playback observations")
        }

        // A slow-loading recording may first expose a usable clock after the
        // opening half-second. It still needs automatic matching, but a stale
        // snapshot or ordinary mid-song playback must not initiate capture.
        do {
            let (sync, capture) = configured()
            sync.observe(position: 20, rate: 1, fresh: true, revision: 1)
            sync.observe(position: 1.2, rate: 1, fresh: false, revision: 1)
            await drainTasks()
            check(capture.startCalls == 0, "Stale or mid-song playback must not start capture")
            sync.observe(position: 1.2, rate: 1, fresh: true, revision: 1)
            await waitUntil("Delayed first playback did not begin matching") { capture.startCalls == 1 }
            check(sync.isAnalyzing, "A delayed fresh startup must still auto-match")
            sync.cancel()
            capture.completeStart(1)
            await waitUntil("Cancelled delayed startup did not finish") { capture.completedStarts == 1 }
        }

        // Internal seek/play resets are allowed before listening; a subsequent
        // revision must close the active epoch and stop capture immediately.
        do {
            let (sync, capture) = configured()
            var restarts = 0
            sync.onRestart = {
                sync.playbackClockDidReset()
                restarts += 1
            }
            sync.retry()
            await waitUntil("Startup never suspended") { capture.startCalls == 1 }
            capture.completeStart(1)
            await waitUntil("Playback did not restart") { restarts == 1 }
            check(sync.isAnalyzing && sync.error == nil, "The intentional startup seek must not cancel matching")
            sync.observe(position: 0.02, rate: 1, fresh: true, revision: 7)
            sync.playbackClockDidReset()
            check(!sync.isAnalyzing && !capture.isCapturing && sync.error != nil,
                  "A clock reset after listening begins must cancel capture and reject the old epoch")
            sync.onRestart = nil
        }

        do {
            let (sync, capture) = configured()
            var restarts = 0
            sync.onRestart = { restarts += 1 }
            sync.retry()
            await waitUntil("Startup never suspended") { capture.startCalls == 1 }
            capture.completeStart(1)
            await waitUntil("Playback did not restart") { restarts == 1 }
            capture.fail("Capture ended unexpectedly")
            check(!sync.isAnalyzing && !capture.isCapturing && sync.error == "Capture ended unexpectedly",
                  "A capture failure must finish analysis and surface its error")
            sync.observe(position: 0.05, rate: 1, fresh: true, revision: 1)
            await drainTasks()
            check(capture.startCalls == 1 && restarts == 1,
                  "A failed attempt must not immediately auto-retry on the next playback tick")
        }

        print("Recording auto-sync lifecycle checks passed: \(checks), using fake capture only; no devices, audio, permissions or preferences.")
    }
}
