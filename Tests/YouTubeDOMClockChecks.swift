// Pure clock validation. No web view, network connection or audio device opens.
import Foundation

@main
struct YouTubeDOMClockChecks {
    @MainActor
    static func main() {
        let videoID = "abcdefghijk", loadID = "one-load"
        let url = URL(string: "https://www.youtube.com/embed/\(videoID)?enablejsapi=1")!
        var checks = 0
        func require(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        func packet(_ sequence: Int = 1, _ position: Double = 4, _ generated: Double = 1_700_000_000_000) -> [String: Any] {
            ["loadID": loadID, "videoID": videoID, "kind": "sample", "sequence": sequence,
             "documentID": "00000000-0000-4000-8000-000000000001", "documentStartedAt": 1_699_999_999_900.0,
             "generatedAt": generated, "position": position, "duration": 100.0, "rate": 1.0,
             "paused": false, "ended": false, "seeking": false, "readyState": 4]
        }
        func feed(_ value: [String: Any], to clock: inout YouTubeDOMClock, now: Double = 100,
                  wall: Double = 1_700_000_000, frame: URL? = nil, main: Bool = false) -> YouTubeDOMClock.Event? {
            clock.accept(value, frameURL: frame ?? url, isMainFrame: main, loadID: loadID,
                         videoID: videoID, now: now, wallTime: wall)
        }
        var clock = YouTubeDOMClock()
        require(feed(packet(), to: &clock) != nil, "Current embed's media clock was rejected")
        require(clock.snapshot?.position == 4 && clock.snapshot?.state == 1, "Media state did not decode")
        require(clock.isFresh(at: 100.2) && clock.takesPriority(at: 100.2), "Fresh DOM clock must supersede iframe API")
        require(!clock.isFresh(at: 100.31) && !clock.takesPriority(at: 100.31), "Stale DOM clock must allow basic-player fallback")
        require(feed(packet(), to: &clock) == nil, "Duplicate sequence was accepted")
        var oldLoad = packet(2); oldLoad["loadID"] = "old-load"
        require(feed(oldLoad, to: &clock) == nil, "Prior-load frame overwrote the current recording clock")
        var oldVideo = packet(2); oldVideo["videoID"] = "XXXXXXXXXXX"
        require(feed(oldVideo, to: &clock) == nil, "A different video overwrote the current recording clock")
        require(feed(packet(2), to: &clock, main: true) == nil, "Top-frame messages must not impersonate the media iframe")
        for address in ["http://www.youtube.com/embed/\(videoID)",
                        "https://youtube.com.evil.example/embed/\(videoID)",
                        "https://www.youtube.com/watch?v=\(videoID)",
                        "https://www.youtube.com/embed/XXXXXXXXXXX",
                        "https://www.youtube.com:444/embed/\(videoID)",
                        "https://name@www.youtube.com/embed/\(videoID)"] {
            require(!YouTubeDOMClock.accepts(frameURL: URL(string: address), isMainFrame: false, videoID: videoID),
                    "Foreign or non-embed frame was accepted: \(address)")
        }
        require(YouTubeDOMClock.accepts(frameURL: URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)"),
                                       isMainFrame: false, videoID: videoID), "Privacy-enhanced YouTube embed was rejected")

        var delayed = YouTubeDOMClock()
        require(feed(packet(), to: &delayed, now: 100, wall: 1_700_000_000.1) != nil, "Bounded bridge delay should be supported")
        require(abs(delayed.snapshot!.sampledAt - 99.9) < 0.0001,
                "Sample time used receipt time instead of its generated timestamp")
        require(!delayed.isFresh(at: 100.21), "Bridge delay was omitted from freshness age")
        var stale = YouTubeDOMClock()
        require(feed(packet(), to: &stale, wall: 1_700_000_000.31) == nil, "Queued stale media snapshots were accepted")
        require(feed(packet(), to: &stale, wall: 1_699_999_999.9) == nil, "Future generated timestamps were accepted")
        var malformed = packet(); malformed["position"] = Double.nan
        require(feed(malformed, to: &stale) == nil, "Nonfinite media position was accepted")
        malformed = packet(); malformed["readyState"] = 9
        require(feed(malformed, to: &stale) == nil, "Malformed readiness was accepted")

        var reloaded = YouTubeDOMClock()
        require(feed(packet(99), to: &reloaded) != nil, "Original document was rejected")
        var newDocument = packet(1, 4.1, 1_700_000_000_100)
        newDocument["documentID"] = "00000000-0000-4000-8000-000000000002"
        newDocument["documentStartedAt"] = 1_700_000_000_050.0
        require(feed(newDocument, to: &reloaded, now: 100.1, wall: 1_700_000_000.1) != nil
                    && reloaded.documentRevision == 1, "Same-URL reload could not restart its sequence")
        require(feed(packet(100, 4.15, 1_700_000_000_150), to: &reloaded, now: 100.15, wall: 1_700_000_000.15) == nil,
                "Late previous-document message reclaimed the precise clock")
        require(feed(newDocument, to: &reloaded, now: 100.1, wall: 1_700_000_000.1) == nil,
                "Duplicate sequence in the new document was accepted")
        var forgedEpoch = newDocument
        forgedEpoch["documentID"] = "00000000-0000-4000-8000-000000000003"
        require(feed(forgedEpoch, to: &reloaded, now: 100.1, wall: 1_700_000_000.1) == nil,
                "A different document reused the current document's navigation epoch")
        forgedEpoch = newDocument; forgedEpoch["sequence"] = 2; forgedEpoch["documentStartedAt"] = 1_700_000_000_060.0
        require(feed(forgedEpoch, to: &reloaded, now: 100.1, wall: 1_700_000_000.1) == nil,
                "A document changed its navigation epoch mid-stream")
        var invalidReload = newDocument
        invalidReload["documentID"] = "00000000-0000-4000-8000-000000000003"
        invalidReload["documentStartedAt"] = 1_700_000_000_075.0; invalidReload["position"] = Double.nan
        require(feed(invalidReload, to: &reloaded, now: 100.1, wall: 1_700_000_000.1) == nil
                    && reloaded.documentRevision == 1, "Malformed new document poisoned the accepted epoch")
        newDocument["sequence"] = 2
        require(feed(newDocument, to: &reloaded, now: 100.1, wall: 1_700_000_000.1) != nil
                    && reloaded.documentRevision == 1, "Current document did not recover after rejected messages")

        var blocked = packet(2); blocked["kind"] = "advertisement"
        require(feed(blocked, to: &clock) == .advertisement && clock.advertisement, "Ad indication did not block timing")
        require(clock.takesPriority(at: 1_000) && !clock.isFresh(at: 1_000),
                "A stale advertisement signal allowed iframe fallback to treat ad audio as the song")
        var missing = packet(3); missing["kind"] = "unavailable"
        require(feed(missing, to: &clock) == .unavailable && clock.advertisement,
                "Missing video must not clear a known advertisement")
        require(feed(packet(4), to: &clock) != nil && !clock.advertisement, "Content did not resume after an ad")
        require(feed(missing.merging(["sequence": 5]) { _, newer in newer }, to: &clock) == .unavailable
                    && !clock.isFresh(at: 100), "Removed/multiple media elements kept a precise clock alive")

        var stateClock = YouTubeDOMClock()
        var gate = PlaybackClockGate()
        func observe(_ payload: [String: Any], now: Double, wall: Double) {
            if case .sample(let sample) = feed(payload, to: &stateClock, now: now, wall: wall) {
                gate.observe(position: sample.position, rate: sample.rate, isPlaying: sample.state == 1,
                             isPaused: sample.state == 2 || sample.state == 0, at: sample.sampledAt)
            }
        }
        observe(packet(), now: 100, wall: 1_700_000_000)
        require(!gate.canSchedule(at: 100), "One media-element snapshot must not claim forward playback")
        observe(packet(2, 4.05, 1_700_000_000_050), now: 100.05, wall: 1_700_000_000.05)
        let initialRevision = gate.revision
        // This is the controller's priority rule: an old iframe snapshot must
        // not introduce the observed -165 ms correction during a precise pass.
        if !stateClock.takesPriority(at: 100.1) {
            gate.observe(position: 3.935, rate: 1, isPlaying: true, at: 100.1)
        }
        observe(packet(3, 4.1, 1_700_000_000_100), now: 100.1, wall: 1_700_000_000.1)
        require(gate.revision == initialRevision && gate.canSchedule(at: 100.2),
                "Coarse iframe correction invalidated the fresh media clock")
        var burstClock = YouTubeDOMClock()
        var burstGate = PlaybackClockGate()
        if case .sample(let sample) = feed(packet(), to: &burstClock) {
            burstGate.observe(position: sample.position, rate: sample.rate, isPlaying: true, at: sample.sampledAt)
        }
        if case .sample(let sample) = feed(packet(2, 4.05, 1_700_000_000_050), to: &burstClock, now: 100.05, wall: 1_700_000_000.05) {
            burstGate.observe(position: sample.position, rate: sample.rate, isPlaying: true, at: sample.sampledAt)
        }
        let burstRevision = burstGate.revision
        if case .sample(let sample) = feed(packet(3, 4.05, 1_700_000_000_050), to: &burstClock, now: 100.05025, wall: 1_700_000_000.0505) {
            require(abs(sample.sampledAt - 100.05) < 0.000001, "Same-millisecond media events mapped backwards in host time")
            burstGate.observe(position: sample.position, rate: sample.rate, isPlaying: true, at: sample.sampledAt)
        } else { preconditionFailure("Sub-millisecond bridge clock jitter rejected a valid event") }
        require(burstGate.revision == burstRevision && burstGate.canSchedule(at: 100.051),
                "Duplicate millisecond timestamps reset a running playback epoch")
        require(feed(packet(4, 4.05, 1_700_000_000_050), to: &burstClock, now: 100.051, wall: 1_700_000_000.07) == nil,
                "A larger backwards host-time mapping was silently clamped")
        gate.requestPause()
        observe(packet(4, 4.15, 1_700_000_000_150), now: 100.15, wall: 1_700_000_000.15)
        require(!gate.canSchedule(at: 100.15), "Old playing sample acknowledged a requested pause")
        var paused = packet(5, 4.16, 1_700_000_000_200); paused["paused"] = true
        observe(paused, now: 100.2, wall: 1_700_000_000.2)
        require(stateClock.snapshot?.state == 2 && !gate.canSchedule(at: 100.2), "Paused media element remained playing")
        var seeking = packet(6, 12, 1_700_000_000_250); seeking["seeking"] = true
        observe(seeking, now: 100.25, wall: 1_700_000_000.25)
        require(stateClock.snapshot?.state == 3 && !gate.canSchedule(at: 100.25), "A seek in progress emitted a running clock")
        var explicitWaiting = packet(7, 12, 1_700_000_000_275); explicitWaiting["buffering"] = true
        observe(explicitWaiting, now: 100.275, wall: 1_700_000_000.275)
        require(stateClock.snapshot?.state == 3 && !gate.canSchedule(at: 100.275),
                "Waiting before readyState changes must stop scheduling")
        var waiting = packet(8, 12, 1_700_000_000_300); waiting["readyState"] = 2
        observe(waiting, now: 100.3, wall: 1_700_000_000.3)
        require(stateClock.snapshot?.state == 3 && !gate.canSchedule(at: 100.3), "Buffering media emitted a running clock")
        var slow = packet(9, 12.025, 1_700_000_000_350); slow["rate"] = 0.5
        observe(slow, now: 100.35, wall: 1_700_000_000.35)
        require(stateClock.snapshot?.rate == 0.5 && !gate.canSchedule(at: 100.35), "Resumed media must demonstrate motion at the observed rate")
        slow = packet(10, 12.05, 1_700_000_000_400); slow["rate"] = 0.5
        observe(slow, now: 100.4, wall: 1_700_000_000.4)
        require(gate.canSchedule(at: 100.4), "Observed media progress did not resume correctly")
        var ended = packet(11, 100, 1_700_000_000_450); ended["ended"] = true
        observe(ended, now: 100.45, wall: 1_700_000_000.45)
        require(stateClock.snapshot?.state == 0 && !gate.canSchedule(at: 100.45), "Ended media clock kept running")
        stateClock.reset()
        require(!stateClock.isFresh(at: 100.4) && !stateClock.advertisement, "New load retained old precise state")

        var pauseIntent = YouTubePauseIntentTracker()
        for state in [-1, 5, 3, 2, 2] {
            require(!pauseIntent.observe(state: state), "Initially paused content was treated as a user's pause")
        }
        require(!pauseIntent.observe(state: 1) && pauseIntent.observe(state: 2),
                "Observed content pause did not emit intent")
        require(!pauseIntent.observe(state: 2), "Repeated paused snapshots duplicated intent")
        require(!pauseIntent.observe(state: 1) && !pauseIntent.observe(state: 3) && pauseIntent.observe(state: 2),
                "A user pause during buffering was lost")
        require(!pauseIntent.observe(state: 1) && !pauseIntent.observe(state: 0) && !pauseIntent.observe(state: 2),
                "Video completion was mistaken for pause intent")
        #if canImport(WebKit)
        var events: [String] = []
        let controller = YouTubeController()
        controller.onPauseIntent = { events.append("pause") }
        controller.onClockReset = { events.append("clock") }
        controller.pause() // No loaded view: must still cancel pending analysis immediately.
        require(events == ["pause", "clock"], "Native pause did not report intent before invalidating its clock")
        events.removeAll()
        controller.seek(to: 0); controller.play(); controller.playFromStart()
        require(!events.contains("pause"), "Internal seek-and-play restart emitted pause intent")
        #endif
        print("YouTube media-clock checks passed (\(checks)): frame/document isolation, timestamps, source priority, ads and pause intent.")
    }
}
