import Foundation

@main struct RecordingPlaybackClockChecks {
    private static func settle(_ clock: inout RecordingPlaybackClock, position: Double,
                               rate: Double, host: Double, revision: UInt64) {
        for observation in 0...24 {
            let elapsed = Double(observation) * 0.05
            clock.observe(position: position + elapsed * rate, rate: rate,
                          host: host + elapsed, revision: revision)
        }
        precondition(clock.isReady)
        precondition(clock.calibrationSampleCount >= 8)
        precondition((clock.calibrationJitter ?? .infinity) < 1e-8)
    }

    static func main() {
        var clock = RecordingPlaybackClock()
        precondition(!clock.isReady)
        precondition(clock.mediaTime(for: 10, now: 10) == nil)
        clock.observe(position: 1, rate: 1, host: 100, revision: 1)
        precondition(!clock.isReady)
        settle(&clock, position: 1, rate: 1, host: 100, revision: 1)
        precondition(abs(clock.mediaTime(for: 100.02, now: 101.25)! - 1.02) < 1e-8,
                     "Settling must retain the beginning of buffered audio")
        precondition(clock.mediaTime(for: 101.2, now: 101.51) == nil,
                     "Stale video clock must not timestamp audio")
        precondition(clock.mediaTime(for: 99.99, now: 101.25) == nil,
                     "Audio before the first observation belongs to an unknown epoch")
        precondition(clock.mediaTime(for: 102, now: 101.25) == nil,
                     "Do not extrapolate far-future audio")
        clock.observe(position: 12, rate: 0.5, host: 102, revision: 2)
        precondition(!clock.isReady)
        settle(&clock, position: 12, rate: 0.5, host: 102, revision: 2)
        precondition(clock.mediaTime(for: 101.99, now: 103.25) == nil)
        precondition(abs(clock.mediaTime(for: 102.04, now: 103.25)! - 12.02) < 1e-8)
        clock.observe(position: 12.2, rate: 2, host: 104, revision: 3)
        settle(&clock, position: 12.2, rate: 2, host: 104, revision: 3)
        precondition(clock.mediaTime(for: 103.99, now: 105.25) == nil)
        precondition(abs(clock.mediaTime(for: 104.04, now: 105.25)! - 12.28) < 1e-8)
        clock.reset()
        precondition(!clock.isReady && clock.calibrationSampleCount == 0)
        precondition(clock.calibrationJitter == nil && clock.calibrationCorrection == nil)

        // Capture arrives at 100 Hz; fresh video observations arrive at 20 Hz.
        // Ignore a 150ms startup error, fit ordinary +/-20ms clock jitter, then
        // replay buffered energy windows without shifting or reordering them.
        for rate in [0.5, 1.0, 2.0] {
            var jittered = RecordingPlaybackClock()
            let initialHost = 500.0
            let initialPosition = 0.8
            var pending = [Double]()
            var previous: Double?
            var mappedCount = 0
            for window in 0...1_200 {
                let elapsed = Double(window) * 0.01
                let host = initialHost + elapsed
                if window.isMultiple(of: 5) {
                    let correction = elapsed < 0.4
                        ? 0.15 * rate : [0.020, 0, -0.020, 0][(window / 5) % 4] * rate
                    jittered.observe(position: initialPosition + elapsed * rate + correction,
                                     rate: rate, host: host, revision: 10)
                }
                pending.append(host)
                if window < 120 {
                    precondition(!jittered.isReady)
                    continue
                }
                precondition(jittered.isReady)
                for sampleHost in pending {
                    guard let mapped = jittered.mediaTime(for: sampleHost, now: host + 0.005) else {
                        preconditionFailure("Buffered continuous audio lost its clock at window \(window), rate \(rate)")
                    }
                    precondition(abs(mapped - (initialPosition + (sampleHost - initialHost) * rate)) < 1e-8,
                                 "Startup error or video observation jitter shifted the fitted timeline")
                    if let previous {
                        precondition(mapped > previous, "Increasing samples must retain increasing media times")
                        precondition(abs(mapped - previous - 0.01 * rate) < 1e-8,
                                     "Capture spacing changed at an observation boundary")
                    }
                    previous = mapped
                    mappedCount += 1
                }
                pending.removeAll(keepingCapacity: true)
            }
            precondition(mappedCount == 1_201)
            precondition(abs(jittered.calibrationCorrection! + 0.15 * rate) < 1e-8)
            precondition(jittered.calibrationJitter! <= 0.041)
            precondition(jittered.mediaTime(for: initialHost + 8, now: initialHost + 12) == nil,
                         "Very old buffered audio must not remain eligible forever")
            precondition(jittered.mediaTime(for: initialHost + 12, now: initialHost + 12.31) == nil,
                         "A settled origin does not make a stale video clock fresh")
        }

        // A bimodal unstable clock must not pass on an accidentally zero MAD.
        var unstable = RecordingPlaybackClock()
        for observation in 0...24 {
            let elapsed = Double(observation) * 0.05
            let correction = observation.isMultiple(of: 2) ? 0.2 : -0.2
            unstable.observe(position: 10 + elapsed + correction, rate: 1,
                             host: 200 + elapsed, revision: 1)
        }
        precondition(!unstable.isReady && unstable.calibrationJitter! > 0.08)
        for observation in 25...44 {
            let elapsed = Double(observation) * 0.05
            unstable.observe(position: 10 + elapsed, rate: 1, host: 200 + elapsed, revision: 1)
        }
        precondition(unstable.isReady, "A rolling calibration window must recover when observations settle")

        var frozen = RecordingPlaybackClock()
        settle(&frozen, position: 0, rate: 1, host: 50, revision: 1)
        for host in [51.3, 51.4, 51.51] {
            frozen.observe(position: 1.2, rate: 1, host: host, revision: 1)
        }
        precondition(frozen.mediaTime(for: 51.51, now: 51.51) == nil,
                     "Frozen positions must not keep an audio epoch alive")
        frozen.observe(position: 1.6, rate: 1, host: 51.6, revision: 1)
        precondition(abs(frozen.mediaTime(for: 51.6, now: 51.6)! - 1.6) < 1e-8)
        frozen.observe(position: 4, rate: 0.5, host: 52, revision: 1)
        precondition(!frozen.isReady)
        settle(&frozen, position: 4, rate: 0.5, host: 52, revision: 1)
        precondition(frozen.mediaTime(for: 51.99, now: 53.25) == nil,
                     "A changed rate starts an epoch even if the caller misses a revision")
        precondition(abs(frozen.mediaTime(for: 52.02, now: 53.25)! - 4.01) < 1e-8)
        frozen.observe(position: 8, rate: 0.5, host: 55, revision: 1)
        precondition(!frozen.isReady && frozen.mediaTime(for: 54.9, now: 55) == nil,
                     "A background observation gap cannot reuse an origin from before suspension")
        settle(&frozen, position: 8, rate: 0.5, host: 55, revision: 1)
        precondition(abs(frozen.mediaTime(for: 55.02, now: 56.25)! - 8.01) < 1e-8)
        frozen.observe(position: .nan, rate: 1, host: 53.3, revision: 2)
        precondition(!frozen.isReady && frozen.mediaTime(for: 53.3, now: 53.3) == nil)
        print("Recording playback clock checks passed: startup settling, buffered opening audio, monotonic 100 Hz capture through 12 seconds of jitter at three speeds, unstable-clock recovery, seek/rate epochs and frozen/stale bounds.")
    }
}
