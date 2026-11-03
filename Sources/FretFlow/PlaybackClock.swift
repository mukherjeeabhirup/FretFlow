import Foundation

/// Gate scheduled audio on fresh, observed video state. A transport request is
/// not proof that YouTube has completed it; old snapshots must not restart clicks.
struct PlaybackClockGate {
    private(set) var revision: UInt64 = 0
    private var sampleTime: TimeInterval?
    private var progressTime: TimeInterval?
    private var position: Double = 0
    private var rate: Double = 1
    private var playing = false
    private var pendingSeek: Double?
    private var seekOrigin: Double?
    private var pendingRate: Double?
    private var waitingForPause = false
    private var requestedAt: TimeInterval?

    mutating func reset() {
        invalidateSample()
        pendingSeek = nil
        seekOrigin = nil
        pendingRate = nil
        waitingForPause = false
        requestedAt = nil
    }

    private mutating func invalidateSample() {
        revision &+= 1
        sampleTime = nil
        progressTime = nil
        playing = false
    }

    mutating func requestPause() { invalidateSample(); waitingForPause = true }
    mutating func requestPlay() { invalidateSample(); waitingForPause = false }
    /// A different clock source/document must prove motion independently,
    /// without dropping transport commands that are still awaiting confirmation.
    mutating func invalidateSource() { invalidateSample() }
    mutating func requestSeek(_ seconds: Double, from origin: Double? = nil, at now: TimeInterval) {
        seekOrigin = origin ?? position
        invalidateSample(); pendingSeek = seconds; requestedAt = now
    }
    mutating func requestRate(_ value: Double, at now: TimeInterval) {
        invalidateSample(); pendingRate = value; requestedAt = now
    }

    mutating func observe(position newPosition: Double, rate newRate: Double,
                          isPlaying: Bool, isPaused: Bool = false, at now: TimeInterval) {
        guard newPosition.isFinite, newRate.isFinite, newRate > 0, now.isFinite else { reset(); return }
        let previouslyAllowed = canSchedule(at: now)
        let awaitingTransport = waitingForPause || pendingSeek != nil || pendingRate != nil
        if let sampleTime {
            let elapsed = max(0, now - sampleTime)
            let predicted = position + (playing ? min(0.5, elapsed) * rate : 0)
            if playing != isPlaying || abs(rate - newRate) > 0.0001
                || abs(newPosition - predicted) > max(0.15, newRate * 0.15)
                || elapsed > 0.5 || now < sampleTime {
                revision &+= 1
                progressTime = nil
            } else if awaitingTransport || !playing || !isPlaying || elapsed > 0.3 {
                progressTime = nil
            } else if elapsed > 0, newPosition - position > 0.002 {
                // A playing flag can precede actual decoding by hundreds of
                // milliseconds. Only forward movement between fresh playing
                // samples establishes a running clock. Seek jumps, source
                // changes and rate acknowledgments cannot supply that proof.
                progressTime = now
            }
        } else {
            progressTime = nil
        }
        if waitingForPause && isPaused { waitingForPause = false }
        if let target = pendingSeek {
            let origin = seekOrigin ?? target
            let distance = abs(target - origin)
            let tolerance = min(max(0.25, newRate * 0.25), max(0.008, distance * 0.3))
            let movement = min(0.02, distance * 0.25)
            let movedToward = target < origin ? newPosition < origin - movement : newPosition > origin + movement
            if abs(newPosition - target) <= tolerance
                || (movedToward && abs(newPosition - target) <= max(0.25, newRate * 0.3)) {
                pendingSeek = nil
            }
        }
        if let target = pendingRate, abs(target - newRate) < 0.001 { pendingRate = nil }
        // The player can decline a speed change or land near a seek target.
        // After settling, use its observed position/rate, never the requested one.
        if let requestedAt, now - requestedAt >= 1.5 { pendingSeek = nil; pendingRate = nil }
        position = max(0, newPosition)
        rate = newRate
        playing = isPlaying
        sampleTime = now
        if !previouslyAllowed && canSchedule(at: now) { revision &+= 1 }
    }

    func canSchedule(at now: TimeInterval) -> Bool {
        guard let sampleTime, let progressTime, now.isFinite, now >= sampleTime else { return false }
        return playing && !waitingForPause && pendingSeek == nil && pendingRate == nil
            && now - sampleTime <= 0.3 && now - progressTime <= 0.3
    }
}
