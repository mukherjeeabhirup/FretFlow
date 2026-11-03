import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Opt-in integration check under FretFlow's own bundle identity. The only
/// captured values retained here are short energy/timestamp summaries, not PCM.
/// Unlike the microphone diagnostic, this explicitly requested mode may show
/// macOS's screen/system-audio permission prompt and plays its YouTube video.
@MainActor
final class PlaybackCaptureDiagnostic {
    private let output: URL
    private let player = YouTubeController()
    private let capture = PlaybackAudioCapture()
    private var window: NSWindow?
    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private var startedAt = 0.0
    private var captureStartedAt: Double?
    private var toneStartedAt: Double?
    private var toneEngine: AVAudioEngine?
    private var toneNode: AVAudioPlayerNode?
    private var playbackStartedAt: Double?
    private var requestedPlayback = false
    private var startingCapture = false
    private var finished = false
    private var permissionBefore = false
    private var captureStarted = false
    private var freshClockTicks = 0
    private var preciseClockTicks = 0
    private var playingTicks = 0
    private var windows = 0
    private var activeWindows = 0
    private var silentBaselineWindows = 0
    private var activeBaselineWindows = 0
    private var nativeToneActiveWindows = 0
    private var videoActiveWindows = 0
    private var nativeToneMaximumRMS = 0.0
    private var videoMaximumRMS = 0.0
    private var playerAudioState = [String: Any]()
    private var audioProcesses = [[String: Any]]()
    private var lastStateQuery = 0.0
    private var maximumRMS = 0.0
    private var maximumPeak = 0.0
    private var firstWindowTime: Double?
    private var lastWindowTime: Double?
    private var firstActiveTime: Double?
    private var firstActiveMediaEstimate: Double?
    private var firstActiveCalibratedMediaTime: Double?
    private var timestampBacksteps = 0
    private var clock = RecordingPlaybackClock()
    private var pendingWindows = [PlaybackAudioWindow]()
    private var firstMappedMediaTime: Double?
    private var lastMappedMediaTime: Double?
    private var matcher: RecordingOnsetMatcher?
    private var match: RecordingOnsetMatch?
    private let referenceAttackCount: Int
    private var mappedWindows = 0
    private var unmappedWindows = 0
    private var failures = [String]()
    private var stageEvents = [[String: Any]]()

    init(output: URL, referenceAttacks: [Double] = [], alignmentScale: Double = 1, inferredOffset: Double = 0) {
        self.output = output
        referenceAttackCount = referenceAttacks.count
        if !referenceAttacks.isEmpty {
            matcher = RecordingOnsetMatcher(referenceAttacks: referenceAttacks,
                                             alignmentScale: alignmentScale, inferredOffset: inferredOffset)
        }
    }

    func run() {
        startedAt = ProcessInfo.processInfo.systemUptime
        permissionBefore = PlaybackAudioCapture.hasScreenCapturePermission
        let view = player.webView
        let testWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        testWindow.title = "FretFlow — checking its own playback audio"
        testWindow.contentView = view
        testWindow.isReleasedWhenClosed = false
        testWindow.center()
        testWindow.makeKeyAndOrderFront(nil)
        window = testWindow
        NSApp.activate(ignoringOtherApps: true)
        capture.onWindow = { [weak self] in self?.receive($0) }
        capture.onFailure = { [weak self] message in
            guard let self, !self.finished else { return }
            self.failures.append(message)
            self.finish(reason: "captureError")
        }
        player.onClockReset = { [weak self] in
            guard let self, !self.finished else { return }
            self.event("playbackClockReset")
            if self.mappedWindows > 0 {
                // Match production's one-epoch rule. Feeding a newly mapped
                // epoch into an existing matcher would conceal a transport
                // discontinuity as an audio-onset/backward-time problem.
                if self.match != nil { self.finish(reason: "matched") }
                else {
                    self.failures.append("The playback clock changed during continuous audio analysis.")
                    self.finish(reason: "clockResetDuringPlayback")
                }
                return
            }
            self.clock.reset()
            self.unmappedWindows += self.pendingWindows.count
            self.pendingWindows.removeAll(keepingCapacity: true)
        }
        player.cue(videoID: "Rv_a6rlRjZk")
        event("loadingVideo")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func event(_ stage: String) {
        stageEvents.append(["stage": stage, "wall": ProcessInfo.processInfo.systemUptime - startedAt,
                            "position": player.position, "captureWindows": windows])
    }

    private func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - startedAt >= 90 {
            failures.append("The playback-audio check timed out: \(player.status)")
            finish(reason: "timeout")
            return
        }
        if player.isReady && !startingCapture && !captureStarted {
            startingCapture = true
            window?.title = "FretFlow — allow playback-audio access if macOS asks"
            event("startingCapture")
            startTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.capture.start()
                    guard !self.finished, !Task.isCancelled else {
                        await self.capture.stop()
                        return
                    }
                    self.captureStarted = true
                    self.captureStartedAt = ProcessInfo.processInfo.systemUptime
                    self.event("capturingSilentBaseline")
                    self.window?.title = "FretFlow — checking isolated audio before playback"
                } catch {
                    guard !self.finished else { return }
                    self.failures.append(self.capture.error ?? error.localizedDescription)
                    self.finish(reason: "startFailed")
                }
            }
        }
        // A short pre-playback baseline helps diagnose an incorrect application
        // filter. It does not intentionally play or inspect any other app.
        if let captureStartedAt, toneStartedAt == nil, now - captureStartedAt >= 0.6 {
            do {
                try startNativeTone()
                toneStartedAt = ProcessInfo.processInfo.systemUptime
                event("nativeToneCalibration")
            } catch {
                failures.append("Native-tone calibration could not start: \(error.localizedDescription)")
                finish(reason: "nativeToneFailed")
                return
            }
        }
        if let toneStartedAt, !requestedPlayback, now - toneStartedAt >= 0.9 {
            toneNode?.stop()
            toneEngine?.stop()
            requestedPlayback = true
            window?.title = "FretFlow — Electric Sunrise playback check (12 seconds)"
            event("startingPlayback")
            // This diagnostic intentionally needs an audible source. It never
            // changes macOS volume, the library, or the click-track preference.
            player.webView.evaluateJavaScript("player.unMute(); player.playVideo();", completionHandler: nil)
        }
        if player.isPlaying { playingTicks += 1 }
        if requestedPlayback && now - lastStateQuery >= 1 {
            lastStateQuery = now
            player.webView.evaluateJavaScript("({muted: player.isMuted(), volume: player.getVolume(), state: player.getPlayerState(), position: player.getCurrentTime()})") { [weak self] value, _ in
                guard let self, !self.finished, let state = value as? [String: Any] else { return }
                self.playerAudioState = state
            }
            audioProcesses = Self.audioProcessMetadata()
        }
        if player.hasFreshPlaybackClock { freshClockTicks += 1 }
        if player.hasPrecisePlaybackClock {
            preciseClockTicks += 1
            clock.observe(position: player.interpolatedPosition, rate: player.rate,
                          host: now, revision: player.clockRevision)
            if playbackStartedAt == nil {
                playbackStartedAt = now
                event("freshPlayback")
            }
            if clock.isReady { drainWindows(now: now) }
        }
        if match != nil { finish(reason: "matched") }
        else if let playbackStartedAt, now - playbackStartedAt >= 12 { finish(reason: "completed") }
    }

    private func receive(_ window: PlaybackAudioWindow) {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        windows += 1
        maximumRMS = max(maximumRMS, window.rms)
        maximumPeak = max(maximumPeak, window.peak)
        if firstWindowTime == nil { firstWindowTime = window.hostTime }
        if let lastWindowTime, window.hostTime < lastWindowTime - 0.001 { timestampBacksteps += 1 }
        lastWindowTime = window.hostTime
        let active = window.rms > 0.0001 && window.peak > 0.0002
        if active {
            activeWindows += 1
            if requestedPlayback {
                videoActiveWindows += 1
                videoMaximumRMS = max(videoMaximumRMS, window.rms)
            } else if toneStartedAt != nil {
                nativeToneActiveWindows += 1
                nativeToneMaximumRMS = max(nativeToneMaximumRMS, window.rms)
            }
            if requestedPlayback && firstActiveTime == nil {
                firstActiveTime = window.hostTime
                if player.hasPrecisePlaybackClock {
                    firstActiveMediaEstimate = player.interpolatedPosition + (window.hostTime - now) * player.rate
                }
            }
        }
        if toneStartedAt == nil {
            if active { activeBaselineWindows += 1 } else { silentBaselineWindows += 1 }
        }
        guard requestedPlayback, player.hasPrecisePlaybackClock,
              let playbackStartedAt, window.hostTime >= playbackStartedAt else {
            unmappedWindows += 1
            return
        }
        // Buffer only compact energy windows from confirmed video playback
        // while the shared clock settles; never retain PCM or calibration tone.
        pendingWindows.append(window)
        if pendingWindows.count > 300 || window.hostTime - pendingWindows[0].hostTime > 3 {
            failures.append("The video clock did not settle within the three-second envelope buffer.")
            finish(reason: "clockDidNotSettle")
            return
        }
        if clock.isReady { drainWindows(now: now) }
    }

    private func drainWindows(now: Double) {
        guard clock.isReady, !pendingWindows.isEmpty else { return }
        let ready = pendingWindows.sorted { $0.hostTime < $1.hostTime }
        pendingWindows.removeAll(keepingCapacity: true)
        for window in ready {
            if let mediaTime = clock.mediaTime(for: window.hostTime, now: now) {
                mappedWindows += 1
                if firstMappedMediaTime == nil { firstMappedMediaTime = mediaTime }
                lastMappedMediaTime = mediaTime
                if firstActiveCalibratedMediaTime == nil, window.rms > 0.0001, window.peak > 0.0002 {
                    firstActiveCalibratedMediaTime = mediaTime
                }
                if match == nil { match = matcher?.observe(time: mediaTime, rms: window.rms, peak: window.peak) }
            } else {
                unmappedWindows += 1
            }
        }
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        startTask?.cancel()
        let endClockSource = player.clockSourceName
        let preciseClockAtEnd = player.hasPrecisePlaybackClock
        player.pause()
        toneNode?.stop()
        toneEngine?.stop()
        event("stopping")
        let endPosition = player.position
        let endStatus = player.status
        let playbackElapsed = playbackStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        if match == nil { match = matcher?.finish() }
        if !captureStarted { failures.append("The application audio stream did not start.") }
        if videoActiveWindows < 20 { failures.append("Too few non-silent YouTube audio windows reached the FretFlow-only filter.") }
        if freshClockTicks < 20 { failures.append("A fresh YouTube playback clock was not observed for long enough.") }
        if preciseClockTicks < 20 { failures.append("The precise video-element clock was not observed for long enough.") }
        if timestampBacksteps > 0 { failures.append("Capture presentation timestamps moved backwards.") }
        if referenceAttackCount > 0 && match == nil { failures.append("No confident score-to-recording match was found in the captured interval.") }
        if reason == "completed" && playbackElapsed < 11.5 { failures.append("The playback interval was incomplete.") }
        window?.title = "FretFlow — finishing playback-audio check"
        Task { [self] in
            await capture.stop()
            player.clear()
            var result: [String: Any] = [
                "passed": failures.isEmpty && (reason == "completed" || reason == "matched"),
                "reason": reason, "bundleID": Bundle.main.bundleIdentifier ?? "",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "parentPID": getppid(),
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "permissionBefore": permissionBefore,
                "permissionAfter": PlaybackAudioCapture.hasScreenCapturePermission,
                "captureStarted": captureStarted, "captureStopped": !capture.isCapturing && !capture.isStarting,
                "videoID": "Rv_a6rlRjZk", "videoPosition": endPosition, "videoStatus": endStatus,
                "playingTicks": playingTicks, "freshClockTicks": freshClockTicks,
                "preciseClockTicks": preciseClockTicks, "preciseClockAtEnd": preciseClockAtEnd,
                "clockSourceName": endClockSource,
                "elapsed": ProcessInfo.processInfo.systemUptime - startedAt,
                "playbackSeconds": playbackElapsed,
                "audioWindowCount": windows, "nonzeroWindowCount": activeWindows,
                "silentBaselineWindows": silentBaselineWindows, "activeBaselineWindows": activeBaselineWindows,
                "nativeToneActiveWindows": nativeToneActiveWindows, "nativeToneMaximumRMS": nativeToneMaximumRMS,
                "videoActiveWindows": videoActiveWindows, "videoMaximumRMS": videoMaximumRMS,
                "playerAudioState": playerAudioState, "audioProcesses": audioProcesses,
                "maximumRMS": maximumRMS, "maximumPeak": maximumPeak,
                "timestampBacksteps": timestampBacksteps,
                "mappedWindows": mappedWindows, "unmappedWindows": unmappedWindows,
                "clockReady": clock.isReady,
                "calibrationSampleCount": clock.calibrationSampleCount,
                "referenceAttackCount": referenceAttackCount,
                "observedAttackCount": matcher?.observedAttackCount ?? 0,
                "analyzedDuration": matcher?.analyzedDuration ?? 0,
                "isDiscontinuous": matcher?.isDiscontinuous ?? false,
                "acceptedWindowCount": matcher?.acceptedWindowCount ?? 0,
                "ignoredWindowCount": matcher?.ignoredWindowCount ?? 0,
                "detectedOnsetTimes": matcher?.detectedOnsetTimes ?? [],
                "applicationActive": NSApp.isActive, "windowVisible": window?.isVisible ?? false,
                "filter": "Only the current FretFlow application PID; no screen or microphone output",
                "audioSaved": false, "imagesCaptured": false,
                "error": capture.error ?? "",
                "failures": failures, "stages": stageEvents
            ]
            if let firstWindowTime { result["firstWindowHostTime"] = firstWindowTime }
            if let responsible = Self.responsiblePID(ProcessInfo.processInfo.processIdentifier) {
                result["responsiblePID"] = responsible
            }
            if let lastWindowTime { result["lastWindowHostTime"] = lastWindowTime }
            if let firstActiveTime { result["firstActiveHostTime"] = firstActiveTime }
            if let firstActiveMediaEstimate { result["firstActiveMediaEstimate"] = firstActiveMediaEstimate }
            if let firstActiveCalibratedMediaTime { result["firstActiveCalibratedMediaTime"] = firstActiveCalibratedMediaTime }
            if let firstMappedMediaTime { result["firstMappedMediaTime"] = firstMappedMediaTime }
            if let lastMappedMediaTime { result["lastMappedMediaTime"] = lastMappedMediaTime }
            if let jitter = clock.calibrationJitter { result["calibrationJitter"] = jitter }
            if let correction = clock.calibrationCorrection { result["calibrationCorrection"] = correction }
            if let reason = matcher?.failureReason { result["failureReason"] = reason }
            if let anchor = matcher?.leadingAnchorTime { result["leadingAnchorTime"] = anchor }
            if let match {
                result["match"] = ["offset": match.offset, "adjustment": match.adjustment,
                    "confidence": match.confidence, "matchedAttackCount": match.matchedAttackCount,
                    "observedAttackCount": match.observedAttackCount]
            }
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            } catch { NSLog("FretFlow playback diagnostic could not save its report: %@", error.localizedDescription) }
            NSApp.terminate(nil)
        }
    }

    private func startNativeTone() throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let count = 16_800
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.floatChannelData![0]
        for i in 0..<count {
            let fade = min(1, min(Double(i), Double(count - i - 1)) / 240)
            samples[i] = Float(0.12 * fade * sin(2 * Double.pi * 1_000 * Double(i) / 48_000))
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        toneEngine = engine
        toneNode = node
        node.scheduleBuffer(buffer, completionHandler: nil)
        node.play()
    }

    /// Metadata only. This does not tap or capture any of the listed processes.
    /// Retain only FretFlow/WebKit entries relevant to audio attribution.
    private static func audioProcessMetadata() -> [[String: Any]] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size <= 1_000_000 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr else { return nil }
            let identifier = bundle.map { $0.takeRetainedValue() as String } ?? ""
            guard identifier.contains("FretFlow") || identifier.contains("fretflow") || identifier.contains("WebKit") else { return nil }
            func number(_ selector: AudioObjectPropertySelector) -> UInt32 {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                var value: UInt32 = 0
                var bytes = UInt32(MemoryLayout<UInt32>.size)
                _ = AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &value)
                return value
            }
            let pid = number(kAudioProcessPropertyPID)
            var entry: [String: Any] = ["objectID": object, "bundleID": identifier, "pid": pid,
                                       "runningOutput": number(kAudioProcessPropertyIsRunningOutput)]
            if let responsible = responsiblePID(pid_t(pid)) {
                entry["responsiblePID"] = responsible
                entry["belongsToCurrentApp"] = responsible == ProcessInfo.processInfo.processIdentifier
            }
            return entry
        }
    }

    /// Optional, read-only attribution diagnostic. This unsupported lookup is
    /// never used by the production capture filter or to grant capture access.
    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        let result = unsafeBitCast(symbol, to: Lookup.self)(pid)
        return result > 0 ? result : nil
    }
}
