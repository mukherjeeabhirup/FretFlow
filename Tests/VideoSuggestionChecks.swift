// Synthetic offline checks. No preferences, credentials, PDF/library data,
// network connections, WebKit instances, microphones, or audio are used.
// Run (Swift 5.9+, macOS or Linux):
// swiftc -swift-version 5 -parse-as-library -module-cache-path /tmp/fretflow-video-suggestion-module-cache Sources/FretFlow/VideoSuggestions.swift Tests/VideoSuggestionChecks.swift -o /tmp/fretflow-video-suggestion-checks
// /tmp/fretflow-video-suggestion-checks
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ignores cancellation on purpose, allowing retired requests to finish out of
/// order. It never passes a request to URLSession or another network transport.
private actor SuspendedSuggestionTransport {
    private var continuations = [Int: CheckedContinuation<(Data, URLResponse), Error>]()
    private(set) var calls = 0

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { continuations[call] = $0 }
    }

    func finish(_ call: Int, data: Data, status: Int = 200) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            preconditionFailure("Synthetic request was not suspended")
        }
        continuation.resume(returning: (data, Self.response(status)))
    }

    nonisolated static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://www.googleapis.com/youtube/v3/search")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

@main
@MainActor
struct VideoSuggestionChecks {
    private static var checks = 0
    private static let firstID = "abcdefghi_1"
    private static let secondID = "JKLMNOPQR-2"
    private static let syntheticKey = "synthetic-offline-key"
    private static let first = VideoSuggestion(videoID: firstID, title: "Synthetic Lantern Exercise", channel: "Example Workshop")
    private static let second = VideoSuggestion(videoID: secondID, title: "Synthetic Orbit Exercise", channel: "Example Workshop")

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    private static func fixture(_ result: VideoSuggestion) -> Data {
        try! JSONSerialization.data(withJSONObject: ["items": [[
            "id": ["kind": "youtube#video", "videoId": result.videoID],
            "snippet": ["title": result.title, "channelTitle": result.channel]
        ]]])
    }

    private static func errorFixture(_ reason: String, modern: Bool = false) -> Data {
        let error: [String: Any] = [
            "message": "Synthetic service message that must never be displayed",
            modern ? "details" : "errors": [["reason": reason]]
        ]
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    private static func expectFailure(_ expected: VideoSuggestionFailure, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected a typed suggestion error") }
        catch let error as VideoSuggestionFailure { check(error == expected, "Unexpected typed suggestion error") }
        catch { preconditionFailure("Unexpected error type") }
    }

    private static func expectAsyncFailure(_ expected: VideoSuggestionFailure,
                                           _ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("Expected a typed async suggestion error") }
        catch let error as VideoSuggestionFailure { check(error == expected, "Unexpected typed async error") }
        catch { preconditionFailure("Unexpected async error type") }
    }

    private static func waitUntil(_ predicate: () async -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await predicate()), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let met = await predicate()
        precondition(met, "Synthetic async check timed out")
    }

    private static func drainTasks() async {
        for _ in 0..<24 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    static func main() async throws {
        try requestChecks()
        try parsingChecks()
        errorChecks()
        await transportChecks()
        await lifecycleChecks()
        print("Offline video suggestion checks passed (\(checks) assertions; synthetic data, mocked transport).")
    }

    private static func requestChecks() throws {
        let query = try VideoSuggestionAPI.query(title: "  Synthetic\n Lantern  Exercise ", artist: " Example\tWorkshop ")
        check(query == "Example Workshop Synthetic Lantern Exercise", "Query must normalize editable metadata")
        let titleOnly = try VideoSuggestionAPI.query(title: "Synthetic Exercise", artist: " \n ")
        check(titleOnly == "Synthetic Exercise", "Artist must be optional")
        expectFailure(.missingTitle) { _ = try VideoSuggestionAPI.query(title: " \n\t", artist: "Example Workshop") }
        expectFailure(.missingKey) { _ = try VideoSuggestionAPI.request(title: "Synthetic Exercise", artist: "", apiKey: " ") }
        check(VideoSuggestionAPI.apiKey(entered: " entered ", environment: "env", defaultsValue: "defaults") == "entered", "Entered key must win")
        check(VideoSuggestionAPI.apiKey(entered: " ", environment: " env ", defaultsValue: "defaults") == "env", "Environment must win over defaults")
        check(VideoSuggestionAPI.apiKey(entered: "", environment: " ", defaultsValue: " defaults ") == "defaults", "Defaults must be a fallback")
        check(VideoSuggestionAPI.apiKey(entered: "", environment: nil, defaultsValue: nil) == nil, "Absent configuration must remain absent")
        let title = "Synthetic & ? Exercise # / + 雨"
        let request = try VideoSuggestionAPI.request(title: title, artist: "Example Workshop", apiKey: syntheticKey)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        check(components.scheme == "https" && components.host == "www.googleapis.com" && components.path == "/youtube/v3/search", "Only the official HTTPS endpoint is allowed")
        check(components.user == nil && components.password == nil && components.fragment == nil, "Query input cannot change URL authority or fragment")
        check(items["q"] == "Example Workshop " + title && items["key"] == syntheticKey, "Query and key must survive URL encoding")
        check(items["type"] == "video" && items["part"] == "snippet", "Only video metadata is requested")
        check(items["videoEmbeddable"] == "true" && items["videoSyndicated"] == "true", "Suggestions must support embedded playback")
        check(items["maxResults"] == "6" && items["order"] == "relevance" && items.count == 8, "Search must be bounded and contain only intended parameters")
        check(request.httpMethod == "GET" && request.httpBody == nil, "Search cannot upload a document body")
        check(request.timeoutInterval == 20 && request.cachePolicy == .reloadIgnoringLocalCacheData, "Search must time out and bypass persistent caches")
        check(request.value(forHTTPHeaderField: "Accept") == "application/json", "Search must request JSON")
    }

    private static func parsingChecks() throws {
        let valid = try VideoSuggestionAPI.results(from: fixture(first))
        check(valid == [first], "Valid video metadata must parse")
        let empty = try VideoSuggestionAPI.results(from: Data("{\"items\":[]}".utf8))
        check(empty.isEmpty, "Empty results are valid")
        expectFailure(.invalidResponse) { _ = try VideoSuggestionAPI.results(from: Data("not JSON".utf8)) }
        expectFailure(.invalidResponse) { _ = try VideoSuggestionAPI.results(from: Data("{}".utf8)) }
        expectFailure(.invalidResponse) { _ = try VideoSuggestionAPI.results(from: Data("{\"items\":{}}".utf8)) }
        let mixed = Data("""
        {"items":[
          {"id":{"kind":"youtube#video","videoId":"abcdefghi_1"},"snippet":{"title":"Synthetic &amp; &quot;Exercise&quot; &#39;A&#39;","channelTitle":"Example &lt;Workshop&gt;"}},
          {"id":{"kind":"youtube#video","videoId":"abcdefghi_1"},"snippet":{"title":"Duplicate","channelTitle":"Example Workshop"}},
          {"id":{"kind":"youtube#channel","videoId":"JKLMNOPQR-2"},"snippet":{"title":"Channel","channelTitle":"Example Workshop"}},
          {"id":{"kind":"youtube#playlist","videoId":"JKLMNOPQR-2"},"snippet":{"title":"Playlist","channelTitle":"Example Workshop"}},
          {"id":{"kind":"youtube#video","videoId":"bad/id"},"snippet":{"title":"Invalid ID","channelTitle":"Example Workshop"}},
          {"id":{"kind":"youtube#video","videoId":"JKLMNOPQR-2"},"snippet":{"title":"  ","channelTitle":"Example Workshop"}},
          {"id":{"kind":"youtube#video","videoId":"JKLMNOPQR-2"},"snippet":{"title":"Missing channel"}},
          {"id":{"kind":"youtube#video","videoId":"JKLMNOPQR-2"}},
          {},
          {"id":{"kind":"youtube#video","videoId":"JKLMNOPQR-2"},"snippet":{"title":"Synthetic Orbit Exercise","channelTitle":"Example Workshop"}}
        ]}
        """.utf8)
        let results = try VideoSuggestionAPI.results(from: mixed)
        check(results.count == 2 && results.map(\.videoID) == [firstID, secondID], "Ignore invalid/nonvideo entries and deduplicate without reordering relevance")
        check(results[0].title == "Synthetic & \"Exercise\" 'A'" && results[0].channel == "Example <Workshop>", "Display common metadata entities as plain text")
        check(VideoSuggestionAPI.displayText("&amp;quot;") == "&quot;", "Do not recursively decode escaped HTML")
        for invalid in ["", "short", "abcdefghijkL", "abcdefghij/", "abcdefghijé", "abcdefghij\n"] {
            check(!VideoSuggestionAPI.validVideoID(invalid), "Reject invalid API video IDs")
        }
        check(VideoSuggestionAPI.validVideoID(firstID) && VideoSuggestionAPI.validVideoID(secondID), "Accept canonical ASCII IDs")
    }

    private static func errorChecks() {
        for reason in ["quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded"] {
            check(VideoSuggestionAPI.failure(status: 403, data: errorFixture(reason)) == .quota, "Recognize quota/rate errors")
        }
        check(VideoSuggestionAPI.failure(status: 429, data: Data()) == .quota, "HTTP rate limiting needs no JSON body")
        check(VideoSuggestionAPI.failure(status: 400, data: errorFixture("keyInvalid")) == .invalidKey, "Recognize invalid key")
        check(VideoSuggestionAPI.failure(status: 400, data: errorFixture("API_KEY_INVALID", modern: true)) == .invalidKey, "Recognize modern key error details")
        check(VideoSuggestionAPI.failure(status: 403, data: errorFixture("accessNotConfigured")) == .apiNotEnabled, "Recognize disabled service")
        check(VideoSuggestionAPI.failure(status: 403, data: errorFixture("SERVICE_DISABLED", modern: true)) == .apiNotEnabled, "Recognize modern disabled service details")
        check(VideoSuggestionAPI.failure(status: 401, data: Data()) == .invalidKey, "Recognize unauthorized status")
        check(VideoSuggestionAPI.failure(status: 403, data: Data()) == .forbidden, "Give guidance for other forbidden requests")
        check(VideoSuggestionAPI.failure(status: 503, data: Data()) == .server, "Recognize temporary server failures")
        let failure = VideoSuggestionAPI.failure(status: 418, data: errorFixture("unknownSyntheticReason"))
        check(failure == .httpStatus(418), "Keep unrecognized status codes")
        check(!failure.message.contains("Synthetic service message") && !failure.message.contains(syntheticKey), "Never display raw service messages or keys")
    }

    private static func transportChecks() async {
        let successData = fixture(first)
        let success = VideoSuggestionClient { _ in (successData, SuspendedSuggestionTransport.response(200)) }
        do { let results = try await success.search(title: first.title, artist: first.channel, apiKey: syntheticKey)
            check(results == [first], "Mock transport must exercise request/response pipeline")
        } catch { preconditionFailure("Synthetic successful search failed") }
        let quotaData = errorFixture("quotaExceeded")
        let quota = VideoSuggestionClient { _ in (quotaData, SuspendedSuggestionTransport.response(403)) }
        await expectAsyncFailure(.quota) { _ = try await quota.search(title: first.title, artist: "", apiKey: syntheticKey) }
        let unreadable = VideoSuggestionClient { _ in (Data("<html>synthetic</html>".utf8), SuspendedSuggestionTransport.response(200)) }
        await expectAsyncFailure(.invalidResponse) { _ = try await unreadable.search(title: first.title, artist: "", apiKey: syntheticKey) }
        let nonHTTP = VideoSuggestionClient { _ in (Data(), URLResponse(url: URL(string: "https://example.invalid")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) }
        await expectAsyncFailure(.invalidResponse) { _ = try await nonHTTP.search(title: first.title, artist: "", apiKey: syntheticKey) }
        for (code, expected) in [(URLError.notConnectedToInternet, VideoSuggestionFailure.offline),
                                 (.networkConnectionLost, .offline), (.timedOut, .timedOut), (.secureConnectionFailed, .network)] {
            let client = VideoSuggestionClient { _ in throw URLError(code) }
            await expectAsyncFailure(expected) { _ = try await client.search(title: first.title, artist: "", apiKey: syntheticKey) }
        }
        let cancelled = VideoSuggestionClient { _ in throw URLError(.cancelled) }
        do { _ = try await cancelled.search(title: first.title, artist: "", apiKey: syntheticKey)
            preconditionFailure("Cancelled transport must throw")
        } catch is CancellationError { check(true, "Transport cancellation stays cancellation") }
        catch { preconditionFailure("Cancellation became a visible search failure") }
    }

    private static func lifecycleChecks() async {
        let mock = SuspendedSuggestionTransport()
        let client = VideoSuggestionClient { try await mock.send($0) }
        let model = VideoSuggestionSearchModel(client: client)
        await drainTasks()
        let initialCalls = await mock.calls
        check(initialCalls == 0 && model.state == .idle, "Creating the model cannot search without opt-in")
        model.search(title: first.title, artist: "", apiKey: nil)
        check(model.state == .failed(.missingKey), "Missing key must show setup guidance")
        model.search(title: " \n", artist: "", apiKey: syntheticKey)
        check(model.state == .failed(.missingTitle), "Blank title must be rejected locally")
        await drainTasks()
        let invalidCalls = await mock.calls
        check(invalidCalls == 0, "Validation failures cannot reach the transport")

        // Cancel before the task can enter transport (song change/disappearance).
        model.search(title: first.title, artist: "", apiKey: syntheticKey)
        model.cancel()
        await drainTasks()
        let queuedCalls = await mock.calls
        check(queuedCalls == 0 && model.state == .idle, "Queued cancelled requests must never start")

        // A new song/query retires a suspended older request. Complete new first.
        model.search(title: first.title, artist: "", apiKey: syntheticKey)
        await waitUntil { await mock.calls == 1 }
        check(model.state == .searching, "Explicit search must show progress")
        model.cancel()
        check(model.state == .idle, "Metadata edits must immediately clear results/progress")
        model.search(title: second.title, artist: "", apiKey: syntheticKey)
        await waitUntil { await mock.calls == 2 }
        await mock.finish(2, data: fixture(second))
        await waitUntil { model.state == .results([second]) }
        await mock.finish(1, data: fixture(first))
        await drainTasks()
        check(model.state == .results([second]), "Late retired success cannot replace current results")

        // Retired failure cannot clear results from a newer successful request.
        model.search(title: first.title, artist: "", apiKey: syntheticKey)
        await waitUntil { await mock.calls == 3 }
        model.search(title: second.title, artist: "", apiKey: syntheticKey)
        await waitUntil { await mock.calls == 4 }
        await mock.finish(4, data: fixture(second))
        await waitUntil { model.state == .results([second]) }
        await mock.finish(3, data: errorFixture("quotaExceeded"), status: 403)
        await drainTasks()
        check(model.state == .results([second]), "Late retired failure cannot overwrite current results")

        // Leaving the view while work is in flight must remain idle afterward.
        model.search(title: first.title, artist: "", apiKey: syntheticKey)
        await waitUntil { await mock.calls == 5 }
        model.cancel()
        await mock.finish(5, data: fixture(first))
        await drainTasks()
        check(model.state == .idle, "Cancellation must retire even noncooperative completions")
        model.search(title: first.title, artist: "", apiKey: syntheticKey)
        await waitUntil { await mock.calls == 6 }
        await mock.finish(6, data: errorFixture("quotaExceeded"), status: 403)
        await waitUntil { model.state == .failed(.quota) }
        check(model.state == .failed(.quota), "Active API failure must reach the UI")
    }
}
