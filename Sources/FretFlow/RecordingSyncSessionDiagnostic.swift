import AppKit
import Foundation
import SwiftUI

/// Explicit end-to-end diagnostic of the production practice session. It uses
/// the requested song's current linked video and retains a successful real
/// calibration. Manual calibrations and the user's enable preference are never
/// changed. Only timing/state metadata is saved; no PCM, microphone or images.
@MainActor
final class RecordingSyncSessionDiagnostic {
    private let output: URL
    private let requestedSongTitle: String
    private let session = PracticeSession()
    private var window: NSWindow?
    private var timer: Timer?
    private var startedAt = 0.0
    private var requestedAt: Double?
    private var finished = false
    private var requestedMatch = false
    private var matchTrigger = "none"
    private var observedAnalyzing = false
    private var restartCount = 0
    private var capturedMatch: RecordingOnsetMatch?
    private var identityKey: String?
    private var songID = ""
    private var videoID = ""
    private var settingBefore: RecordingSyncSetting?
    private var initialFirstClick: Double?
    private var initialFirstMeasure: Double?
    private var matchReceivedAt: Double?
    private var preciseClockTicksDuringAnalysis = 0
    private var clockSourcesDuringAnalysis = Set<String>()
    private var matchHadPreciseClock = false
    private var matchClockSource = "none"
    private var phaseEvents = [[String: Any]]()
    private var failures = [String]()

    init(output: URL, songTitle: String = "Electric Sunrise") {
        self.output = output
        requestedSongTitle = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func run() {
        startedAt = ProcessInfo.processInfo.systemUptime
        guard !session.isSmokeTest else {
            failures.append("The recording-sync check cannot run with --smoke-test; it must use the real saved library.")
            finish(reason: "incompatibleMode")
            return
        }
        guard let song = session.library.songs.first(where: {
            $0.kind == "gp" && $0.title.compare(requestedSongTitle, options: .caseInsensitive) == .orderedSame
        }) else {
            failures.append("\(requestedSongTitle) is not present as a Guitar Pro score in the saved library.")
            finish(reason: "missingScore")
            return
        }
        songID = song.id
        guard let linkedVideo = session.library.videoLinks[song.id], !linkedVideo.isEmpty else {
            failures.append("\(requestedSongTitle) has no linked video. The diagnostic does not replace saved video links.")
            finish(reason: "missingVideo")
            return
        }
        videoID = linkedVideo
        guard let key = session.recordingSync.key(songID: song.id, videoID: linkedVideo,
                                                  scoreURL: session.library.url(for: song)) else {
            failures.append("The current score could not be fingerprinted for a recording-specific calibration.")
            finish(reason: "missingIdentity")
            return
        }
        identityKey = key
        settingBefore = session.recordingSync.setting(for: key)
        guard settingBefore?.source != "manual" else {
            finish(reason: "manualAlignmentPreserved", skipped: true)
            return
        }
        guard session.autoSync.enabled else {
            finish(reason: "automaticMatchingDisabled", skipped: true)
            return
        }

        // Select before start so the real loader restores this recording's
        // alignment and wires all production callbacks exactly once.
        session.selectedID = song.id
        let view = PracticeView(session: session, score: session.score, player: session.player)
            .frame(minWidth: 950, minHeight: 730)
            .tint(Color(red: 0.43, green: 0.35, blue: 0.88))
        let testWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 900),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        testWindow.title = "FretFlow — checking recording sync"
        testWindow.contentMinSize = NSSize(width: 950, height: 730)
        testWindow.contentView = NSHostingView(rootView: view)
        testWindow.isReleasedWhenClosed = false
        testWindow.center()
        testWindow.makeKeyAndOrderFront(nil)
        window = testWindow
        NSApp.activate(ignoringOtherApps: true)
        session.start()

        // Observe the production callbacks without replacing their work. A
        // pre-existing automatic setting must not count as a new test result.
        let productionClockReset = session.player.onClockReset
        session.player.onClockReset = { [weak self] in
            if let self, !self.finished { self.event("productionClockResetBefore") }
            productionClockReset?()
            if let self, !self.finished { self.event("productionClockResetAfter") }
        }
        let productionRestart = session.autoSync.onRestart
        session.autoSync.onRestart = { [weak self] in
            if let self, !self.finished {
                self.restartCount += 1
                self.event("productionRestart")
            }
            productionRestart?()
        }
        let productionMatch = session.autoSync.onMatch
        session.autoSync.onMatch = { [weak self] key, match in
            productionMatch?(key, match)
            guard let self, !self.finished, self.identityKey == key else { return }
            self.capturedMatch = match
            self.matchReceivedAt = ProcessInfo.processInfo.systemUptime
            self.matchHadPreciseClock = self.session.player.hasPrecisePlaybackClock
            self.matchClockSource = self.session.player.clockSourceName
            self.event("productionMatch")
        }
        event("loadingProductionSession")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func event(_ phase: String) {
        phaseEvents.append(["phase": phase, "wall": ProcessInfo.processInfo.systemUptime - startedAt,
                            "position": session.player.position, "analyzing": session.autoSync.isAnalyzing,
                            "interpolatedPosition": session.player.interpolatedPosition,
                            "clockRevision": session.player.clockRevision,
                            "playing": session.player.isPlaying,
                            "clockSource": session.player.clockSourceName,
                            "preciseClock": session.player.hasPrecisePlaybackClock,
                            "freshClock": session.player.hasFreshPlaybackClock,
                            "matchingStatus": session.autoSync.status,
                            "matchingError": session.autoSync.error ?? ""])
    }

    private func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - startedAt >= 90 {
            failures.append("The production recording-sync check timed out: \(session.autoSync.status) / \(session.player.status)")
            finish(reason: "timeout")
            return
        }
        if let error = session.score.error {
            failures.append(error)
            finish(reason: "scoreError")
            return
        }
        if requestedMatch, let error = session.autoSync.error {
            failures.append(error)
            finish(reason: "matchingError")
            return
        }
        if !requestedMatch, session.score.isLoaded, session.player.isReady {
            guard !session.score.referenceAttacks.isEmpty else {
                failures.append("The loaded score supplied no reference attacks to the production matcher.")
                finish(reason: "missingReferenceAttacks")
                return
            }
            guard session.syncSource != "manual", session.autoSync.enabled else {
                finish(reason: session.syncSource == "manual" ? "manualAlignmentPreserved" : "automaticMatchingDisabled", skipped: true)
                return
            }
            initialFirstClick = session.score.clicks.first?.time
            initialFirstMeasure = session.score.measures.first?.start
            requestedMatch = true
            requestedAt = now
            if settingBefore == nil {
                // Exercise the ordinary first-play trigger for a new recording.
                // Analysis may begin only after the player confirms its clock.
                matchTrigger = "firstPlay"
                event("requestFirstPlay")
                session.player.play()
            } else {
                matchTrigger = "retry"
                event("requestProductionMatch")
                session.autoSync.retry()
            }
            observedAnalyzing = session.autoSync.isAnalyzing
            if matchTrigger == "retry", !observedAnalyzing {
                failures.append("The production automatic matcher did not enter its analysis state.")
                finish(reason: "analysisDidNotStart")
            }
            return
        }
        if session.autoSync.isAnalyzing {
            if !observedAnalyzing { event("automaticAnalysisStarted") }
            observedAnalyzing = true
            clockSourcesDuringAnalysis.insert(session.player.clockSourceName)
            if session.player.hasPrecisePlaybackClock { preciseClockTicksDuringAnalysis += 1 }
        }
        guard requestedMatch else { return }
        guard observedAnalyzing else {
            if let requestedAt, now - requestedAt >= 15 {
                failures.append("Ordinary first playback did not start automatic matching within 15 seconds: \(session.autoSync.status) / \(session.player.status)")
                finish(reason: "analysisDidNotStart")
            }
            return
        }
        if let match = capturedMatch {
            let adjustment = session.syncAdjustment
            let gridUpdated = session.score.isLoaded && !session.score.clicks.isEmpty && !session.score.measures.isEmpty
                && abs(session.score.alignmentAdjustment - adjustment) < 0.000_001
                && abs(session.score.alignmentOffset - session.score.inferredAlignmentOffset - adjustment) < 0.000_001
            let saved = session.recordingSync.setting(for: identityKey)
            let stored = saved?.source == "automatic" && abs((saved?.adjustment ?? .infinity) - adjustment) < 0.000_001
            if !session.autoSync.isAnalyzing, session.syncSource == "automatic", gridUpdated, stored,
               abs(adjustment - match.adjustment) <= 0.000_501 {
                event("productionGridAndStoreUpdated")
                finish(reason: "matched")
            } else if let matchReceivedAt, now - matchReceivedAt > 10 {
                failures.append("A match was produced, but the production saved setting and score/click timeline did not converge.")
                finish(reason: "alignmentDidNotApply")
            }
        } else if !session.autoSync.isAnalyzing {
            failures.append("Matching stopped before the production matcher accepted a new result: \(session.autoSync.status)")
            finish(reason: "analysisStopped")
        }
    }

    private func finish(reason: String, skipped: Bool = false) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        let beforePauseStatus = session.autoSync.status
        let beforePauseError = session.autoSync.error ?? ""
        let analysisStoppedBeforeCleanup = !session.autoSync.isAnalyzing
        let saved = session.recordingSync.setting(for: identityKey)
        let persisted = RecordingSyncStore().setting(for: identityKey)
        let persistedMatches = saved != nil && saved == persisted
        if reason == "matched", !persistedMatches { failures.append("The calibration could not be read back from saved preferences.") }
        let firstClick = session.score.clicks.first
        let firstMeasure = session.score.measures.first
        let clicksRespectStart = session.score.clicks.allSatisfy { $0.time + 0.000_001 >= max(0, session.score.alignmentOffset) }
        if reason == "matched", !clicksRespectStart { failures.append("The updated click grid contains a click before the aligned recording start.") }
        if reason == "matched", !matchHadPreciseClock || matchClockSource != "mediaElement" || preciseClockTicksDuringAnalysis == 0 {
            failures.append("The production match was not verified against a fresh media-element clock.")
        }
        let passed = reason == "matched" && failures.isEmpty
        var result: [String: Any] = [
            "passed": passed, "skipped": skipped, "reason": reason, "failures": failures,
            "elapsed": ProcessInfo.processInfo.systemUptime - startedAt,
            "songID": songID, "videoID": videoID, "scoreTitle": session.score.scoreTitle,
            "requestedSongTitle": requestedSongTitle,
            "automaticMatchingEnabled": session.autoSync.enabled,
            "requestedProductionMatch": requestedMatch, "observedAnalyzing": observedAnalyzing,
            "matchTrigger": matchTrigger,
            "productionRestartCount": restartCount, "newMatchReceived": capturedMatch != nil,
            "source": session.syncSource ?? "none", "adjustment": session.syncAdjustment,
            "inferredOffset": session.score.inferredAlignmentOffset, "effectiveOffset": session.score.alignmentOffset,
            "alignmentScale": session.score.alignmentScale, "gridAdjustment": session.score.alignmentAdjustment,
            "clickCount": session.score.clicks.count, "measureCount": session.score.measures.count,
            "referenceAttackCount": session.score.referenceAttacks.count,
            "clicksRespectAlignedStart": clicksRespectStart, "persistedSettingMatches": persistedMatches,
            "analysisStoppedBeforeCleanup": analysisStoppedBeforeCleanup,
            "matchingStatus": beforePauseStatus, "matchingError": beforePauseError,
            "matcherDiagnostics": session.autoSync.lastDiagnostics,
            "playerStatus": session.player.status, "playerPosition": session.player.position,
            "playerRate": session.player.rate, "scoreError": session.score.error ?? "",
            "clockSource": session.player.clockSourceName,
            "hasPrecisePlaybackClock": session.player.hasPrecisePlaybackClock,
            "preciseClockTicksDuringAnalysis": preciseClockTicksDuringAnalysis,
            "clockSourcesDuringAnalysis": clockSourcesDuringAnalysis.sorted(),
            "matchHadPreciseClock": matchHadPreciseClock, "matchClockSource": matchClockSource,
            "applicationActive": NSApp.isActive, "windowVisible": window?.isVisible ?? false,
            "audioSaved": false, "microphoneUsed": false, "imagesCaptured": false,
            "phases": phaseEvents
        ]
        result["settingBefore"] = settingBefore.map { ["source": $0.source, "adjustment": $0.adjustment] as [String: Any] } ?? [:]
        result["savedSetting"] = saved.map { ["source": $0.source, "adjustment": $0.adjustment,
                                               "confidence": $0.confidence ?? 0] as [String: Any] } ?? [:]
        result["initialFirstClick"] = initialFirstClick.map { $0 as Any } ?? NSNull()
        result["initialFirstMeasureStart"] = initialFirstMeasure.map { $0 as Any } ?? NSNull()
        result["firstClick"] = firstClick.map { ["time": $0.time, "barIndex": $0.barIndex,
                                                "beatIndex": $0.beatIndex] as [String: Any] } ?? [:]
        result["firstMeasure"] = firstMeasure.map { ["start": $0.start, "end": $0.end,
                                                    "index": $0.index, "label": $0.label] as [String: Any] } ?? [:]
        if let capturedMatch {
            result["match"] = ["offset": capturedMatch.offset, "adjustment": capturedMatch.adjustment,
                               "confidence": capturedMatch.confidence, "matchedAttackCount": capturedMatch.matchedAttackCount,
                               "observedAttackCount": capturedMatch.observedAttackCount] as [String: Any]
        }
        if let requestedAt { result["matchingSeconds"] = ProcessInfo.processInfo.systemUptime - requestedAt }
        session.player.pause()
        session.autoSync.cancel()
        session.clickTrack.suspend()
        result["clickStoppedAfterCleanup"] = !session.clickTrack.isRunning
        result["matchingStoppedAfterCleanup"] = !session.autoSync.isAnalyzing
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
            print(String(data: data, encoding: .utf8) ?? "Recording-sync result saved")
        } catch { print("Could not save recording-sync diagnostic: \(error.localizedDescription)") }
        NSApp.terminate(nil)
    }
}
