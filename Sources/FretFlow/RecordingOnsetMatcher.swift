import Foundation

struct RecordingOnsetMatch: Equatable {
    /// Media/content time of score time zero, including the inferred alignment.
    let offset: Double
    /// Add this to the score's inferred offset; do not also add `offset`.
    let adjustment: Double
    let confidence: Double
    let matchedAttackCount: Int
    let observedAttackCount: Int
}

/// Conservative rhythm alignment of an isolated recording's energy envelope.
/// Input times are already media/content seconds, not wall or device seconds.
/// This does not identify a recording, infer tempo, or guarantee alignment from
/// one sound: ambiguous/sparse/noisy material deliberately produces no result.
struct RecordingOnsetMatcher {
    private struct Window {
        let time: Double
        let level: Double
    }
    private struct Onset {
        let time: Double
        let strength: Double
    }
    private struct Candidate {
        let offset: Double
        let score: Double
        let precision: Double
        let recall: Double
        let matches: Int
        let observed: Int
        let expected: Int
        let errors: [Double]
    }
    private struct Evaluation {
        var match: RecordingOnsetMatch?
        var best: Candidate?
        var refined: Candidate?
        var alternative: Candidate?
        var margin: Double?
        var anchor: Double?
        var rejectionReason: String?
    }

    private let reference: [Double]
    private let inferredOffset: Double
    private var recent = [Window]()
    private var onsets = [Onset]()
    private var firstTime: Double?
    private var lastTime: Double?
    private var lastEvaluation: Double = -.infinity
    private var leadingSilencePossible = true
    private var leadingCandidate: Double?
    private var leadingActiveDuration = 0.0
    private var leadingAnchor: Double?
    private var receivedWindows = 0
    private(set) var isDiscontinuous = false
    private(set) var failureReason: String?
    private(set) var ignoredWindowCount = 0
    private(set) var result: RecordingOnsetMatch?

    var observedAttackCount: Int { onsets.count }
    var analyzedDuration: Double { max(0, (lastTime ?? 0) - (firstTime ?? 0)) }
    var acceptedWindowCount: Int { receivedWindows }
    /// Timing-only diagnostics; no audio or reconstructable envelope is exposed.
    var detectedOnsetTimes: [Double] { onsets.map(\.time) }
    var leadingAnchorTime: Double? { leadingAnchor }

    /// Timing and confidence metadata only. Evaluates the same bounded search
    /// used for matching without mutating it; no samples/envelope are exposed.
    var diagnostics: [String: Any] {
        let evaluation = evaluateDetails()
        var values: [String: Any] = [
            "analyzedDuration": analyzedDuration,
            "acceptedWindowCount": acceptedWindowCount,
            "ignoredWindowCount": ignoredWindowCount,
            "observedAttackCount": observedAttackCount,
            "referenceAttackCount": reference.count,
            "detectedOnsetTimes": detectedOnsetTimes,
            "isDiscontinuous": isDiscontinuous,
            "matchAvailable": evaluation.match != nil,
            "leadingAnchorEligible": evaluation.anchor != nil
        ]
        if let firstTime { values["firstWindowTime"] = firstTime }
        if let lastTime { values["lastWindowTime"] = lastTime }
        if let leadingAnchor { values["leadingAnchorTime"] = leadingAnchor }
        if let anchor = evaluation.anchor { values["anchorOffset"] = anchor }
        if let failureReason { values["failureReason"] = failureReason }
        if let reason = evaluation.rejectionReason { values["rejectionReason"] = reason }
        func candidate(_ value: Candidate) -> [String: Any] {
            ["offset": value.offset, "score": value.score, "precision": value.precision,
             "recall": value.recall, "matchedAttackCount": value.matches,
             "observedAttackCount": value.observed, "expectedAttackCount": value.expected,
             "medianTimingError": Self.median(value.errors)]
        }
        if let best = evaluation.best { values["bestCandidate"] = candidate(best) }
        if let refined = evaluation.refined { values["refinedCandidate"] = candidate(refined) }
        if let alternative = evaluation.alternative { values["competingCandidate"] = candidate(alternative) }
        if let margin = evaluation.margin { values["competingMargin"] = margin }
        if let match = evaluation.match {
            values["match"] = ["offset": match.offset, "adjustment": match.adjustment,
                               "confidence": match.confidence]
        }
        return values
    }

    init(referenceAttacks: [Double], alignmentScale: Double = 1, inferredOffset: Double = 0) {
        self.inferredOffset = inferredOffset.isFinite ? inferredOffset : 0
        let scale = alignmentScale.isFinite && (0.25...4).contains(alignmentScale) ? alignmentScale : 1
        let sorted = referenceAttacks.filter { $0.isFinite && $0 >= 0 && $0 <= 180 }
            .map { $0 * scale }.sorted()
        var merged = [Double]()
        // Simultaneous attacks in different parts are one rhythmic event.
        for attack in sorted where merged.last.map({ attack - $0 >= 0.025 }) ?? true {
            merged.append(attack)
            if merged.count >= 4_096 { break }
        }
        reference = merged
    }

    /// A window should summarize roughly 10–25 ms of playback. `time` is the
    /// media position of its first sample; normalized RMS and peak are finite.
    /// Tiny out-of-order windows are discarded, never retimed. A backward seek
    /// or capture gap invalidates this attempt; start a new matcher for a fresh
    /// continuous playback pass.
    mutating func observe(time: Double, rms: Double, peak: Double) -> RecordingOnsetMatch? {
        if let result { return result }
        guard !isDiscontinuous else { return nil }
        guard time.isFinite, time >= 0, rms.isFinite, peak.isFinite,
              rms >= 0, peak >= 0, rms <= 4, peak <= 4 else {
            ignoredWindowCount += 1
            return nil
        }
        if let lastTime {
            if time < lastTime - 0.025 {
                invalidate("Playback timing moved backwards during analysis.")
                return nil
            }
            if time - lastTime > 0.25 {
                invalidate("Playback audio has a gap during analysis.")
                return nil
            }
            if time <= lastTime {
                ignoredWindowCount += 1
                return nil
            }
        }
        if firstTime == nil {
            firstTime = time
            leadingSilencePossible = time <= 0.12
        }
        guard analyzedDuration <= 60, receivedWindows < 24_000 else {
            invalidate("The bounded recording-analysis window is complete.")
            return nil
        }
        receivedWindows += 1
        let elapsed = lastTime.map { time - $0 } ?? 0
        lastTime = time
        let level = max(rms, peak * 0.22)
        recent.removeAll { time - $0.time > 0.12 }
        let preceding = recent.filter { time - $0.time <= 0.075 }.map(\.level)
        let baseline = Self.median(preceding)

        updateLeadingSilence(time: time, level: level, elapsed: elapsed)

        // Positive energy change, rather than absolute volume, finds attacks
        // over sustained backing instruments. A short refractory period avoids
        // counting one attack's rising envelope several times.
        let rise = level - baseline
        if level >= 0.0015, rise >= max(0.0009, baseline * 0.42),
           onsets.last.map({ time - $0.time >= 0.075 }) ?? true {
            let strength = min(1, max(0.25, rise / max(level, 0.004)))
            onsets.append(Onset(time: time, strength: strength))
            if onsets.count > 800 {
                invalidate("Too many distinct audio attacks were detected to match safely.")
                return nil
            }
        }
        recent.append(Window(time: time, level: level))

        if time - lastEvaluation >= 0.5, analyzedDuration >= 8 {
            lastEvaluation = time
            result = evaluate()
        }
        return result
    }

    mutating func finish() -> RecordingOnsetMatch? {
        if result == nil { result = evaluate() }
        return result
    }

    private mutating func invalidate(_ reason: String) {
        isDiscontinuous = true
        failureReason = reason
    }

    private mutating func updateLeadingSilence(time: Double, level: Double, elapsed: Double) {
        guard leadingAnchor == nil, leadingSilencePossible else { return }
        if let candidate = leadingCandidate {
            if level >= 0.0008 { leadingActiveDuration += elapsed }
            if time - candidate >= 0.08 {
                // A transient click or a single noise spike is not music onset.
                if leadingActiveDuration >= 0.055 { leadingAnchor = candidate }
                leadingSilencePossible = false
            }
        } else if level > 0.0007 {
            if level >= 0.003, time - (firstTime ?? time) >= 0.18, time <= 15 {
                leadingCandidate = time
                leadingActiveDuration = 0
            } else {
                // Gradual fades or a capture that began during music don't
                // supply the precise silence-to-attack anchor required here.
                leadingSilencePossible = false
            }
        }
    }

    private func evaluate() -> RecordingOnsetMatch? { evaluateDetails().match }

    private func evaluateDetails() -> Evaluation {
        var evaluation = Evaluation()
        guard !isDiscontinuous else {
            evaluation.rejectionReason = failureReason ?? "Playback analysis was discontinuous."
            return evaluation
        }
        guard let start = firstTime, let end = lastTime, end - start >= 8 else {
            evaluation.rejectionReason = "At least eight seconds of continuous audio are required."
            return evaluation
        }
        guard reference.count >= 6, onsets.count >= 6 else {
            evaluation.rejectionReason = reference.count < 6
                ? "The score has fewer than six reference attacks."
                : "Fewer than six audio attacks were detected."
            return evaluation
        }
        // An opening guitar rest may accompany drums/ambience absent from the
        // tab book. Never anchor that guitar entrance to the first recorded sound.
        let anchor = (reference.first ?? 1) <= 0.25 ? leadingAnchor.map { $0 - reference[0] } : nil
        evaluation.anchor = anchor
        let lower = max(-30, inferredOffset - 3)
        let upper = min(120, inferredOffset + 3)
        var offsets = stride(from: lower, through: upper, by: 0.01).map { $0 }
        if let anchor, anchor >= 0, anchor <= 15 { offsets.append(anchor) }
        var candidates = [Candidate]()
        for offset in offsets {
            if let anchor, abs(offset - anchor) > 0.065 { continue }
            if let candidate = evaluate(offset: offset, start: start, end: end) { candidates.append(candidate) }
        }
        candidates.sort { $0.score > $1.score }
        guard let best = candidates.first else {
            evaluation.rejectionReason = "No candidate has six matches spanning 3.5 seconds within six seconds of coverage."
            return evaluation
        }
        evaluation.best = best
        evaluation.alternative = candidates.first { abs($0.offset - best.offset) >= 0.12 }
        evaluation.margin = best.score - (evaluation.alternative?.score ?? 0)
        func rejection(_ candidate: Candidate, stage: String) -> String? {
            if candidate.matches < 6 { return "\(stage) candidate has fewer than six matching attacks." }
            if candidate.precision < 0.78 { return "\(stage) candidate precision is below 0.78." }
            if candidate.recall < 0.45 { return "\(stage) candidate recall is below 0.45." }
            if candidate.score < 0.82 { return "\(stage) candidate score is below 0.82." }
            return nil
        }
        if let reason = rejection(best, stage: "Best") {
            evaluation.rejectionReason = reason
            return evaluation
        }

        // Refine to the median observed/reference residual, robust to an odd
        // spurious transient; this is bounded by input audio-window precision.
        let refinedOffset = best.offset + Self.median(best.errors)
        guard let refined = evaluate(offset: refinedOffset, start: start, end: end) else {
            evaluation.rejectionReason = "The refined offset no longer has sufficient matching coverage."
            return evaluation
        }
        evaluation.refined = refined
        evaluation.alternative = candidates.first { abs($0.offset - refinedOffset) >= 0.12 }
        evaluation.margin = refined.score - (evaluation.alternative?.score ?? 0)
        if let reason = rejection(refined, stage: "Refined") {
            evaluation.rejectionReason = reason
            return evaluation
        }
        let confidence: Double
        if let anchor {
            guard abs(refinedOffset - anchor) <= 0.065 else {
                evaluation.rejectionReason = "The refined offset disagrees with the leading-silence anchor."
                return evaluation
            }
            confidence = min(0.99, 0.78 + 0.12 * refined.precision + 0.07 * refined.recall)
        } else {
            // Periodic quarter/eighth patterns can fit several offsets a beat
            // apart. Without a clean start anchor, leave those cases unaligned.
            let margin = evaluation.margin ?? 0
            guard margin >= 0.10 else {
                evaluation.rejectionReason = "Competing rhythmic offsets are too similar (margin below 0.10)."
                return evaluation
            }
            confidence = min(0.98, 0.65 + refined.score * 0.25 + min(0.08, margin * 0.5))
        }
        let adjustment = refinedOffset - inferredOffset
        guard confidence >= 0.88, adjustment.isFinite, (-30...120).contains(adjustment) else {
            evaluation.rejectionReason = "Confidence is below 0.88 or the adjustment is outside its permitted range."
            return evaluation
        }
        evaluation.match = RecordingOnsetMatch(offset: refinedOffset, adjustment: adjustment, confidence: confidence,
                                              matchedAttackCount: refined.matches, observedAttackCount: refined.observed)
        return evaluation
    }

    private func evaluate(offset: Double, start: Double, end: Double) -> Candidate? {
        let firstExpected = (reference.first ?? 0) + offset
        let coverageStart = max(start, firstExpected - 0.055)
        let coverageEnd = end - 0.07
        guard coverageEnd - coverageStart >= 6 else { return nil }
        let observed = onsets.filter { $0.time >= coverageStart && $0.time <= coverageEnd }
        let firstReference = Self.lowerBound(reference, coverageStart - offset)
        let afterReference = Self.lowerBound(reference, coverageEnd - offset + 0.000_001)
        let expectedCount = afterReference - firstReference
        guard observed.count >= 6, expectedCount >= 6 else { return nil }
        var matched = Set<Int>()
        var errors = [Double]()
        var weights = 0.0
        var matchedWeights = 0.0
        var firstMatch: Double?
        var lastMatch: Double?
        for onset in observed {
            let weight = 0.5 + onset.strength * 0.5
            weights += weight
            let target = onset.time - offset
            let insertion = Self.lowerBound(reference, target)
            let options = [insertion - 1, insertion].filter { $0 >= firstReference && $0 < afterReference }
            guard let index = options.min(by: { abs(reference[$0] - target) < abs(reference[$1] - target) }),
                  !matched.contains(index) else { continue }
            let error = target - reference[index]
            guard abs(error) <= 0.045 else { continue }
            matched.insert(index)
            errors.append(error)
            matchedWeights += weight * max(0, 1 - pow(error / 0.065, 2))
            if firstMatch == nil { firstMatch = onset.time }
            lastMatch = onset.time
        }
        guard matched.count >= 6, (lastMatch ?? 0) - (firstMatch ?? 0) >= 3.5 else { return nil }
        let precision = matchedWeights / max(weights, 0.0001)
        let recall = Double(matched.count) / Double(expectedCount)
        let score = 0.75 * precision + 0.25 * min(1, recall / 0.75)
        return Candidate(offset: offset, score: score, precision: precision, recall: recall,
                         matches: matched.count, observed: observed.count, expected: expectedCount, errors: errors)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) * 0.5 : sorted[middle]
    }

    private static func lowerBound(_ values: [Double], _ target: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < target { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
