// Opt-in transport/audio integration check. Compile with -D CLICK_TRACK_AUDIO_CHECKS
// and Sources/FretFlow/{PlaybackClock,YouTubeController,ClickTrack}.swift.
// YouTube is muted; the click mixer is muted before starting its cold engine.
// Observes only this test's generated clicks. No microphone, loopback or saved audio.
import AppKit
import AVFoundation
import Foundation
import WebKit

private final class LiveClickMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var activeSamples = 0
    private var pulseStarts = [Double]()
    private var lastActiveTime: Double?

    func receive(_ samples: [Float], rate: Double, host: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        let start = AVAudioTime.seconds(forHostTime: host)
        for (index, sample) in samples.enumerated() where abs(sample) > 0.004 {
            let time = start + Double(index) / rate
            activeSamples += 1
            if lastActiveTime == nil || time - lastActiveTime! > 0.025 { pulseStarts.append(time) }
            lastActiveTime = time
        }
    }

    func snapshot() -> (buffers: Int, activeSamples: Int, pulseStarts: [Double]) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, activeSamples, pulseStarts)
    }
}

@main struct YouTubeClickLiveChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = LiveClickDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class LiveClickDelegate: NSObject, NSApplicationDelegate {
    private var controller: YouTubeController!
    private let track = ClickTrackController()
    private let capture = LiveClickMetrics()
    private var window: NSWindow!
    private var timer: Timer?
    private let start = ProcessInfo.processInfo.systemUptime
    private var stage = 0
    private var stageStart = ProcessInfo.processInfo.systemUptime
    private var stagePulseCount = 0
    private var pausePosition = 0.0
    private var finished = false
    private var ready = false
    private var coldEngine = false
    private var normalPlayback = false
    private var halfSpeed = false
    private var seeked = false
    private var resumed = false
    private var pausedImmediately = false
    private var freshTicks = 0
    private var runningTicks = 0
    private var coldStartDuration = 0.0
    private var maximumUpdateDuration = 0.0
    private var resetEvents = [[String: Any]]()
    private var phaseEvents = [[String: Any]]()
    private var slowUpdates = [[String: Any]]()
    private var failures = [String]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        track.verifySilently { [capture] in capture.receive($0, rate: $1, host: $2) }
        track.volume = 1
        track.setEvents((0..<108).map { index in
            ScoreClick(time: Double(index) * 0.5, barIndex: index / 4,
                       measureIndex: index / 4, beatIndex: index % 4,
                       numerator: 4, denominator: 4, bpm: 120, accent: index % 4 == 0)
        })
        track.enabled = true
        coldEngine = !track.verificationHasEngine
        controller = YouTubeController()
        controller.onClockReset = { [weak self] in
            guard let self else { return }
            self.track.stop()
            if self.resetEvents.count < 2_000 {
                self.resetEvents.append(["wall": ProcessInfo.processInfo.systemUptime - self.start,
                    "position": self.controller.position, "revision": self.controller.clockRevision,
                    "stage": self.stage, "playing": self.controller.isPlaying,
                    "fresh": self.controller.hasFreshPlaybackClock])
            }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FretFlow — muted click synchronization check"
        window.contentView = controller.webView
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.cue(videoID: "RLytwCPVpSk")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !failures.isEmpty { exit(1) }
    }

    private func beginStage(_ next: Int) {
        stage = next
        stageStart = ProcessInfo.processInfo.systemUptime
        stagePulseCount = capture.snapshot().pulseStarts.count
        phaseEvents.append(["stage": next, "wall": stageStart - start,
                            "position": controller.position, "pulses": stagePulseCount])
    }

    private func tick() {
        guard !finished else { return }
        let tickStart = ProcessInfo.processInfo.systemUptime
        let fresh = controller.hasFreshPlaybackClock
        let hadEngine = track.verificationHasEngine
        // Match PracticeSession: the same interpolated content position,
        // freshness gate, revision callback and 50 ms common-mode timer.
        track.update(position: controller.interpolatedPosition, isPlaying: fresh,
                     rate: controller.rate, discontinuity: controller.clockRevision)
        let updateDuration = ProcessInfo.processInfo.systemUptime - tickStart
        maximumUpdateDuration = max(maximumUpdateDuration, updateDuration)
        if updateDuration > 0.1 && slowUpdates.count < 200 {
            slowUpdates.append(["wall": tickStart - start, "milliseconds": updateDuration * 1_000,
                                "hadEngine": hadEngine, "fresh": fresh, "stage": stage,
                                "position": controller.position, "revision": controller.clockRevision,
                                "applicationActive": NSApp.isActive,
                                "windowVisible": window.occlusionState.contains(.visible)])
        }
        if !hadEngine && track.verificationHasEngine { coldStartDuration = updateDuration }
        if fresh { freshTicks += 1 }
        if track.isRunning { runningTicks += 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - stageStart
        let pulses = capture.snapshot().pulseStarts.count - stagePulseCount
        if let error = track.error { failures.append(error); finish(); return }
        switch stage {
        case 0 where controller.isReady:
            ready = true
            beginStage(1)
            controller.webView.evaluateJavaScript("player.mute(); player.playVideo();", completionHandler: nil)
        case 1 where fresh && elapsed > 2 && pulses >= 3:
            normalPlayback = true
            beginStage(2)
            controller.setRate(0.5)
        case 2 where fresh && abs(controller.rate - 0.5) < 0.001 && elapsed > 2.5 && pulses >= 3:
            halfSpeed = true
            beginStage(3)
            controller.seek(to: 12)
        case 3 where fresh && controller.position >= 12.75 && elapsed > 2 && pulses >= 2:
            seeked = true
            pausePosition = controller.position
            controller.pause()
            pausedImmediately = !controller.hasFreshPlaybackClock && !track.isRunning
            if !pausedImmediately { failures.append("Pause did not immediately cancel clock and queued-click state") }
            beginStage(4)
        case 4 where !controller.isPlaying && elapsed > 0.4:
            beginStage(5)
            controller.play()
        case 5 where fresh && controller.position > pausePosition + 0.75 && elapsed > 2 && pulses >= 2:
            resumed = true
            finish()
            return
        default: break
        }
        if ProcessInfo.processInfo.systemUptime - start > 45 {
            failures.append("Timed out in stage \(stage): \(controller.status)")
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        controller.pause()
        if !coldEngine { failures.append("The engine was prewarmed before playback") }
        if !normalPlayback { failures.append("Cold-start live playback did not render at least three click pulses") }
        if !halfSpeed { failures.append("Accepted half-speed playback did not render continuing click pulses") }
        if !seeked { failures.append("Post-seek live playback did not render continuing click pulses") }
        if !resumed { failures.append("Playback did not render continuing click pulses after pause and resume") }
        if !pausedImmediately { failures.append("Immediate pause cancellation was not verified") }
        let captureState = capture.snapshot()
        let result: [String: Any] = [
            "passed": failures.isEmpty, "ready": ready, "coldEngine": coldEngine,
            "normalPlaybackClicks": normalPlayback, "halfSpeedClicks": halfSpeed,
            "seekClicks": seeked, "resumeClicks": resumed, "pauseCancelsImmediately": pausedImmediately,
            "freshTicks": freshTicks, "runningTicks": runningTicks,
            "scheduledClicks": track.verificationScheduledCount,
            "renderedBuffers": captureState.buffers, "generatedActiveSamples": captureState.activeSamples,
            "renderedPulses": captureState.pulseStarts.count,
            "coldStartMilliseconds": coldStartDuration * 1_000,
            "maximumUpdateMilliseconds": maximumUpdateDuration * 1_000,
            "reportedOutputLatencyMilliseconds": track.verificationOutputLatency * 1_000,
            "elapsed": ProcessInfo.processInfo.systemUptime - start,
            "position": controller.position, "rate": controller.rate, "status": controller.status,
            "failures": failures, "phases": phaseEvents, "clockResets": resetEvents,
            "slowUpdates": slowUpdates, "applicationActive": NSApp.isActive,
            "windowVisible": window.occlusionState.contains(.visible),
            "audio": "Both sources muted; observed only generated click samples; no audio saved"
        ]
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/live-click-check")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("youtube-click.json"))
            print(String(data: data, encoding: .utf8) ?? "Result saved")
        } catch { print("Could not save live click check: \(error)") }
        controller.clear()
        NSApp.terminate(nil)
    }
}
