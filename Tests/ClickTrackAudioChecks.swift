// Opt-in native output check. Build with -D CLICK_TRACK_AUDIO_CHECKS.
// Only this app's generated click signal is observed, upstream of a muted
// output mixer. No audible sound, microphone, loopback, or saved audio.
import AVFoundation
import Foundation

private final class ClickCapture: @unchecked Sendable {
    struct Pulse {
        var start: Double
        var end: Double
        var energy: Double
    }
    private let lock = NSLock()
    private var pulses = [Pulse]()
    private var renderedBuffers = 0

    func receive(_ samples: [Float], rate: Double, host: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        renderedBuffers += 1
        let start = AVAudioTime.seconds(forHostTime: host)
        for (index, sample) in samples.enumerated() where abs(sample) > 0.004 {
            let time = start + Double(index) / rate
            let energy = Double(sample * sample)
            if let last = pulses.last, time - last.end < 0.025 {
                pulses[pulses.count - 1].end = time
                pulses[pulses.count - 1].energy += energy
            } else {
                pulses.append(Pulse(start: time, end: time, energy: energy))
            }
        }
    }

    func snapshot() -> ([Pulse], Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pulses, renderedBuffers)
    }
}

@main
struct ClickTrackAudioChecks {
    @MainActor static func main() async {
        let track = ClickTrackController()
        let capture = ClickCapture()
        track.verifySilently { capture.receive($0, rate: $1, host: $2) }
        track.volume = 1
        let firstClick = 0.6
        track.setEvents((0..<4).map { index in
            ScoreClick(time: firstClick + Double(index) * 0.35, barIndex: index / 2,
                       measureIndex: index / 2, beatIndex: index % 2,
                       numerator: 2, denominator: 4, bpm: 60 / 0.35, accent: index % 2 == 0)
        })
        track.enabled = true
        track.update(position: 0, isPlaying: false, rate: 1)
        var failures = [String]()
        func require(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        require(!track.verificationHasEngine, "Paused enable unexpectedly opened an audio engine")
        // A cold device can take longer than a fresh video snapshot remains
        // valid. Warm the muted route, then verify steady-state deadlines.
        track.update(position: 8, isPlaying: true, rate: 1)
        let outputLatency = track.verificationOutputLatency
        let pauseAt = firstClick + 0.7 - outputLatency - 0.05
        let start = ProcessInfo.processInfo.systemUptime
        let hostStart = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        while ProcessInfo.processInfo.systemUptime - start < pauseAt {
            track.update(position: ProcessInfo.processInfo.systemUptime - start, isPlaying: true, rate: 1, discontinuity: 1)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        require(track.error == nil, "Native audio start failed: \(track.error ?? "")")
        require(track.verificationScheduledCount >= 3, "The third future beat was not queued before pausing")
        track.update(position: ProcessInfo.processInfo.systemUptime - start, isPlaying: false, rate: 1)
        try? await Task.sleep(nanoseconds: 350_000_000)
        let (firstPulses, bufferCount) = capture.snapshot()
        require(bufferCount > 0, "No generated output buffers reached the player-node tap")
        require(firstPulses.count == 2, "Expected two audible-in-render clicks, then a cancelled third; got \(firstPulses.count)")
        if firstPulses.count >= 2 {
            require(abs(firstPulses[0].start + outputLatency - hostStart - firstClick) < 0.02,
                    "Rendered onset plus reported output latency missed the shared media deadline")
            require(abs(firstPulses[1].start - firstPulses[0].start - 0.35) < 0.015,
                    "Host-time scheduled click spacing drifted")
            require(firstPulses[0].energy > firstPulses[1].energy * 1.5,
                    "Native-rendered accent was not stronger than the regular click")
        }
        require(!track.isRunning, "Pause left the click controller running")

        // Arm a future event, then invalidate transport before its deadline.
        track.update(position: 8, isPlaying: true, rate: 1, discontinuity: 2)
        let resume = ProcessInfo.processInfo.systemUptime
        track.update(position: firstClick - outputLatency - 0.08, isPlaying: true, rate: 1, discontinuity: 3)
        require(track.verificationScheduledCount >= 4, "Resume failed to schedule a future click")
        track.update(position: 8, isPlaying: true, rate: 1, discontinuity: 4)
        try? await Task.sleep(nanoseconds: 200_000_000)
        require(capture.snapshot().0.count == firstPulses.count, "Seek left an old queued click playing")
        track.enabled = false
        require(!track.isRunning, "Disable left the click controller running")
        require(ProcessInfo.processInfo.systemUptime - resume < 2, "Output cancellation stalled")
        if failures.isEmpty {
            print("Native click output check passed: host-time pulses rendered, accent distinct, pause/seek cancelled queued clicks. Mixer muted; no microphone or saved audio.")
            print(String(format: "Reported output latency: %.2f ms; first render onset advanced by %.2f ms. Physical speaker onset was not recorded.",
                         outputLatency * 1_000, (hostStart + firstClick - (firstPulses.first?.start ?? hostStart)) * 1_000))
        } else {
            print(String(format: "Output diagnostic: latency %.2f ms, scheduled %d, tapped buffers %d, pulses %d",
                         outputLatency * 1_000, track.verificationScheduledCount, bufferCount, firstPulses.count))
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
