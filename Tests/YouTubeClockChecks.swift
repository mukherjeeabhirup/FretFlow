// Foundation-only checks. Compile with PlaybackClock.swift and
// YouTubeController.swift; WebKit code is excluded automatically on Linux.
import Foundation

@main struct YouTubeClockChecks {
    static func main() {
        var poll = YouTubeClockPollGate()
        precondition(poll.request(at: 10) == nil)
        poll.received(identity: "load/document", at: 10)
        precondition(poll.request(at: 10.05) == nil)
        let first = poll.request(at: 10.13)!
        precondition(poll.request(at: 10.4) == nil, "Polls must remain single-flight")
        let replacement = poll.request(at: 10.64)!
        poll.finish(first)
        precondition(poll.request(at: 10.7) == nil, "Retired completion cleared the replacement poll")
        poll.finish(replacement)
        precondition(poll.request(at: 10.71) != nil, "A suspended completion permanently wedged polling")
        poll.reset()
        precondition(poll.request(at: 11) == nil, "Retired document remained pollable")
        poll.received(identity: "new/document", at: 11)
        let establishing = poll.request(at: 11.05, establishingPlayback: true)!
        poll.received(identity: "third/document", at: 11.1)
        let third = poll.request(at: 11.15, establishingPlayback: true)!
        poll.finish(establishing)
        precondition(poll.request(at: 11.2, establishingPlayback: true) == nil)
        poll.finish(third)
        poll.received(identity: "third/document", at: 11.2)
        precondition(poll.request(at: 11.25) == nil, "Fresh page timers should suppress native polls")
        precondition(poll.request(at: .nan) == nil)
        precondition(poll.request(at: 11.1) == nil)

        func payload(_ sequence: Int, _ generated: Double) -> [String: Any] {
            ["sequence": sequence, "generatedAt": generated]
        }
        var bridge = YouTubePlayerClock()
        let timestamp = 1_700_000_000_000.0
        precondition(abs(bridge.accept(payload(1, timestamp), now: 100, wallTime: timestamp / 1_000 + 0.1)! - 99.9) < 1e-6)
        precondition(bridge.accept(payload(1, timestamp), now: 100, wallTime: timestamp / 1_000) == nil)
        precondition(bridge.accept(payload(2, timestamp), now: 100.5, wallTime: timestamp / 1_000 + 0.5) == nil,
                     "Queued background snapshot was refreshed at receipt")
        precondition(bridge.accept(payload(2, timestamp + 600), now: 100.6, wallTime: timestamp / 1_000 + 0.6) != nil)
        precondition(bridge.accept(payload(3, timestamp + 500), now: 100.7, wallTime: timestamp / 1_000 + 0.7) == nil)
        precondition(bridge.accept(payload(3, .nan), now: 100.7, wallTime: timestamp / 1_000 + 0.7) == nil)
        precondition(bridge.accept(payload(3, timestamp + 900), now: 100.7, wallTime: timestamp / 1_000 + 0.7) == nil)
        bridge.reset()
        precondition(bridge.accept(payload(1, timestamp), now: 100, wallTime: timestamp / 1_000) != nil)

        var terminal = YouTubePlayerClock()
        precondition(terminal.accept(payload(1, timestamp), now: 100, wallTime: timestamp / 1_000) != nil)
        var delayedError = payload(2, timestamp + 100)
        delayedError["kind"] = "error"
        precondition(terminal.acceptTerminalError(delayedError, wallTime: timestamp / 1_000 + 5),
                     "A terminal error queued during suspension must not expire like a clock sample")
        precondition(!terminal.acceptTerminalError(delayedError, wallTime: timestamp / 1_000 + 5),
                     "Duplicate terminal events must not be accepted")
        var nonTerminal = payload(3, timestamp + 200)
        nonTerminal["kind"] = "snapshot"
        precondition(!terminal.acceptTerminalError(nonTerminal, wallTime: timestamp / 1_000 + 5))
        var futureError = payload(3, timestamp + 10_000)
        futureError["kind"] = "error"
        precondition(!terminal.acceptTerminalError(futureError, wallTime: timestamp / 1_000 + 5))
        var expiredClock = payload(3, timestamp + 200)
        expiredClock["kind"] = "snapshot"
        precondition(terminal.accept(expiredClock, now: 105, wallTime: timestamp / 1_000 + 5) == nil,
                     "Accepting lifecycle errors must not relax clock freshness")

        let frame = URL(string: "https://www.youtube.com/embed/abcdefghijk")!
        var media = YouTubeDOMClock()
        var gate = PlaybackClockGate()
        func sample(_ sequence: Int, position: Double, now: Double) {
            let packet: [String: Any] = ["sequence": sequence, "generatedAt": timestamp + (now - 100) * 1_000,
                "loadID": "load", "videoID": "abcdefghijk", "kind": "sample",
                "documentID": "00000000-0000-4000-8000-000000000001", "documentStartedAt": timestamp - 100,
                "position": position, "duration": 100.0, "rate": 1.0,
                "paused": false, "ended": false, "seeking": false, "readyState": 4]
            guard case .sample(let observed) = media.accept(packet, frameURL: frame, isMainFrame: false,
                loadID: "load", videoID: "abcdefghijk", now: now, wallTime: timestamp / 1_000 + now - 100) else {
                preconditionFailure("Synthetic media sample was rejected")
            }
            gate.observe(position: observed.position, rate: observed.rate, isPlaying: observed.state == 1, at: observed.sampledAt)
        }
        sample(1, position: 4, now: 100)
        precondition(!YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: true, at: 100))
        sample(2, position: 4.05, now: 100.05)
        precondition(YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: true, at: 100.1))
        for source in [YouTubeClockSource.none, .iframe, .advertisement] {
            precondition(!source.canSchedule(gate: gate, media: media, isReady: true, at: 100.1),
                         "An approximate or retired source scheduled clicks")
        }
        precondition(!YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: false, at: 100.1))
        precondition(!YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: true, at: 100.36),
                     "Background suspension kept an old clock running")
        gate.invalidateSource()
        sample(3, position: 6, now: 102)
        precondition(!YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: true, at: 102))
        for index in 4...12 { sample(index, position: 6, now: 102 + Double(index - 3) * 0.05) }
        precondition(!YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: true, at: 102.45),
                     "Fresh playing flags with a frozen media position enabled clicks")
        sample(13, position: 6.05, now: 102.5)
        precondition(YouTubeClockSource.mediaElement.canSchedule(gate: gate, media: media, isReady: true, at: 102.5))
        print("YouTube clock checks passed: poll retirement, identity, bridge age, source safety, background gaps and frozen media.")
    }
}
