import Foundation

@main struct PlaybackAudioEnvelopeChecks {
    static func main() {
        var checks = 0
        func require(_ value: Bool, _ name: String) {
            checks += 1
            if !value { fatalError(name) }
        }
        func near(_ value: Double, _ target: Double, _ name: String) {
            require(abs(value - target) < 0.000001, name)
        }
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            var envelope = PlaybackAudioEnvelope()
            var result = [PlaybackAudioWindow]()
            let count = Int(rate / 100)
            for i in 0..<(count * 3) {
                let amplitude = i < count ? 0.5 : (i < count * 2 ? 0.1 : 0.7)
                if let window = envelope.append(frameEnergy: amplitude * amplitude, framePeak: amplitude,
                                                 at: 100 + Double(i) / rate, rate: rate) { result.append(window) }
            }
            require(result.count == 3, "Ten millisecond windows")
            near(result[0].hostTime, 100, "First sample timestamp")
            near(result[2].hostTime, 100.02, "Contiguous window timestamps")
            near(result[0].duration, 0.01, "Window duration")
            near(result[0].rms, 0.5, "RMS")
            near(result[0].peak, 0.5, "Peak")
            near(result[1].flux, 0, "Falling energy is not an onset")
            near(result[2].flux, 0.6, "Positive energy rise")
        }
        var envelope = PlaybackAudioEnvelope()
        for i in 0..<240 { _ = envelope.append(frameEnergy: 1, framePeak: 1, at: Double(i) / 48_000, rate: 48_000) }
        var afterGap: PlaybackAudioWindow?
        for i in 0..<480 { afterGap = envelope.append(frameEnergy: 0.25, framePeak: 0.5,
                                                       at: 3 + Double(i) / 48_000, rate: 48_000) ?? afterGap }
        require(afterGap != nil, "A gap recovers")
        near(afterGap!.hostTime, 3, "A gap discards the partial preceding window")
        near(afterGap!.rms, 0.5, "No pre-gap samples leak into the new window")
        require(envelope.append(frameEnergy: .nan, framePeak: 0, at: 4, rate: 48_000) == nil, "Reject invalid samples")
        require(envelope.append(frameEnergy: 0, framePeak: 0, at: 4, rate: 0) == nil, "Reject invalid sample rate")
        near(PlaybackAudioEnvelope.hostUptime(presentation: 9999.98, hostClockNow: 10_000, uptimeNow: 3_000)!,
             2999.98, "Host epochs are converted with a simultaneous reference")
        require(PlaybackAudioEnvelope.hostUptime(presentation: 2, hostClockNow: 10_000, uptimeNow: 3_000) == nil,
                "Refuse unknown timestamp epoch")
        require(PlaybackAudioEnvelope.hostUptime(presentation: 10_001, hostClockNow: 10_000, uptimeNow: 3_000) == nil,
                "Refuse implausible future samples")
        require(PlaybackAudioEnvelope.hostUptime(presentation: .nan, hostClockNow: 10_000, uptimeNow: 3_000) == nil,
                "Refuse invalid timestamps")
        print("Playback audio envelope checks passed: \(checks). No capture or permission request.")
    }
}
