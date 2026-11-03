import Foundation

/// Run without initializing any audio device:
/// swiftc -O -D PITCH_DETECTOR_CHECKS Sources/FretFlow/Tuner.swift Tests/TunerChecks.swift -o /tmp/fretflow-tuner-checks
@main
struct TunerChecks {
    static var checks = 0
    static var failures = [String]()

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    static func wave(frequency: Double, sampleRate: Double, harmonics: [Double], amplitude: Double = 0.35,
                     decay: Bool = false, count: Int = 8_192) -> [Float] {
        (0..<count).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            let envelope = decay ? exp(-2.2 * Double(index) / Double(count)) : 1
            let value = harmonics.enumerated().reduce(0.0) { $0 + $1.element * sin(phase * Double($1.offset + 1) + 0.37) }
            return Float(value * amplitude * envelope)
        }
    }

    static func noise(count: Int, amplitude: Double, seed: UInt64 = 0x12345678) -> [Float] {
        var randomState = seed
        return (0..<count).map { _ in
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            return Float((Double(randomState >> 40) / Double(1 << 24) - 0.5) * 2 * amplitude)
        }
    }

    static func checkPitch(_ samples: [Float], rate: Double, expected: Double, label: String,
                           tolerance: Double = 4, minimumConfidence: Double = 0.9) {
        let result = GuitarPitchDetector.estimate(samples: samples, sampleRate: rate)
        guard let frequency = result.frequency else {
            require(false, "\(label): no pitch detected")
            return
        }
        let cents = GuitarPitch.cents(frequency: frequency, target: expected)
        require(abs(cents) < tolerance, "\(label): expected \(expected), received \(frequency) (\(cents) cents)")
        require(result.confidence > minimumConfidence, "\(label): confidence \(result.confidence) too low")
    }

    static func checkQuietGuitar(rate: Double) {
        let count = Int(rate * 0.17)
        for midi in [28, 30, 31, 33, 35, 40, 45, 50, 55, 59, 64] {
            let fundamental = GuitarPitch.frequency(midi: midi)
            // A room microphone receives a quiet electric's strong upper
            // partials and a weak fundamental. Use the actual 170ms window,
            // several noise realizations, and a decaying note envelope.
            for seed: UInt64 in [3, 22, 180] {
                let room = noise(count: count, amplitude: 0.00028, seed: seed)
                let pluck = wave(frequency: fundamental, sampleRate: rate,
                                 harmonics: [0.10, 1, 0.20, 0.32], amplitude: 0.0012, decay: true, count: count)
                let samples = zip(pluck, room).map(+)
                let estimate = GuitarPitchDetector.estimate(samples: samples, sampleRate: rate)
                require(estimate.rms < 0.003, "Quiet regression must remain below the previous hard gate")
                checkPitch(samples, rate: rate, expected: fundamental,
                           label: "Unplugged \(GuitarPitch.name(midi: midi)), room \(seed), \(rate)Hz",
                           tolerance: 9, minimumConfidence: 0.85)
            }
        }
        for frequency in [82.4069, 329.6276] {
            let barelyAudible = wave(frequency: frequency, sampleRate: rate, harmonics: [1, 0.3, 0.1],
                                    amplitude: 0.0003, count: count)
            checkPitch(zip(barelyAudible, noise(count: count, amplitude: 0.00008)).map(+), rate: rate,
                       expected: frequency, label: "Very quiet string \(frequency) at \(rate)", tolerance: 5)
        }
        for amplitude in [0.0001, 0.0004, 0.003, 0.1] {
            for seed: UInt64 in [7, 291] {
                require(GuitarPitchDetector.estimate(samples: noise(count: count, amplitude: amplitude, seed: seed),
                                                      sampleRate: rate).frequency == nil,
                        "Increased sensitivity must reject room noise at amplitude \(amplitude), \(rate)Hz")
            }
        }
        let lowFSharp = GuitarPitch.frequency(midi: 30)
        checkPitch(wave(frequency: lowFSharp, sampleRate: rate, harmonics: [0, 1, 0.7, 0.3],
                        amplitude: 0.001, decay: true, count: count), rate: rate, expected: lowFSharp,
                   label: "Missing fundamental with second and third partials at \(rate)", tolerance: 6)
        for frequency in [46.2493, 61.7354, 82.4069, 329.6276] {
            let upperDominant = (0..<count).map { index -> Float in
                let position = Double(index) / Double(count)
                let phase = 2 * Double.pi * frequency * Double(index) / rate
                let harmonics = [0.10, 1.0, 0.15].enumerated().reduce(0.0) { sum, harmonic in
                    let partial = Double(harmonic.offset + 1)
                    // Upper partials fade faster than the fundamental, changing
                    // timbre across the window as on a real plucked string.
                    return sum + harmonic.element * exp(-(0.4 + partial * 0.8) * position) * sin(phase * partial + 0.17)
                }
                return Float(harmonics * 0.0012)
            }
            checkPitch(zip(upperDominant, noise(count: count, amplitude: 0.00025, seed: 81)).map(+),
                       rate: rate, expected: frequency, label: "Weak fundamental and changing decay \(frequency), \(rate)Hz",
                       tolerance: 8, minimumConfidence: 0.85)
        }
        var roomRumble: Float = 0
        let coloredNoise = noise(count: count, amplitude: 0.002).map { sample -> Float in
            roomRumble = 0.94 * roomRumble + sample * 0.06
            return roomRumble
        }
        require(GuitarPitchDetector.estimate(samples: coloredNoise, sampleRate: rate).frequency == nil,
                "Low-frequency room noise should not acquire a note at \(rate)Hz")
        // Pure pitches must not be halved just because a longer period lands
        // closer to an integer sample. Also covers the full custom-tuning range.
        for midi in 28...88 {
            let frequency = GuitarPitch.frequency(midi: midi) * pow(2, 23.0 / 1_200)
            checkPitch(wave(frequency: frequency, sampleRate: rate, harmonics: [1], amplitude: 0.001, count: count),
                       rate: rate, expected: frequency, label: "Chromatic unsnapped MIDI \(midi), \(rate)Hz", tolerance: 5)
        }
        for frequency in stride(from: 1_000.0, through: 1_390.0, by: 13) {
            checkPitch(wave(frequency: frequency, sampleRate: rate, harmonics: [1], amplitude: 0.001, count: count),
                       rate: rate, expected: frequency, label: "High-note octave safety \(frequency), \(rate)Hz", tolerance: 5)
        }
    }

    static func checkTracking() {
        var tracker = GuitarPitchTracker()
        var time = 0.0
        func input(_ frequency: Double?, confidence: Double = 0.97, rms: Double = 0.0007,
                   step: Double = 0.043) -> PitchEstimate {
            time += step
            return tracker.update(.init(frequency: frequency, confidence: confidence, rms: rms), at: time)
        }
        let lowE = GuitarPitch.frequency(midi: 40)
        require(input(lowE).frequency == nil, "An isolated attack must not immediately display a note")
        let acquired = input(lowE)
        require(acquired.frequency.map { abs(GuitarPitch.cents(frequency: $0, target: lowE)) < 0.1 } ?? false,
                "A quiet sustained note is acquired after two observations")
        for _ in 0..<8 {
            let wrong = input(lowE * 2)
            require(wrong.frequency.map { abs(GuitarPitch.cents(frequency: $0, target: lowE)) < 1 } ?? false,
                    "Single-frame octave errors must not move the needle")
            require(wrong.confidence == 0, "An unconfirmed octave must not make the retained note appear in tune")
            _ = input(lowE)
        }
        let changedOctave = (0..<4).map { _ in input(lowE * 2) }.last!
        require(changedOctave.frequency.map { abs(GuitarPitch.cents(frequency: $0, target: lowE * 2)) < 1 } ?? false,
                "A genuine sustained octave jump must be accepted within 172ms")
        let nextString = GuitarPitch.frequency(midi: 45)
        let stringTransition = (0..<3).map { _ in input(nextString) }
        require(stringTransition[0].confidence == 0 && stringTransition[1].confidence == 0,
                "Conflicting string observations must not transfer their confidence to the previous note")
        let changedString = stringTransition.last!
        require(changedString.frequency.map { abs(GuitarPitch.cents(frequency: $0, target: nextString)) < 1 } ?? false,
                "Changing strings must settle within 129ms")
        var jitter = [Double]()
        for cents in [4.0, -4, 3, -3, 2, -2, 4, -4] {
            if let pitch = input(nextString * pow(2, cents / 1_200)).frequency {
                jitter.append(GuitarPitch.cents(frequency: pitch, target: nextString))
            }
        }
        require(jitter.count == 8 && jitter.allSatisfy { abs($0) < 2.5 }, "Cents smoothing must suppress a twitching needle")
        let adjusted = nextString * pow(2, 20.0 / 1_200)
        let tuningChange = (0..<4).map { _ in input(adjusted) }.last!
        require(tuningChange.frequency.map { abs(GuitarPitch.cents(frequency: $0, target: adjusted)) < 2 } ?? false,
                "Turning a tuning peg must stay responsive within 172ms")
        let dropout = input(nil, confidence: 0, rms: 0.0002)
        require(dropout.frequency != nil && dropout.confidence == 0, "A short dropout may hold position without claiming confidence")
        let resumed = input(adjusted)
        require(resumed.frequency != nil, "A note resumes immediately after a brief dropout")
        let silence = (0..<4).map { _ in input(nil, confidence: 0, rms: 0) }.last!
        require(silence.frequency == nil, "Silence must clear a stale pitch within 172ms")
        _ = input(lowE)
        _ = input(lowE)
        for _ in 0..<20 { _ = input(73.4); _ = input(196) }
        require(input(73.4).frequency == nil, "Inconsistent pitches cannot keep a stale note visible indefinitely")
        tracker.reset()
        require(input(nextString).frequency == nil, "A restarted capture must not inherit the previous pitch")
        _ = input(nextString)
        require(input(nextString, step: 1).frequency == nil, "A discontinuous clock must reacquire the note")
        let invalid = tracker.update(.init(frequency: 110, confidence: 1, rms: 0.001), at: .nan)
        require(invalid.frequency == nil, "Invalid tracker timestamps must not leak a stale reading")
    }

    static func checkStreamingPluck(rate: Double) {
        let window = Int(rate * 0.17), hop = 2_048, frames = 20
        let count = window + hop * (frames - 1)
        let fundamental = GuitarPitch.frequency(midi: 30)
        let background = noise(count: count, amplitude: 0.00012, seed: 95)
        let samples = (0..<count).map { index -> Float in
            let t = Double(index) / rate
            let phase = 2 * Double.pi * fundamental * t
            return Float(0.0013 * exp(-2 * t) * (0.1 * sin(phase) + sin(phase * 2) + 0.18 * sin(phase * 3))) + background[index]
        }
        var tracker = GuitarPitchTracker()
        var readings = [Double]()
        for frame in 0..<frames {
            let offset = frame * hop
            let estimate = GuitarPitchDetector.estimate(samples: Array(samples[offset..<(offset + window)]), sampleRate: rate)
            let tracked = tracker.update(estimate, at: Double(offset + window) / rate)
            if let frequency = tracked.frequency { readings.append(frequency) }
        }
        require(readings.count >= 15, "A quiet low-string decay should stay readable through most of its sustain at \(rate)Hz")
        require(readings.allSatisfy { abs(GuitarPitch.cents(frequency: $0, target: fundamental)) < 10 },
                "Overlapping microphone windows must not jump octaves during quiet sustain at \(rate)Hz")
    }

    static func main() {
        let start = Date()
        for rate in [44_100.0, 48_000.0] {
            for frequency in [46.2493, 55.0, 61.7354, 82.4069, 110.0, 146.8324, 196.0, 246.9417, 329.6276, 440.0, 987.7666] {
                checkPitch(wave(frequency: frequency, sampleRate: rate, harmonics: [1]),
                           rate: rate, expected: frequency, label: "Sine \(frequency) Hz at \(rate)", tolerance: 5)
                checkPitch(wave(frequency: frequency, sampleRate: rate, harmonics: [0.7, 1, 0.4, 0.18], decay: true),
                           rate: rate, expected: frequency, label: "Guitar harmonics \(frequency) Hz at \(rate)", tolerance: 7)
            }
            let lowB = GuitarPitch.frequency(midi: 35)
            checkPitch(wave(frequency: lowB, sampleRate: rate, harmonics: [0.2, 1, 0.1]),
                       rate: rate, expected: lowB, label: "Second-harmonic-dominant low B at \(rate)")
            checkPitch(wave(frequency: lowB, sampleRate: rate, harmonics: [1], amplitude: 0.008),
                       rate: rate, expected: lowB, label: "Quiet low B at \(rate)")
            checkPitch(wave(frequency: 82.4069, sampleRate: rate, harmonics: [1, 0.6, 0.35]).map { $0 + 0.3 },
                       rate: rate, expected: 82.4069, label: "DC-offset E2 at \(rate)")
            let silence = GuitarPitchDetector.estimate(samples: [Float](repeating: 0, count: 8_192), sampleRate: rate)
            require(silence.frequency == nil && silence.rms == 0, "Silence should not detect a pitch")
            let constant = GuitarPitchDetector.estimate(samples: [Float](repeating: 0.4, count: 8_192), sampleRate: rate)
            require(constant.frequency == nil, "DC alone should not detect a pitch")
            var randomState: UInt64 = 0x12345678
            let noise = (0..<8_192).map { _ -> Float in
                randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
                return (Float(randomState >> 40) / Float(1 << 24) - 0.5) * 0.7
            }
            require(GuitarPitchDetector.estimate(samples: noise, sampleRate: rate).frequency == nil,
                    "Broadband noise should not detect a pitch at \(rate)")
            let guitarWithNoise = zip(wave(frequency: lowB, sampleRate: rate, harmonics: [1, 0.5, 0.25]), noise)
                .map { $0 + $1 * 0.06 }
            checkPitch(guitarWithNoise, rate: rate, expected: lowB, label: "Low B with room noise at \(rate)")
            checkQuietGuitar(rate: rate)
            checkStreamingPluck(rate: rate)
        }
        checkTracking()
        require(GuitarPitchDetector.estimate(samples: [], sampleRate: 48_000).frequency == nil, "Empty buffers rejected")
        require(GuitarPitchDetector.estimate(samples: [Float](repeating: 0.2, count: 8_192), sampleRate: 0).frequency == nil,
                "Invalid sample rates rejected")
        require(GuitarPitchDetector.estimate(samples: [Float](repeating: .nan, count: 8_192), sampleRate: 48_000).frequency == nil,
                "Non-finite input rejected")
        require(GuitarPitch.parse("B1") == 35, "Low B note parsing")
        require(GuitarPitch.parse("E2") == 40, "Low E note parsing")
        require(GuitarPitch.parse("F#2") == 42 && GuitarPitch.parse("F♯2") == 42, "Sharp note parsing")
        require(GuitarPitch.parse("Bb2") == 46 && GuitarPitch.parse("B♭2") == 46, "Flat note parsing")
        require(GuitarPitch.parse("E") == nil && GuitarPitch.parse("H2") == nil && GuitarPitch.parse("E0") == nil,
                "Invalid and out-of-range note names rejected")
        require(abs(GuitarPitch.frequency(midi: 69, concertA: 442) - 442) < 0.00001, "Adjustable reference pitch")
        require(GuitarPitch.midi(frequency: 61.7354) == 35, "Low B maps to the correct octave")
        require(abs(GuitarPitch.cents(frequency: 880, target: 440) - 1_200) < 0.00001, "Cents map an octave correctly")
        require(Set(GuitarTuning.presets.map(\.id)).count == GuitarTuning.presets.count, "Preset IDs are unique")
        require(GuitarTuning.presets.allSatisfy { (6...7).contains($0.notes.count) }, "All presets have six or seven strings")
        require(GuitarTuning.presets.contains { $0.notes == [35, 40, 45, 50, 55, 59, 64] }, "Seven-string standard tuning exists")
        require(GuitarTuning.presets.contains { $0.notes == [38, 45, 50, 55, 59, 64] }, "Drop D tuning exists")

        let builtIn = TunerInputConfiguration(deviceID: 42, sampleRate: 48_000, channelCount: 1)
        require(!TunerCaptureRecovery.needsRestart(isRunning: true, expected: builtIn, current: builtIn),
                "A delayed startup or unrelated output notification must not stop a healthy built-in mic")
        require(TunerCaptureRecovery.needsRestart(isRunning: false, expected: builtIn, current: builtIn),
                "An engine stopped by macOS must restart even when its input format is unchanged")
        require(TunerCaptureRecovery.needsRestart(isRunning: true, expected: builtIn,
                    current: .init(deviceID: 42, sampleRate: 44_100, channelCount: 1)),
                "A changed hardware sample rate must rebuild the analysis tap")
        require(TunerCaptureRecovery.needsRestart(isRunning: true, expected: builtIn,
                    current: .init(deviceID: 42, sampleRate: 48_000, channelCount: 2)),
                "A changed hardware channel count must rebuild the analysis tap")
        require(TunerCaptureRecovery.needsRestart(isRunning: true, expected: builtIn,
                    current: .init(deviceID: 73, sampleRate: 48_000, channelCount: 1)),
                "A route change must reselect the built-in microphone")
        require(TunerCaptureRecovery.needsRestart(isRunning: true, expected: builtIn, current: nil),
                "An unavailable input must attempt bounded recovery")
        var recovery = TunerCaptureRecovery()
        require(recovery.allowRestart(at: 100), "First reconnection is allowed")
        require(recovery.allowRestart(at: 100.35), "A transient hardware failure can retry")
        require(recovery.allowRestart(at: 100.70), "Third reconnection is allowed")
        require(!recovery.allowRestart(at: 101.05), "Repeated configuration failures cannot loop indefinitely")
        require(recovery.allowRestart(at: 111), "A later independent hardware change can recover")

        print("Tuner checks: \(checks - failures.count)/\(checks) passed in \(String(format: "%.2f", Date().timeIntervalSince(start))) s. No microphone accessed.")
        for failure in failures { print("FAIL: \(failure)") }
        if !failures.isEmpty { exit(1) }
    }
}
