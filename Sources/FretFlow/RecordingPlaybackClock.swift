import Foundation

/// Relates captured audio presentation timestamps to the observed video clock.
/// A seek or speed change starts a new epoch; old audio must never cross it.
struct RecordingPlaybackClock {
    private struct Anchor {
        let host: Double
        let position: Double
        let rate: Double
    }
    private var epoch: Anchor?
    private var origin: Anchor?
    private var latest: Anchor?
    private var calibrationObservations = [Anchor]()
    private var progressHost: Double?
    private var highWaterPosition = 0.0
    private var revision: UInt64?
    var isReady: Bool { origin != nil }
    private(set) var calibrationSampleCount = 0
    /// Interquartile spread of calibration samples, measured in wall seconds.
    private(set) var calibrationJitter: Double?
    /// Correction to the first raw content position, measured in content seconds.
    private(set) var calibrationCorrection: Double?

    mutating func reset() {
        epoch = nil
        origin = nil
        latest = nil
        calibrationObservations.removeAll(keepingCapacity: true)
        progressHost = nil
        highWaterPosition = 0
        revision = nil
        calibrationSampleCount = 0
        calibrationJitter = nil
        calibrationCorrection = nil
    }

    mutating func observe(position: Double, rate: Double, host: Double, revision: UInt64) {
        guard position.isFinite, position >= 0, rate.isFinite, (0.125...4).contains(rate), host.isFinite else { reset(); return }
        if self.revision != revision || (latest.map { host <= $0.host || host - $0.host > 0.3 || $0.rate != rate } ?? false) {
            reset()
        }
        self.revision = revision
        let observation = Anchor(host: host, position: position, rate: rate)
        if epoch == nil {
            epoch = observation
            progressHost = host
            highWaterPosition = position
        } else if position > highWaterPosition + 0.002 {
            progressHost = host
            highWaterPosition = position
        }
        latest = observation
        calibrate(with: observation)
    }

    private mutating func calibrate(with observation: Anchor) {
        guard origin == nil, let epoch else { return }
        let age = observation.host - epoch.host
        // YouTube's first playing snapshot may still contain startup error.
        // Let the clock settle before choosing its permanent audio origin.
        guard age >= 0.4 - 1e-9 else { return }
        calibrationObservations.append(observation)
        calibrationObservations.removeAll { observation.host - $0.host > 0.8 + 1e-9 }
        if calibrationObservations.count > 120 { calibrationObservations.removeFirst(calibrationObservations.count - 120) }
        calibrationSampleCount = calibrationObservations.count
        guard age >= 1.2 - 1e-9, calibrationSampleCount >= 8 else { return }
        let intercepts = calibrationObservations.map {
            $0.position - ($0.host - epoch.host) * epoch.rate
        }.sorted()
        let position = Self.median(intercepts)
        let lower = intercepts[Int(Double(intercepts.count - 1) * 0.25)]
        let upper = intercepts[Int(Double(intercepts.count - 1) * 0.75)]
        let jitter = (upper - lower) / epoch.rate
        calibrationJitter = jitter
        // Ordinary observation jitter is expected. Defer only an obviously
        // unstable clock; the caller can continue buffering compact envelopes.
        guard position.isFinite, jitter.isFinite, jitter <= 0.08 else { return }
        origin = Anchor(host: epoch.host, position: position, rate: epoch.rate)
        calibrationCorrection = position - epoch.position
        calibrationObservations.removeAll(keepingCapacity: true)
    }

    private static func median(_ input: [Double]) -> Double {
        let values = input.sorted()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    func mediaTime(for host: Double, now: Double) -> Double? {
        guard host.isFinite, now.isFinite, let origin, let latest, let progressHost,
              host >= origin.host, host >= latest.host - 3,
              (0...0.3).contains(now - latest.host), (0...0.3).contains(now - progressHost),
              host <= latest.host + 0.15 else { return nil }
        // YouTube corrects its observed clock by a few milliseconds between
        // snapshots. Choosing a new nearest anchor for every audio window can
        // turn those corrections into backward timestamps, falsely marking a
        // continuous recording as a seek. Keep one calibrated origin/rate for
        // this confirmed playback epoch. Later observations establish freshness
        // and progress; actual seeks, rate changes and stalls change the revision.
        let position = origin.position + (host - origin.host) * origin.rate
        return position >= 0 && position.isFinite ? position : nil
    }
}
