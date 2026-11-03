import Foundation

@main
struct RecordingOnsetChecks {
    static func main() {
        var count = 0
        func require(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }
        let rhythm = [0.0, 0.31, 0.89, 1.24, 1.88, 2.17, 2.93, 3.33, 3.98, 4.21,
                      4.96, 5.43, 6.12, 6.51, 7.18, 7.91, 8.26, 8.88, 9.47, 10.16, 10.48, 11.25]

        func simulate(reference: [Double], audioAttacks: [Double], duration: Double = 14,
                      captureStart: Double = 0, scale: Double = 1, inferred: Double = 0,
                      noise: Double = 0.00001, background: Double = 0,
                      jitter: Bool = false) -> RecordingOnsetMatch? {
            var matcher = RecordingOnsetMatcher(referenceAttacks: reference, alignmentScale: scale, inferredOffset: inferred)
            let events = audioAttacks.enumerated().map { index, time in
                time + (jitter ? [0.0, 0.008, -0.006, 0.003][index % 4] : 0)
            }
            for index in 0...Int((duration - captureStart) / 0.01) {
                let time = captureStart + Double(index) * 0.01
                var amplitude = noise + background
                for attack in events where time >= attack && time - attack <= 0.3 {
                    amplitude += 0.12 * exp(-(time - attack) / 0.06)
                }
                if let result = matcher.observe(time: time, rms: amplitude, peak: amplitude * 2) { return result }
            }
            return matcher.finish()
        }

        let delayed = simulate(reference: rhythm, audioAttacks: rhythm.map { $0 + 0.75 })
        require(delayed != nil && abs(delayed!.offset - 0.75) <= 0.015, "Known 0.75-second leading silence did not align")
        require(delayed!.matchedAttackCount >= 6 && delayed!.confidence >= 0.88, "Weak match was accepted")
        let periodic = stride(from: 0.0, through: 12, by: 0.5).map { $0 }
        let anchored = simulate(reference: periodic, audioAttacks: periodic.map { $0 + 0.75 })
        require(anchored != nil && abs(anchored!.offset - 0.75) <= 0.015,
                "Clean leading silence did not disambiguate a quarter-note shift")
        let ambiguous = simulate(reference: periodic, audioAttacks: periodic.map { $0 + 0.75 }, captureStart: 1)
        require(ambiguous == nil, "Unanchored periodic rhythm must not guess a beat or bar offset")

        let openingRest = rhythm.map { $0 + 1.1 }
        let resting = simulate(reference: openingRest, audioAttacks: openingRest.map { $0 + 0.75 })
        require(resting != nil && abs(resting!.offset - 0.75) <= 0.025,
                "An opening rest was mistaken for leading recording silence")
        let intro = [0.1, 0.62, 1.18, 1.71]
        let otherInstrument = simulate(reference: openingRest, audioAttacks: intro + openingRest.map { $0 + 0.75 })
        require(otherInstrument == nil || abs(otherInstrument!.offset - 0.75) <= 0.025,
                "Unnotated opening instruments caused a false first-sound anchor")

        let longRest = rhythm.map { $0 + 23.1 }
        let longIntro = stride(from: 0.0, through: 22.5, by: 0.5).map { $0 }
        let lateGuitar = simulate(reference: longRest, audioAttacks: longIntro + longRest.map { $0 + 0.75 }, duration: 38)
        require(lateGuitar != nil && abs(lateGuitar!.offset - 0.75) <= 0.025,
                "Long unnotated intro was matched to the score's much later guitar entrance")

        let adjusted = simulate(reference: rhythm, audioAttacks: rhythm.map { $0 + 0.75 }, inferred: 1.2)
        require(adjusted != nil && abs(adjusted!.adjustment + 0.45) <= 0.015,
                "Result did not subtract the existing inferred alignment")
        let scaled = simulate(reference: rhythm, audioAttacks: rhythm.map { $0 * 1.02 + 0.75 }, scale: 1.02, jitter: true)
        require(scaled != nil && abs(scaled!.offset - 0.75) <= 0.025,
                "Score alignment scale or audio-window jitter changed the inferred intro")
        let wider = simulate(reference: rhythm, audioAttacks: rhythm.map { $0 + 5.75 }, duration: 19)
        require(wider != nil && abs(wider!.offset - 5.75) <= 0.015,
                "A confirmed leading silence could not match an intro beyond the narrow search")

        require(simulate(reference: rhythm, audioAttacks: []) == nil, "Silence should not align")
        require(simulate(reference: rhythm, audioAttacks: [0.75]) == nil, "A single attack should not align")
        require(simulate(reference: [0, 4, 8, 12], audioAttacks: [0.75, 4.75, 8.75, 12.75]) == nil,
                "Sparse material needs manual confirmation")
        require(simulate(reference: rhythm, audioAttacks: [], noise: 0.015) == nil, "Steady noise should not align")
        let unrelated = [0.75, 1.16, 1.67, 2.58, 2.83, 3.17, 4.64, 5.03, 5.36, 6.39, 7.65, 8.73, 9.84, 10.91]
        require(simulate(reference: rhythm, audioAttacks: unrelated) == nil,
                "Unrelated attacks or an ad-like rhythm should not be accepted")

        // Rapid random level changes should not fit a dense score just because
        // some expected note lies near nearly every possible point in time.
        var noisy = RecordingOnsetMatcher(referenceAttacks: (0..<4_096).map { Double($0) * 0.03 })
        var seed: UInt64 = 928_147
        var maximumUpdateMilliseconds = 0.0
        for index in 0...1_400 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let amplitude = 0.005 + Double((seed >> 32) % 10_000) * 0.000006
            let began = ProcessInfo.processInfo.systemUptime
            _ = noisy.observe(time: Double(index) * 0.01, rms: amplitude, peak: amplitude * 2)
            maximumUpdateMilliseconds = max(maximumUpdateMilliseconds, (ProcessInfo.processInfo.systemUptime - began) * 1_000)
        }
        require(noisy.finish() == nil, "Random fluctuations matched a dense score")

        // Small clock/interpolation jitter must not poison a whole pass. These
        // late duplicate windows are ignored rather than changing onset times.
        var jitteredClock = RecordingOnsetMatcher(referenceAttacks: rhythm)
        for index in 0...1_400 {
            let time = Double(index) * 0.01
            var amplitude = 0.00001
            for attack in rhythm.map({ $0 + 0.75 }) where time >= attack && time - attack <= 0.3 {
                amplitude += 0.12 * exp(-(time - attack) / 0.06)
            }
            _ = jitteredClock.observe(time: time, rms: amplitude, peak: amplitude * 2)
            if index > 5 && index.isMultiple(of: 50) {
                _ = jitteredClock.observe(time: time - 0.012, rms: amplitude, peak: amplitude * 2)
            }
        }
        let jitteredMatch = jitteredClock.finish()
        require(jitteredMatch != nil && abs(jitteredMatch!.offset - 0.75) <= 0.015,
                "Small backward clock jitter poisoned an otherwise valid match")
        require(!jitteredClock.isDiscontinuous && jitteredClock.failureReason == nil && jitteredClock.ignoredWindowCount > 0,
                "Small discarded jitter was incorrectly reported as a discontinuity")
        require(jitteredClock.detectedOnsetTimes.count == jitteredClock.observedAttackCount
                    && jitteredClock.acceptedWindowCount > 700,
                "Timing-only analysis diagnostics disagree with the accepted input")
        require(jitteredClock.leadingAnchorTime != nil && abs(jitteredClock.leadingAnchorTime! - 0.75) <= 0.015,
                "Leading onset diagnostic was lost or retimed by a duplicate window")

        var broken = RecordingOnsetMatcher(referenceAttacks: rhythm)
        _ = broken.observe(time: 0, rms: 0, peak: 0)
        _ = broken.observe(time: 2, rms: 0.1, peak: 0.2)
        for index in 201...1_400 {
            _ = broken.observe(time: Double(index) * 0.01, rms: 0.1, peak: 0.2)
        }
        require(broken.finish() == nil, "Capture gaps must invalidate the attempt rather than invent silence")
        require(broken.isDiscontinuous && broken.failureReason != nil,
                "Capture-gap rejection did not explain why analysis stopped")
        var backwards = RecordingOnsetMatcher(referenceAttacks: rhythm)
        _ = backwards.observe(time: 1, rms: 0.01, peak: 0.02)
        _ = backwards.observe(time: 0.8, rms: 0.01, peak: 0.02)
        require(backwards.isDiscontinuous && backwards.finish() == nil,
                "A substantial backward seek must invalidate the attempt")
        var invalid = RecordingOnsetMatcher(referenceAttacks: [Double.nan, -.infinity, -1])
        _ = invalid.observe(time: .nan, rms: 0.1, peak: 0.2)
        _ = invalid.observe(time: 0, rms: .infinity, peak: 0.2)
        require(invalid.finish() == nil, "Invalid samples or score timing should never match")

        let acceptedBefore = jitteredClock.acceptedWindowCount
        let matchedDiagnostics = jitteredClock.diagnostics
        let candidate = matchedDiagnostics["refinedCandidate"] as? [String: Any]
        require(matchedDiagnostics["matchAvailable"] as? Bool == true
                    && matchedDiagnostics["rejectionReason"] == nil
                    && abs((candidate?["offset"] as? Double ?? -100) - 0.75) <= 0.015,
                "Successful diagnostics disagree with the accepted match")
        require(candidate?["expectedAttackCount"] as? Int != nil
                    && matchedDiagnostics["detectedOnsetTimes"] as? [Double] == jitteredClock.detectedOnsetTimes,
                "Candidate coverage or timing-only onset metadata is missing")
        require(jitteredClock.acceptedWindowCount == acceptedBefore && jitteredClock.finish() == jitteredMatch,
                "Reading diagnostics mutated the matcher or its accepted result")

        var ambiguousDiagnostic = RecordingOnsetMatcher(referenceAttacks: periodic)
        for index in 100...1_400 {
            let time = Double(index) * 0.01
            var amplitude = 0.00001
            for attack in periodic.map({ $0 + 0.75 }) where time >= attack && time - attack <= 0.3 {
                amplitude += 0.12 * exp(-(time - attack) / 0.06)
            }
            _ = ambiguousDiagnostic.observe(time: time, rms: amplitude, peak: amplitude * 2)
        }
        let ambiguousDetails = ambiguousDiagnostic.diagnostics
        require(ambiguousDiagnostic.finish() == nil
                    && (ambiguousDetails["rejectionReason"] as? String)?.contains("Competing rhythmic offsets") == true,
                "Ambiguous rhythmic offsets did not report their actual rejection reason")
        require(ambiguousDetails["bestCandidate"] != nil && ambiguousDetails["competingCandidate"] != nil
                    && (ambiguousDetails["competingMargin"] as? Double ?? 100) < 0.10,
                "Ambiguity diagnostics omitted the competing candidate or margin")
        require(broken.diagnostics["rejectionReason"] as? String == broken.failureReason,
                "Discontinuous diagnostics hid the capture failure")
        require(noisy.diagnostics["rejectionReason"] is String && invalid.diagnostics["rejectionReason"] is String,
                "Rejected or empty input lacks an explanation")
        for details in [matchedDiagnostics, ambiguousDetails, noisy.diagnostics, broken.diagnostics, backwards.diagnostics, invalid.diagnostics] {
            require(JSONSerialization.isValidJSONObject(details), "Diagnostics contain nonfinite or non-JSON-safe values")
            require(!details.keys.contains(where: { ["rms", "peak", "samples", "envelope", "strength"].contains($0) }),
                    "Diagnostics exposed audio samples or reconstructable envelope values")
        }
        print("Recording onset checks passed (\(count)): intro offsets, rests, ambiguity, scale, jitter, sparse/noisy input and capture gaps.")
        print(String(format: "Largest update in dense-score/noise stress case: %.2f ms", maximumUpdateMilliseconds))
    }
}
