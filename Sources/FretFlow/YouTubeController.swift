import Foundation
#if canImport(WebKit)
import AppKit
import Combine
import SwiftUI
import WebKit
#endif

/// Pure validation and freshness tracking for the read-only embed media clock.
struct YouTubeDOMClock {
    struct Snapshot: Equatable {
        let position: Double
        let duration: Double
        let rate: Double
        let state: Int
        let sampledAt: Double
    }
    enum Event: Equatable { case sample(Snapshot), advertisement, unavailable }
    private(set) var snapshot: Snapshot?
    private(set) var advertisement = false
    private(set) var documentRevision: UInt64 = 0
    private(set) var documentID: String?
    private var documentStartedAt: Double?
    private var lastSequence = -1
    private var lastGeneratedAt: Double?
    private var lastSampledAt: Double?

    mutating func reset() { self = YouTubeDOMClock() }

    func isFresh(at now: Double) -> Bool {
        guard !advertisement, let snapshot, now.isFinite else { return false }
        return now >= snapshot.sampledAt && now - snapshot.sampledAt <= 0.3
    }

    func takesPriority(at now: Double) -> Bool { advertisement || isFresh(at: now) }

    static func accepts(frameURL: URL?, isMainFrame: Bool, videoID: String) -> Bool {
        guard !isMainFrame, let frameURL, let components = URLComponents(url: frameURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              let host = components.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host),
              components.port == nil || components.port == 443 else { return false }
        return components.path == "/embed/" + videoID
    }

    mutating func accept(_ payload: [String: Any], frameURL: URL?, isMainFrame: Bool,
                         loadID: String, videoID: String, now: Double, wallTime: Double) -> Event? {
        guard Self.accepts(frameURL: frameURL, isMainFrame: isMainFrame, videoID: videoID),
              payload["loadID"] as? String == loadID, payload["videoID"] as? String == videoID,
              let incomingDocument = payload["documentID"] as? String, UUID(uuidString: incomingDocument) != nil,
              let started = (payload["documentStartedAt"] as? NSNumber)?.doubleValue, started.isFinite, started > 0,
              let sequence = payload["sequence"] as? Int, sequence > 0,
              let generated = (payload["generatedAt"] as? NSNumber)?.doubleValue, generated.isFinite,
              now.isFinite, wallTime.isFinite,
              let kind = payload["kind"] as? String else { return nil }
        let age = wallTime - generated / 1_000
        guard age >= -0.025, age <= 0.3, started <= generated + 25,
              lastGeneratedAt.map({ generated >= $0 }) ?? true else { return nil }
        let changesDocument = incomingDocument != documentID
        if changesDocument {
            // A same-URL iframe reload has a new document and a fresh sequence.
            // Its navigation time must advance; delayed old-document messages
            // can never reclaim the clock, even with a higher sequence number.
            guard documentStartedAt.map({ started > $0 }) ?? true else { return nil }
        } else {
            guard started == documentStartedAt, sequence > lastSequence else { return nil }
        }
        let measuredSampledAt = now - max(0, age)
        if let lastSampledAt, measuredSampledAt < lastSampledAt - 0.002 { return nil }
        // Date.now has millisecond resolution. Two events in the same tick
        // can map a fraction of a millisecond backwards because native wall
        // and monotonic clocks are read separately. Keep that mapping monotonic;
        // larger time regressions and media-position jumps remain invalid.
        let sampledAt = max(lastSampledAt ?? measuredSampledAt, measuredSampledAt)
        let event: Event
        switch kind {
        case "advertisement": event = .advertisement
        case "unavailable": event = .unavailable
        case "sample":
            func value(_ key: String) -> Double? {
                guard let value = (payload[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
                return value
            }
            guard let position = value("position"), position >= 0,
                  let duration = value("duration"), duration > 0, position <= duration + 0.5,
                  let rate = value("rate"), (0.125...4).contains(rate),
                  let paused = payload["paused"] as? Bool, let ended = payload["ended"] as? Bool,
                  let seeking = payload["seeking"] as? Bool,
                  let readyState = payload["readyState"] as? Int, (0...4).contains(readyState) else { return nil }
            let buffering = payload["buffering"] as? Bool ?? false
            let state = ended ? 0 : (paused ? 2 : (seeking || buffering || readyState < 3 ? 3 : 1))
            event = .sample(Snapshot(position: min(position, duration), duration: duration, rate: rate,
                                     state: state, sampledAt: sampledAt))
        default: return nil
        }
        if changesDocument {
            if documentID != nil { documentRevision &+= 1 }
            documentID = incomingDocument
            documentStartedAt = started
        }
        lastSequence = sequence
        lastGeneratedAt = generated
        lastSampledAt = sampledAt
        switch event {
        case .sample(let value): snapshot = value; advertisement = false
        case .advertisement: snapshot = nil; advertisement = true
        case .unavailable: snapshot = nil // Keep an ad block until a real content sample clears it.
        }
        return event
    }
}

/// A paused initial load, buffering and a finished video are not pause intent.
/// Arm only after content has actually played, including through buffering.
struct YouTubePauseIntentTracker {
    private var hasObservedPlaying = false

    mutating func observe(state: Int) -> Bool {
        if state == 1 { hasObservedPlaying = true; return false }
        if state == 2 {
            let pausedPlayback = hasObservedPlaying
            hasObservedPlaying = false
            return pausedPlayback
        }
        if state == 0 || state == 5 || state == -1 { hasObservedPlaying = false }
        return false
    }
}

/// Single-flight native watchdog for WebKit's background timer throttling.
/// A completion from a retired load/document cannot clear a newer request.
struct YouTubeClockPollGate {
    private var identity: String?
    private var lastReceived: Double?
    private var lastRequested: Double?
    private var serial: UInt64 = 0
    private var pending: UInt64?
    private var pendingSince: Double?

    mutating func reset() {
        serial &+= 1
        identity = nil; lastReceived = nil; lastRequested = nil; pending = nil; pendingSince = nil
    }

    mutating func received(identity: String, at now: Double) {
        guard !identity.isEmpty, now.isFinite else { return }
        if self.identity != identity { reset(); self.identity = identity }
        lastReceived = now
    }

    mutating func request(at now: Double, establishingPlayback: Bool = false) -> UInt64? {
        guard now.isFinite else { return nil }
        // WebKit may suspend a JavaScript completion while hidden. Retire it
        // after a bounded wait so it cannot wedge polling for the whole load.
        if let pendingSince, now - pendingSince >= 0.5 { pending = nil; self.pendingSince = nil }
        guard identity != nil, pending == nil, let lastReceived,
              now - lastReceived >= (establishingPlayback ? 0.04 : 0.12),
              lastRequested.map({ now - $0 >= 0.04 }) ?? true else { return nil }
        serial &+= 1
        pending = serial
        pendingSince = now
        lastRequested = now
        return serial
    }

    mutating func finish(_ ticket: UInt64) {
        if pending == ticket { pending = nil; pendingSince = nil }
    }
}

/// Timestamp the iframe bridge at generation, never at receipt. Native polls
/// cannot turn queued background messages into a fresh transport observation.
struct YouTubePlayerClock {
    private var sequence = 0
    private var generatedAt: Double?
    private var sampledAt: Double?

    mutating func reset() { self = YouTubePlayerClock() }

    /// Terminal errors are lifecycle events, not clock observations. Keep their
    /// sequence/generation ordering but accept delayed delivery for this load.
    mutating func acceptTerminalError(_ payload: [String: Any], wallTime: Double) -> Bool {
        guard payload["kind"] as? String == "error",
              let incoming = payload["sequence"] as? Int, incoming > sequence,
              let generated = (payload["generatedAt"] as? NSNumber)?.doubleValue,
              generated.isFinite, generated > 0, wallTime.isFinite,
              generated / 1_000 <= wallTime + 0.025,
              generatedAt.map({ generated >= $0 }) ?? true else { return false }
        sequence = incoming
        generatedAt = generated
        return true
    }

    mutating func accept(_ payload: [String: Any], now: Double, wallTime: Double) -> Double? {
        guard let incomingSequence = payload["sequence"] as? Int, incomingSequence > sequence,
              let generated = (payload["generatedAt"] as? NSNumber)?.doubleValue,
              generated.isFinite, now.isFinite, wallTime.isFinite,
              generatedAt.map({ generated >= $0 }) ?? true else { return nil }
        let age = wallTime - generated / 1_000
        guard age >= -0.025, age <= 0.3 else { return nil }
        let measured = now - max(0, age)
        guard sampledAt.map({ measured >= $0 - 0.002 }) ?? true else { return nil }
        sequence = incomingSequence
        generatedAt = generated
        sampledAt = max(sampledAt ?? measured, measured)
        return sampledAt
    }
}

enum YouTubeClockSource: String {
    case none, iframe, mediaElement, advertisement

    func canSchedule(gate: PlaybackClockGate, media: YouTubeDOMClock, isReady: Bool, at now: Double) -> Bool {
        isReady && self == .mediaElement && media.isFresh(at: now) && gate.canSchedule(at: now)
    }
}

#if canImport(WebKit)
@MainActor
final class YouTubeController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var title = ""
    @Published private(set) var status = "Link a YouTube video to this song."
    @Published private(set) var rate: Double = 1
    @Published private(set) var availableRates: [Double] = [1]
    @Published private(set) var videoID = ""
    var onClockReset: (() -> Void)?
    var onPauseIntent: (() -> Void)?
    /// Once per successful cue, after metadata/rates are applied. Install before
    /// cue(), then restore persisted position/rate here without starting playback.
    var onReady: (() -> Void)?
    private var clickClock = PlaybackClockGate()
    private var mediaClock = YouTubeDOMClock()
    private var pauseIntent = YouTubePauseIntentTracker()
    private var sourceRevision: UInt64 = 0
    private var clockSource = YouTubeClockSource.none
    var clockSourceName: String { clockSource.rawValue }
    var isPaused: Bool { [0, 2, 5].contains(lastPlayerState) }
    var clockRevision: UInt64 { clickClock.revision &+ sourceRevision }
    var hasFreshPlaybackClock: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        // The iframe API extrapolates its cached time even when no fresh media
        // state arrives. It is useful for controls/display, but cannot prove
        // decoding progress for clicks or recording.
        return clockSource.canSchedule(gate: clickClock, media: mediaClock, isReady: isReady, at: now)
    }
    var hasPrecisePlaybackClock: Bool {
        hasFreshPlaybackClock && clockSource == .mediaElement
            && mediaClock.isFresh(at: ProcessInfo.processInfo.systemUptime)
    }

    private var sampledAt = ProcessInfo.processInfo.systemUptime
    private var loadID = UUID().uuidString
    private var hasLoadedVideo = false
    private var loadTimeout: Task<Void, Never>?
    private var lastPlayerState = -1
    private var hasPlaybackError = false
    private let appOrigin = URL(string: "https://com.local.fretflow")!
    private static let clockWorld = WKContentWorld.world(name: "FretFlowClock")
    private var clockScript: WKUserScript?
    private var mediaFrame: WKFrameInfo?
    private var clockPollTimer: Timer?
    private var clockPollGate = YouTubeClockPollGate()
    private var playerPollGate = YouTubeClockPollGate()
    private var playerClock = YouTubePlayerClock()

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakYouTubeMessageHandler(self), name: "youtube")
        configuration.userContentController.add(WeakYouTubeMessageHandler(self), contentWorld: Self.clockWorld, name: "youtubeClock")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.loadHTMLString(Self.emptyHTML, baseURL: appOrigin)
        return view
    }()

    deinit { loadTimeout?.cancel(); clockPollTimer?.invalidate() }

    var interpolatedPosition: Double {
        // Match the click gate's freshness window so a stalled snapshot cannot
        // move the green playhead on after scheduled audio has been stopped.
        let elapsed = hasFreshPlaybackClock ? min(0.3, max(0, ProcessInfo.processInfo.systemUptime - sampledAt)) * rate : 0
        let value = position + elapsed
        return max(0, duration > 0 ? min(value, duration) : value)
    }

    func cue(videoID input: String) {
        guard let identifier = Self.videoID(from: input) else {
            status = "Paste a valid YouTube video link or 11-character video ID."
            return
        }
        if identifier == videoID, isReady, !hasPlaybackError { return }
        let oldPlayer = hasLoadedVideo
        if oldPlayer { webView.evaluateJavaScript("window.fretFlowPlayer && window.fretFlowPlayer.pause()", completionHandler: nil) }
        resetPlayback()
        videoID = identifier
        loadID = UUID().uuidString
        status = "Loading YouTube…"
        guard let html = loadPlayerHTML() else {
            status = "The bundled YouTube player is missing. Rebuild FretFlow to restore it."
            return
        }
        let configuration: [String: String] = ["videoID": identifier, "loadID": loadID, "origin": appOrigin.absoluteString]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        hasLoadedVideo = true
        installMediaClock(configurationJSON: json)
        webView.stopLoading()
        webView.loadHTMLString(html.replacingOccurrences(of: "__FRETFLOW_CONFIG__", with: json), baseURL: appOrigin)
        // Poll even if the first ready packet was queued while hidden. Waiting
        // for an accepted packet to seed this gate could prevent recovery.
        playerPollGate.received(identity: loadID, at: ProcessInfo.processInfo.systemUptime)
        startClockPolling()
        let expectedLoad = loadID
        loadTimeout?.cancel()
        loadTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            guard let self, self.loadID == expectedLoad, !self.isReady, !self.hasPlaybackError else { return }
            self.status = "YouTube is taking too long to load. Check your connection, then link the video again."
        }
    }

    func clear() {
        loadTimeout?.cancel()
        loadTimeout = nil
        loadID = UUID().uuidString
        removeMediaClockScript()
        if hasLoadedVideo {
            webView.evaluateJavaScript("window.fretFlowPlayer && window.fretFlowPlayer.pause()", completionHandler: nil)
            webView.stopLoading()
            webView.loadHTMLString(Self.emptyHTML, baseURL: appOrigin)
        }
        hasLoadedVideo = false
        resetPlayback()
        videoID = ""
        status = "Link a YouTube video to this song."
    }

    func play() { clickClock.requestPlay(); onClockReset?(); perform("play") }
    func playFromStart() {
        clickClock.requestSeek(0, from: interpolatedPosition, at: ProcessInfo.processInfo.systemUptime)
        clickClock.requestPlay()
        onClockReset?()
        perform("playFromStart")
    }
    func pause() { onPauseIntent?(); clickClock.requestPause(); onClockReset?(); perform("pause") }
    func togglePlayback() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        clickClock.requestSeek(target, from: interpolatedPosition, at: ProcessInfo.processInfo.systemUptime)
        onClockReset?()
        perform("seek", arguments: [target])
    }

    func setRate(_ value: Double) {
        guard value.isFinite, availableRates.contains(where: { abs($0 - value) < 0.001 }) else { return }
        guard abs(value - rate) > 0.001 else { return }
        clickClock.requestRate(value, at: ProcessInfo.processInfo.systemUptime)
        onClockReset?()
        // YouTube may decline a rate request. The published value comes only
        // from player observations, including onPlaybackRateChange.
        perform("setRate", arguments: [value])
    }

    nonisolated static func videoID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ value: String) -> String? {
            value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil ? value : nil
        }
        if let identifier = valid(trimmed) { return identifier }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return nil }
        if let port = components.port, port != (scheme == "https" ? 443 : 80) { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        if ["youtu.be", "www.youtu.be"].contains(host) {
            return parts.count == 1 ? valid(parts[0]) : nil
        }
        guard ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host) else { return nil }
        if parts == ["watch"] {
            let values = (components.queryItems ?? []).filter { $0.name == "v" }.compactMap(\.value)
            return values.count == 1 ? valid(values[0]) : nil
        }
        if parts.count == 2, ["embed", "shorts", "live", "v"].contains(parts[0]) {
            return valid(parts[1])
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "youtubeClock" {
            let previousDocumentRevision = mediaClock.documentRevision
            guard !hasPlaybackError, hasLoadedVideo, let payload = message.body as? [String: Any],
                  let event = mediaClock.accept(payload, frameURL: message.frameInfo.request.url,
                                                isMainFrame: message.frameInfo.isMainFrame,
                                                loadID: loadID, videoID: videoID,
                                                now: ProcessInfo.processInfo.systemUptime,
                                                wallTime: Date().timeIntervalSince1970) else { return }
            retainMediaClockFrame(message.frameInfo)
            if mediaClock.documentRevision != previousDocumentRevision {
                pauseIntent = YouTubePauseIntentTracker()
                clickClock.invalidateSource()
                sourceRevision &+= 1
                onClockReset?()
            }
            receiveMediaClock(event)
            return
        }
        guard message.name == "youtube", message.frameInfo.isMainFrame, hasLoadedVideo, !hasPlaybackError,
              let payload = message.body as? [String: Any],
              payload["loadID"] as? String == loadID,
              payload["videoID"] as? String == videoID,
              let kind = payload["kind"] as? String else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wallTime = Date().timeIntervalSince1970
        let playerSampleTime: Double
        if kind == "error" {
            // Identity and main-frame validation above still apply. An old
            // error must stop playback, never be treated as fresh media time.
            guard playerClock.acceptTerminalError(payload, wallTime: wallTime) else { return }
            playerSampleTime = now
        } else {
            guard let sample = playerClock.accept(payload, now: now, wallTime: wallTime) else { return }
            playerSampleTime = sample
        }
        playerPollGate.received(identity: loadID, at: ProcessInfo.processInfo.systemUptime)
        startClockPolling()
        switch kind {
        case "ready", "snapshot", "state", "rate":
            guard !hasPlaybackError else { return }
            // A ready event may have spent too long queued while hidden. A
            // later fresh snapshot can establish readiness without replaying
            // that stale position or losing the caller's restore callback.
            let becameReady = !isReady && (kind == "ready" || payload["ready"] as? Bool == true)
            if becameReady { loadTimeout?.cancel(); isReady = true }
            updateSnapshot(payload, at: playerSampleTime)
            if becameReady || kind == "state" { updatePlayerStatus() }
            if becameReady { onReady?() }
        case "blocked":
            clickClock.reset(); onClockReset?()
            isPlaying = false
            status = "Click Play inside the YouTube player to enable playback."
        case "error":
            clickClock.reset(); onClockReset?()
            stopClockPolling()
            loadTimeout?.cancel()
            isReady = false
            isPlaying = false
            hasPlaybackError = true
            let code = (payload["code"] as? NSNumber)?.intValue ?? 0
            switch code {
            case 2: status = "YouTube could not read this video ID. Check the video link."
            case 5: status = "YouTube cannot play this video here. Try another upload or open it on YouTube."
            case 100: status = "This video is private, removed, or unavailable. Link another video."
            case 101, 150: status = "The owner disabled embedded playback. Link another upload of this song."
            case 153: status = "YouTube could not verify this app. Relaunch the installed FretFlow app and try again."
            default: status = "YouTube could not load. Check your connection and link the video again."
            }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let isWebURL = ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        if navigationAction.navigationType == .linkActivated, isWebURL {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           isWebURL, url.host?.lowercased() != appOrigin.host {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // YouTube loads its media and consent UI in nested frames. Restricting
        // their domains here would break legitimate playback and sign-in flows.
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { reportNavigationError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { reportNavigationError(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopClockPolling()
        hasPlaybackError = true
        clickClock.reset(); onClockReset?()
        isReady = false
        isPlaying = false
        status = "The video player stopped. Link the video again to reload it."
    }

    private func perform(_ method: String, arguments: [Double] = []) {
        guard isReady, !videoID.isEmpty else { return }
        let argumentsText = arguments.map(String.init(describing:)).joined(separator: ",")
        let expectedLoad = loadID
        webView.evaluateJavaScript("window.fretFlowPlayer && window.fretFlowPlayer.\(method)(\(argumentsText))") { [weak self] _, error in
            guard let self, self.loadID == expectedLoad, error != nil else { return }
            self.status = "The player did not respond. Click Play inside the video, or link it again."
        }
    }

    private func updateSnapshot(_ payload: [String: Any], at sampleTime: Double) {
        let previousRevision = clickClock.revision
        func finite(_ key: String) -> Double? {
            guard let value = (payload[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        if let values = payload["rates"] as? [NSNumber] {
            let rates = Array(Set(values.map(\.doubleValue).filter { $0.isFinite && $0 > 0 })).sorted()
            availableRates = rates.isEmpty ? [1] : rates
        }
        if let value = payload["title"] as? String, !value.isEmpty { title = value }
        // The iframe API's cached currentTime can step backwards by >150 ms.
        // It remains the control/metadata API, but must not overwrite a fresh
        // media element timestamp or acknowledge transport on its behalf.
        let now = ProcessInfo.processInfo.systemUptime
        guard !mediaClock.takesPriority(at: now) else { return }
        selectClockSource(.iframe)
        if let value = finite("position") { position = max(0, value) }
        if let value = finite("duration") { duration = max(0, value) }
        if duration > 0 { position = min(position, duration) }
        sampledAt = sampleTime
        if let value = finite("rate"), value > 0 { rate = value }
        if let state = (payload["state"] as? NSNumber)?.intValue {
            lastPlayerState = state
            isPlaying = state == 1
            if pauseIntent.observe(state: state) { onPauseIntent?() }
        }
        if finite("position") != nil, finite("rate") != nil, payload["state"] is NSNumber {
            clickClock.observe(position: position, rate: rate, isPlaying: isPlaying,
                               isPaused: lastPlayerState == 2 || lastPlayerState == 0, at: sampledAt)
        }
        if clickClock.revision != previousRevision { onClockReset?() }
    }

    private func receiveMediaClock(_ event: YouTubeDOMClock.Event) {
        switch event {
        case .sample(let sample):
            let previousRevision = clickClock.revision
            selectClockSource(.mediaElement)
            position = sample.position
            duration = sample.duration
            rate = sample.rate
            sampledAt = sample.sampledAt
            lastPlayerState = sample.state
            isPlaying = sample.state == 1
            if pauseIntent.observe(state: sample.state) { onPauseIntent?() }
            clickClock.observe(position: position, rate: rate, isPlaying: isPlaying,
                               isPaused: sample.state == 2 || sample.state == 0, at: sampledAt)
            if clickClock.revision != previousRevision { onClockReset?() }
            if isReady { updatePlayerStatus() }
        case .advertisement:
            if isPlaying || clockSource != .advertisement {
                isPlaying = false
                lastPlayerState = 3
                // Preserve pending pause/seek/rate acknowledgments; the source
                // revision alone invalidates queued clicks and analysis epochs.
                selectClockSource(.advertisement)
                status = "Waiting for the linked video after YouTube's advertisement…"
            }
        case .unavailable:
            if clockSource == .mediaElement {
                isPlaying = false
                clickClock.invalidateSource()
                onClockReset?()
            }
        }
    }

    private func selectClockSource(_ source: YouTubeClockSource) {
        guard source != clockSource else { return }
        clockSource = source
        clickClock.invalidateSource()
        sourceRevision &+= 1
        onClockReset?()
    }

    private func updatePlayerStatus() {
        switch lastPlayerState {
        case 0: status = "Video finished"
        case 1: status = "Playing on YouTube"
        case 2: status = "Paused"
        case 3: status = "YouTube is buffering…"
        case 5, -1: status = "Ready. Press Play to start."
        default: break
        }
    }

    private func resetPlayback() {
        stopClockPolling()
        mediaClock.reset()
        playerClock.reset()
        pauseIntent = YouTubePauseIntentTracker()
        clockSource = .none
        sourceRevision &+= 1
        clickClock.reset(); onClockReset?()
        isReady = false
        isPlaying = false
        position = 0
        duration = 0
        title = ""
        rate = 1
        availableRates = [1]
        sampledAt = ProcessInfo.processInfo.systemUptime
        lastPlayerState = -1
        hasPlaybackError = false
    }

    private func reportNavigationError(_ error: Error) {
        guard hasLoadedVideo, (error as NSError).code != NSURLErrorCancelled else { return }
        stopClockPolling()
        hasPlaybackError = true
        clickClock.reset(); onClockReset?()
        isReady = false
        isPlaying = false
        status = "Could not connect to YouTube. Check your connection and link the video again."
    }

    private func loadPlayerHTML() -> String? {
        loadBundledText(name: "YouTube", extension: "html")
    }

    private func retainMediaClockFrame(_ frame: WKFrameInfo) {
        guard let documentID = mediaClock.documentID else { return }
        mediaFrame = frame
        clockPollGate.received(identity: loadID + "/" + documentID, at: ProcessInfo.processInfo.systemUptime)
        startClockPolling()
    }

    private func startClockPolling() {
        guard clockPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollMediaClockIfNeeded() }
        }
        clockPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollMediaClockIfNeeded() {
        pollPlayerClockIfNeeded()
        guard hasLoadedVideo, !hasPlaybackError, let frame = mediaFrame,
              YouTubeDOMClock.accepts(frameURL: frame.request.url, isMainFrame: frame.isMainFrame, videoID: videoID),
              let documentID = mediaClock.documentID else { return }
        let expected: [String: String] = ["loadID": loadID, "videoID": videoID, "documentID": documentID]
        guard let data = try? JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              let ticket = clockPollGate.request(at: ProcessInfo.processInfo.systemUptime,
                                                establishingPlayback: isPlaying && !hasFreshPlaybackClock) else { return }
        // This calls only our read-only helper in the already validated child
        // frame and the same isolated content world as its message handler.
        let script = "window.__fretFlowReadClock ? window.__fretFlowReadClock(\(json)) : false"
        webView.evaluateJavaScript(script, in: frame, in: Self.clockWorld) { [weak self] _ in
            self?.clockPollGate.finish(ticket)
        }
    }

    private func pollPlayerClockIfNeeded() {
        guard hasLoadedVideo, !hasPlaybackError,
              !mediaClock.takesPriority(at: ProcessInfo.processInfo.systemUptime),
              let data = try? JSONSerialization.data(withJSONObject: ["loadID": loadID, "videoID": videoID]),
              let json = String(data: data, encoding: .utf8),
              let ticket = playerPollGate.request(at: ProcessInfo.processInfo.systemUptime) else { return }
        // This refreshes controls and the coarse display only. Cached iframe
        // getters are never sufficient evidence for scheduling audio.
        webView.evaluateJavaScript("window.fretFlowPlayer && window.fretFlowPlayer.readClock(\(json))") { [weak self] _, _ in
            self?.playerPollGate.finish(ticket)
        }
    }

    private func stopClockPolling() {
        clockPollTimer?.invalidate()
        clockPollTimer = nil
        mediaFrame = nil
        clockPollGate.reset()
        playerPollGate.reset()
    }

    private func installMediaClock(configurationJSON: String) {
        removeMediaClockScript()
        guard let template = loadBundledText(name: "YouTubeClock", extension: "js") else { return }
        let source = template.replacingOccurrences(of: "__FRETFLOW_CLOCK_CONFIG__", with: configurationJSON)
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.clockWorld)
        clockScript = script
        webView.configuration.userContentController.addUserScript(script)
    }

    private func removeMediaClockScript() {
        guard let clockScript else { return }
        let controller = webView.configuration.userContentController
        let retained = controller.userScripts.filter { $0 !== clockScript }
        controller.removeAllUserScripts()
        for script in retained { controller.addUserScript(script) }
        self.clockScript = nil
    }

    private func loadBundledText(name: String, extension suffix: String) -> String? {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: suffix),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).\(suffix)"),
            sourceRoot.appendingPathComponent("Resources/\(name).\(suffix)")
        ].compactMap { $0 }
        for url in candidates {
            if let html = try? String(contentsOf: url, encoding: .utf8) { return html }
        }
        return nil
    }

    private static let emptyHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body style="margin:0;background:#111318;color:#a7aab3;font:14px -apple-system,sans-serif;display:grid;place-items:center;height:100vh">
    <div>Link a YouTube video to start practicing.</div></body></html>
    """
}

struct YouTubeView: NSViewRepresentable {
    @ObservedObject var controller: YouTubeController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
private final class WeakYouTubeMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: YouTubeController?
    init(_ target: YouTubeController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

#endif
