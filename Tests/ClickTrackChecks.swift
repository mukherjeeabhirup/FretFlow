import Foundation

@main
struct ClickTrackChecks {
    static var checks = 0
    static var failures = [String]()
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        require(abs(actual - expected) < 0.000_001, message + " (\(actual), expected \(expected))")
    }
    static func beat(_ time: Double, index: Int = 0, numerator: Int = 4, denominator: Int = 4) -> ScoreClick {
        let safeNumerator = max(1, numerator)
        return ScoreClick(time: time, barIndex: index / safeNumerator, measureIndex: index / safeNumerator,
                         beatIndex: index % safeNumerator, numerator: numerator, denominator: denominator,
                         bpm: 120, accent: index % safeNumerator == 0)
    }
    static func main() {
        let events = (0..<40).map { beat(Double($0) * 0.5, index: $0) }
        var planner = ClickTrackPlanner()
        require(planner.setEvents(events), "Accept a valid beat grid")
        var plan = planner.update(position: 0, isPlaying: false, rate: 1, enabled: true, now: 0)
        require(plan.clicks.isEmpty && !plan.active, "Enabling while paused must be silent")
        require(plan.currentClick?.numerator == 4, "Show meter while paused")
        plan = planner.update(position: 0, isPlaying: true, rate: 1, enabled: false, now: 0)
        require(plan.clicks.isEmpty && !plan.active, "Disabled click track must be silent")

        plan = planner.update(position: 0, isPlaying: true, rate: 1, enabled: true, now: 1)
        require(plan.resetAudio && plan.clicks.map(\.index) == [0], "Start with exactly the current downbeat")
        near(plan.clicks[0].delay, 0, "Current beat has no delay")
        var emitted = plan.clicks.map(\.index)
        for step in 1...195 {
            let position = Double(step) * 0.05
            plan = planner.update(position: position, isPlaying: true, rate: 1, enabled: true, now: 1 + position)
            require(!plan.resetAudio, "Stable continuous clock must not reset (\(step))")
            for scheduled in plan.clicks {
                near(position + scheduled.delay, scheduled.click.time, "Click follows its absolute media deadline")
                require(scheduled.delay <= ClickTrackPlanner.lookAhead + 0.000_001, "Queue stays bounded")
            }
            emitted += plan.clicks.map(\.index)
        }
        require(emitted == Array(0...19), "Each beat is scheduled once across overlapping lookahead windows")

        plan = planner.update(position: 9.76, isPlaying: false, rate: 1, enabled: true, now: 10.8)
        require(plan.resetAudio && plan.clicks.isEmpty, "Pause cancels queued audio")
        plan = planner.update(position: 15.2, isPlaying: true, rate: 1, enabled: true, now: 11, discontinuity: 1)
        require(plan.resetAudio && plan.clicks.isEmpty, "Seek skips passed beats instead of bursting")
        plan = planner.update(position: 15.4, isPlaying: true, rate: 1, enabled: true, now: 11.2, discontinuity: 1)
        require(plan.clicks.map(\.index) == [31], "Seek resumes at the next beat")
        near(plan.clicks[0].delay, 0.1, "Future seek beat retains phase")
        plan = planner.update(position: 2, isPlaying: true, rate: 1, enabled: true, now: 11.3, discontinuity: 2)
        require(plan.resetAudio && plan.clicks.map(\.index) == [4], "Backward loop re-arms the destination downbeat")
        plan = planner.update(position: 2.01, isPlaying: true, rate: 1, enabled: true, now: 11.31, discontinuity: 3)
        require(plan.resetAudio && plan.clicks.isEmpty, "A new seek does not replay the beat it already passed")

        planner.stop()
        plan = planner.update(position: 0.45, isPlaying: true, rate: 0.5, enabled: true, now: 20)
        require(plan.clicks.count == 1, "Half-speed lookahead includes the next beat")
        near(plan.clicks[0].delay, 0.1, "Half speed converts content delay into twice wall delay")
        plan = planner.update(position: 0.46, isPlaying: true, rate: 2, enabled: true, now: 20.02)
        require(plan.resetAudio && plan.clicks.count == 1, "Rate changes clear previously scheduled deadlines")
        near(plan.clicks[0].delay, 0.02, "Double speed halves wall delay")

        planner.stop()
        plan = planner.update(position: 1.9, isPlaying: true, rate: 1, enabled: true, now: 30, loopEnd: 2)
        require(plan.clicks.isEmpty, "Do not queue the next bar beyond an A/B loop end")
        plan = planner.update(position: 0, isPlaying: true, rate: 1, enabled: true, now: 30.1, loopEnd: 2, discontinuity: 4)
        require(plan.clicks.map(\.index) == [0], "Loop destination downbeat is scheduled")
        plan = planner.update(position: 0.01, isPlaying: true, rate: 1, enabled: false, now: 30.11, loopEnd: 2, discontinuity: 4)
        require(plan.resetAudio && plan.clicks.isEmpty, "Turning off clears the short lookahead")

        planner.stop()
        _ = planner.update(position: 0.4, isPlaying: true, rate: 1, enabled: true, now: 40)
        plan = planner.update(position: 4.2, isPlaying: true, rate: 1, enabled: true, now: 44)
        require(plan.resetAudio && plan.clicks.isEmpty, "Wake/stall resets and skips missed beats")
        plan = planner.update(position: 8.4, isPlaying: true, rate: 1, enabled: true, now: 44.05)
        require(plan.resetAudio && plan.clicks.map(\.index) == [17], "Embedded-player scrub is detected even without an epoch")
        plan = planner.update(position: .nan, isPlaying: true, rate: 1, enabled: true, now: 44.1)
        require(plan.resetAudio && plan.clicks.isEmpty, "Invalid clock stops playback")
        for rate in [Double.nan, .infinity, 0, -1, 10] {
            plan = planner.update(position: 1, isPlaying: true, rate: rate, enabled: true, now: 45)
            require(!plan.active && plan.clicks.isEmpty, "Reject invalid playback rate")
        }
        require(!planner.setEvents([beat(0), beat(0)]), "Reject duplicate click timestamps")
        require(planner.events.isEmpty, "Malformed grid cannot leave old score playing")
        require(!planner.setEvents([beat(1), beat(0)]), "Reject unsorted timestamps")
        require(!planner.setEvents([beat(.nan)]), "Reject nonfinite timestamps")
        require(!planner.setEvents([beat(0, numerator: 0)]), "Reject invalid meter")
        require(planner.setEvents([]), "An empty score disables clicks safely")

        let mixed = [beat(0), beat(0.5, index: 1), beat(1, index: 0, numerator: 7, denominator: 8),
                     beat(1.25, index: 1, numerator: 7, denominator: 8)]
        require(planner.setEvents(mixed), "Accept mixed-meter grid")
        require(planner.click(at: 0.9)?.denominator == 4, "Original meter before change")
        require(planner.click(at: 1)?.numerator == 7 && planner.click(at: 1)?.denominator == 8, "New meter at exact boundary")
        require(planner.click(at: 1.3)?.beatIndex == 1, "Display current beat within the new bar")

        // Presentation delay is a property of the audio route, not musical
        // tempo. The click must render earlier by the same wall time at every
        // playback speed, while the beat display stays on the media position.
        require(planner.setEvents(events), "Reload grid for output latency checks")
        for rate in [0.25, 0.5, 1, 2] {
            planner.stop()
            let position = 0.5 - rate * 0.1
            plan = planner.update(position: position, isPlaying: true, rate: rate,
                                  enabled: true, now: 50, outputLatency: 0.08)
            require(plan.clicks.map(\.index) == [1], "Queue the impending click early at rate \(rate)")
            if let scheduled = plan.clicks.first {
                near(scheduled.delay, 0.02, "Device latency is subtracted in wall seconds")
                near(position + (scheduled.delay + 0.08) * rate, scheduled.click.time,
                     "Audible presentation matches the score deadline")
            }
            require(plan.currentClick?.beatIndex == 0, "Latency compensation does not advance the displayed beat")
        }
        planner.stop()
        plan = planner.update(position: 0.45, isPlaying: true, rate: 1, enabled: true,
                              now: 60, outputLatency: 0.08)
        require(plan.clicks.isEmpty, "Skip a future audible beat whose render deadline is already missed")
        plan = planner.update(position: 0.8, isPlaying: true, rate: 1, enabled: true,
                              now: 60.35, outputLatency: 0.08)
        require(plan.clicks.map(\.index) == [2], "Resume phase-correct output after skipped startup beat")
        near(plan.clicks.first?.delay ?? -1, 0.12, "Lookahead accounts for both queue time and device latency")
        plan = planner.update(position: 0.81, isPlaying: true, rate: 1, enabled: true,
                              now: 60.36, outputLatency: 0.2)
        require(plan.resetAudio && plan.clicks.isEmpty, "A slower output route discards stale queued deadlines")
        plan = planner.update(position: 0.82, isPlaying: false, rate: 1, enabled: true,
                              now: 60.37, outputLatency: 0.2)
        require(plan.resetAudio && plan.clicks.isEmpty, "Pause cancels the expanded latency-aware queue")
        planner.stop()
        plan = planner.update(position: 1.7, isPlaying: true, rate: 1, enabled: true,
                              now: 61, loopEnd: 2, outputLatency: 0.2)
        require(plan.clicks.isEmpty, "Latency compensation never schedules beyond loop B")
        near(ClickTrackPlanner.safeOutputLatency(.nan), 0, "Unknown latency has a safe fallback")
        near(ClickTrackPlanner.safeOutputLatency(-1), 0, "Negative device latency is ignored")
        near(ClickTrackPlanner.safeOutputLatency(3), 1, "Malformed latency cannot create an unbounded queue")

        let legacyData = Data("{\"time\":0,\"barIndex\":0,\"measureIndex\":0,\"beatIndex\":0,\"numerator\":4,\"denominator\":4,\"bpm\":120,\"accent\":true}".utf8)
        let legacyClick = try? JSONDecoder().decode(ScoreClick.self, from: legacyData)
        require(legacyClick?.effectiveAccentLevel == 3, "Legacy payload retains the strong bar downbeat")
        var written = beat(0.125, index: 0)
        written.accentLevel = 2
        written.isSubdivision = true
        written.grouping = "2+2+3"
        require(written.effectiveAccentLevel == 2 && written.isValid, "Written subdivision accent is accepted")
        written.accentLevel = 4
        require(!written.isValid, "Unsupported accent level is rejected before indexing audio buffers")

        for rate in [44_100.0, 48_000.0] {
            let accent = ClickWaveform.samples(sampleRate: rate, accent: true)
            let regular = ClickWaveform.samples(sampleRate: rate, accent: false)
            require(accent.count >= Int(rate * 0.010) && accent.count <= Int(rate * 0.030)
                    && regular.count == accent.count, "Clicks stay short enough to separate fast beats")
            require(accent.first == 0 && accent.last == 0 && regular.first == 0 && regular.last == 0, "Click has clean silent edges")
            require(accent.allSatisfy { $0.isFinite && abs($0) <= 1 } && regular.allSatisfy { $0.isFinite && abs($0) <= 1 }, "No clipping or nonfinite samples")
            let accentEnergy = accent.reduce(0.0) { $0 + Double($1 * $1) }
            let regularEnergy = regular.reduce(0.0) { $0 + Double($1 * $1) }
            require(regularEnergy > 0.1 && accentEnergy > regularEnergy * 1.5, "Downbeat is audibly stronger than ordinary clicks")
            require(accent != regular, "Downbeat has distinct timbre")
            let group = ClickWaveform.samples(sampleRate: rate, accentLevel: 1)
            let written = ClickWaveform.samples(sampleRate: rate, accentLevel: 2)
            let groupEnergy = group.reduce(0.0) { $0 + Double($1 * $1) }
            let writtenEnergy = written.reduce(0.0) { $0 + Double($1 * $1) }
            require(groupEnergy > regularEnergy * 1.2 && writtenEnergy > groupEnergy * 1.1,
                    "Group and written accents have progressively stronger attacks")
            require(group != regular && group != accent && written != group && written != accent,
                    "Bar, group, written, and ordinary clicks have distinct sounds")
            require((group + written).allSatisfy { $0.isFinite && abs($0) <= 1 },
                    "Additional accent sounds cannot clip")
        }
        require(ClickWaveform.samples(sampleRate: 0, accent: false).isEmpty, "Reject bad synthesis rate")
        require(ClickWaveform.samples(accentLevel: 5).isEmpty, "Reject invalid accent synthesis")
        print("Click-track checks: \(checks - failures.count)/\(checks) passed. No audio device or microphone accessed.")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
