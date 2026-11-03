import Foundation

/// Times are positions in the linked recording, before playback-speed changes.
struct ScoreClick: Codable, Equatable, Sendable {
    let time: Double
    let barIndex: Int
    let measureIndex: Int
    let beatIndex: Int
    let numerator: Int
    let denominator: Int
    let bpm: Double
    let accent: Bool
    var accentLevel: Int? = nil
    var grouping: String? = nil
    var isSubdivision: Bool? = nil

    /// Older score payloads contain only the bar-downbeat flag.
    var effectiveAccentLevel: Int { accentLevel ?? (accent ? 3 : 0) }

    var isValid: Bool {
        time.isFinite && time >= 0 && barIndex >= 0 && measureIndex >= 0
            && (1...128).contains(numerator) && beatIndex >= 0 && beatIndex < numerator
            && [1, 2, 4, 8, 16, 32, 64, 128, 256].contains(denominator)
            && bpm.isFinite && bpm > 0 && bpm <= 1_200
            && (0...3).contains(effectiveAccentLevel)
    }
}

struct ScheduledScoreClick: Equatable {
    let index: Int
    let click: ScoreClick
    /// Wall-clock delay, rather than score or recording seconds.
    let delay: Double
}

struct ClickTrackPlan {
    let resetAudio: Bool
    let clicks: [ScheduledScoreClick]
    let currentClick: ScoreClick?
    let active: Bool
}

/// The polling clock only fills a short queue. Audio timestamps, rather than
/// the poll callback, determine when a click is rendered. Pure for testing.
struct ClickTrackPlanner {
    static let lookAhead = 0.14
    static let maximumOutputLatency = 1.0
    private(set) var events = [ScoreClick]()
    private var nextIndex = 0
    private var wasActive = false
    private var lastPosition: Double?
    private var lastTime: TimeInterval?
    private var lastRate: Double?
    private var lastDiscontinuity: UInt64?
    private var lastLoopEnd: Double?
    private var lastOutputLatency: Double?

    static func safeOutputLatency(_ value: Double) -> Double {
        value.isFinite ? max(0, min(maximumOutputLatency, value)) : 0
    }

    @discardableResult
    mutating func setEvents(_ input: [ScoreClick]) -> Bool {
        stop()
        // Reject a corrupt grid rather than silently shifting or multiplying
        // its beats. A normal long score is far below this allocation limit.
        guard input.count <= 250_000,
              input.allSatisfy(\.isValid),
              zip(input, input.dropFirst()).allSatisfy({ $0.time < $1.time }) else {
            events = []
            return false
        }
        events = input
        return true
    }

    mutating func stop() {
        wasActive = false
        nextIndex = 0
        lastPosition = nil
        lastTime = nil
        lastRate = nil
        lastDiscontinuity = nil
        lastLoopEnd = nil
        lastOutputLatency = nil
    }

    private func firstIndex(atOrAfter position: Double) -> Int {
        var lower = 0, upper = events.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if events[middle].time < position { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    func click(at position: Double) -> ScoreClick? {
        guard position.isFinite, !events.isEmpty else { return nil }
        let next = firstIndex(atOrAfter: position)
        if next < events.count, abs(events[next].time - position) < 0.000_001 { return events[next] }
        return next > 0 ? events[next - 1] : events.first
    }

    mutating func update(position: Double, isPlaying: Bool, rate: Double,
                         enabled: Bool, now: TimeInterval, loopEnd: Double? = nil,
                         discontinuity: UInt64 = 0, outputLatency: Double = 0) -> ClickTrackPlan {
        let current = click(at: position)
        let validClock = position.isFinite && position >= 0 && now.isFinite
            && rate.isFinite && (0.125...4).contains(rate)
            && (loopEnd == nil || (loopEnd!.isFinite && loopEnd! >= 0))
        let active = enabled && isPlaying && validClock && !events.isEmpty
        guard active else {
            let reset = wasActive
            stop()
            return ClickTrackPlan(resetAudio: reset, clicks: [], currentClick: current, active: false)
        }

        // A node's render timestamp precedes audible presentation. Keep this
        // device delay in wall seconds, independent of song playback speed.
        let latency = Self.safeOutputLatency(outputLatency)
        var reset = !wasActive || lastRate != rate || lastDiscontinuity != discontinuity || lastLoopEnd != loopEnd
            || abs((lastOutputLatency ?? latency) - latency) > 0.001
        if let lastTime, let lastPosition {
            let elapsed = now - lastTime
            let prediction = lastPosition + elapsed * rate
            // Explicit seeks are identified by the host's revision. This also
            // catches embedded-player scrubs, a stalled clock, or waking up.
            if elapsed < 0 || elapsed > 0.35 || abs(position - prediction) > max(0.025, 0.10 * rate) {
                reset = true
            }
        }
        if reset { nextIndex = firstIndex(atOrAfter: position + rate * (latency - 0.002)) }
        wasActive = true
        lastTime = now
        lastPosition = position
        lastRate = rate
        lastDiscontinuity = discontinuity
        lastLoopEnd = loopEnd
        lastOutputLatency = latency

        var clicks = [ScheduledScoreClick]()
        let horizon = position + rate * (Self.lookAhead + latency)
        while nextIndex < events.count {
            let event = events[nextIndex]
            if event.time > horizon + 0.000_001 { break }
            if let loopEnd, event.time >= loopEnd - 0.000_001 { break }
            let index = nextIndex
            nextIndex += 1
            // Never emit a catch-up burst after a skipped frame or seek. The
            // tiny tolerance only protects a beat exactly on a float boundary.
            let delay = (event.time - position) / rate - latency
            if delay >= -0.002 {
                clicks.append(ScheduledScoreClick(index: index, click: event, delay: max(0, delay)))
            }
        }
        return ClickTrackPlan(resetAudio: reset, clicks: clicks, currentClick: current, active: true)
    }
}

/// Short synthesized clicks with enough body to hear over a backing track.
/// The envelope and peak gain stay below full scale, including at full volume.
enum ClickWaveform {
    static func samples(sampleRate: Double = 48_000, accent: Bool) -> [Float] {
        samples(sampleRate: sampleRate, accentLevel: accent ? 3 : 0)
    }

    static func samples(sampleRate: Double = 48_000, accentLevel: Int) -> [Float] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { return [] }
        guard (0...3).contains(accentLevel) else { return [] }
        let duration = 0.028
        let count = Int(sampleRate * duration)
        let frequency = [1_400.0, 1_750.0, 2_900.0, 2_200.0][accentLevel]
        let amplitude = [0.70, 0.83, 0.91, 0.95][accentLevel]
        return (0..<count).map { index in
            if index == 0 || index == count - 1 { return 0 }
            let time = Double(index) / sampleRate
            let attack = min(1, time / 0.0003)
            let release = min(1, (duration - time) / 0.003)
            let envelope = attack * release * exp(-time / 0.006)
            let tone = sin(2 * Double.pi * frequency * time)
                + 0.22 * sin(2 * Double.pi * frequency * 1.7 * time)
            return Float(amplitude * envelope * tone / 1.22)
        }
    }
}

#if !CLICK_TRACK_CHECKS
import AVFoundation
import Combine
import Darwin

@MainActor
final class ClickTrackController: ObservableObject {
    @Published var enabled = false {
        didSet {
            if !enabled { stop() }
            else { error = nil }
        }
    }
    @Published var volume: Double = 0.65 {
        didSet {
            let safe = volume.isFinite ? max(0, min(1, volume)) : 0.65
            if volume != safe { volume = safe }
            node?.volume = Float(safe)
            #if CLICK_TRACK_AUDIO_CHECKS
            if verificationReceiver != nil { return }
            #endif
            UserDefaults.standard.set(safe, forKey: "FretFlow.click.volume")
        }
    }
    @Published private(set) var currentClick: ScoreClick?
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    private var planner = ClickTrackPlanner()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var clickBuffers = [AVAudioPCMBuffer]()
    private var configurationObserver: NSObjectProtocol?
    #if CLICK_TRACK_AUDIO_CHECKS
    private var verificationReceiver: (@Sendable ([Float], Double, UInt64) -> Void)?
    private(set) var verificationScheduledCount = 0
    var verificationHasEngine: Bool { engine != nil }
    var verificationOutputLatency: Double { node?.outputPresentationLatency ?? 0 }

    /// Test builds only: inspect this node's synthesized signal before the
    /// mixer mutes it. This never taps an input device or other app's audio.
    func verifySilently(_ receiver: @escaping @Sendable ([Float], Double, UInt64) -> Void) {
        precondition(engine == nil)
        verificationReceiver = receiver
    }
    #endif

    init() {
        if let saved = UserDefaults.standard.object(forKey: "FretFlow.click.volume") as? Double,
           saved.isFinite, (0...1).contains(saved) { volume = saved }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine?.stop()
    }

    func setEvents(_ events: [ScoreClick]) {
        stop()
        currentClick = nil
        error = planner.setEvents(events) ? nil : "This score's click timing could not be read."
        if planner.events.isEmpty { pauseOutputIfRunning() }
    }

    /// Cancel queued clicks immediately without reopening the hardware route
    /// on every seek, buffering transition, or fresh clock revision.
    func stop() {
        planner.stop()
        node?.stop() // Also removes every queued future click.
        isRunning = false
        if !enabled { pauseOutputIfRunning() }
    }

    /// Leaving practice or unloading the player can also idle the output device.
    func suspend() {
        stop()
        pauseOutputIfRunning()
    }

    private func pauseOutputIfRunning() {
        if let engine, engine.isRunning { engine.pause() }
    }

    func update(position: Double, isPlaying: Bool, rate: Double,
                loopEnd: Double? = nil, discontinuity: UInt64 = 0) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        do {
            let canStart = enabled && isPlaying && !planner.events.isEmpty
                && position.isFinite && position >= 0 && rate.isFinite && (0.125...4).contains(rate)
                && (loopEnd == nil || (loopEnd!.isFinite && loopEnd! >= 0))
            if canStart { try startAudioIfNeeded() }
            let now = ProcessInfo.processInfo.systemUptime
            let startupTime = now - receivedAt
            let plan = planner.update(position: position + (canStart ? startupTime * rate : 0),
                                      isPlaying: isPlaying && startupTime < 0.3, rate: rate,
                                      enabled: enabled, now: now, loopEnd: loopEnd,
                                      discontinuity: discontinuity,
                                      outputLatency: node?.outputPresentationLatency ?? 0)
            if currentClick != plan.currentClick { currentClick = plan.currentClick }
            guard plan.active else {
                if isRunning || plan.resetAudio || canStart { node?.stop() }
                // Keep an enabled output route warm during transport pauses,
                // stale snapshots, and slow cold starts. Reopening it on every
                // clock revision can block the UI and starve fresh snapshots.
                if !enabled || planner.events.isEmpty { pauseOutputIfRunning() }
                isRunning = false
                return
            }
            guard let node, clickBuffers.count == 4 else { return }
            if plan.resetAudio { node.stop() }
            if !node.isPlaying { node.play() }
            node.volume = Float(volume)
            isRunning = true
            error = nil
            for event in plan.clicks {
                let remaining = now + event.delay - ProcessInfo.processInfo.systemUptime
                // Skip a missed rendering deadline instead of letting a click
                // arrive audibly late. The planner has already subtracted the
                // current output path's latency, including wireless devices.
                guard remaining >= -0.002 else { continue }
                let deadline = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: max(0.001, remaining))
                node.scheduleBuffer(clickBuffers[event.click.effectiveAccentLevel],
                                    at: AVAudioTime(hostTime: deadline), options: [], completionHandler: nil)
                #if CLICK_TRACK_AUDIO_CHECKS
                verificationScheduledCount += 1
                #endif
            }
        } catch {
            stop()
            releaseAudio()
            enabled = false
            self.error = "Could not start the click track: \(error.localizedDescription)"
        }
    }

    private struct OutputError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func startAudioIfNeeded() throws {
        if let engine {
            if !engine.isRunning { try engine.start() }
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw OutputError("Audio buffers could not be created.")
        }
        let buffers = (0...3).compactMap { makeBuffer(format: format, accentLevel: $0) }
        guard buffers.count == 4 else { throw OutputError("Audio buffers could not be created.") }
        let output = AVAudioEngine()
        let player = AVAudioPlayerNode()
        output.attach(player)
        output.connect(player, to: output.mainMixerNode, format: format)
        player.volume = Float(volume)
        #if CLICK_TRACK_AUDIO_CHECKS
        if let receiver = verificationReceiver {
            output.mainMixerNode.outputVolume = 0
            player.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, time in
                guard let channel = buffer.floatChannelData?[0], time.isHostTimeValid else { return }
                receiver(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                         buffer.format.sampleRate, time.hostTime)
            }
        }
        #endif
        engine = output
        node = player
        clickBuffers = buffers
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                        object: output, queue: nil) { [weak self, weak output] _ in
            Task { @MainActor in
                guard let self, let output, self.engine === output, self.isRunning, !output.isRunning else { return }
                // Rebuild on the next fresh host-clock update. Ignore the
                // engine's own delayed startup notification when still running.
                self.stop()
                self.releaseAudio()
            }
        }
        output.prepare()
        try output.start()
    }

    private func makeBuffer(format: AVAudioFormat, accentLevel: Int) -> AVAudioPCMBuffer? {
        let samples = ClickWaveform.samples(sampleRate: format.sampleRate, accentLevel: accentLevel)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }

    private func releaseAudio() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        node = nil
        clickBuffers = []
    }
}
#endif
