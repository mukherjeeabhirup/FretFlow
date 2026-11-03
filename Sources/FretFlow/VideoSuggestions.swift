import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#endif

struct VideoSuggestion: Identifiable, Equatable, Sendable {
    let videoID: String
    let title: String
    let channel: String
    var id: String { videoID }
}

enum VideoSuggestionFailure: Error, Equatable, Sendable {
    case missingTitle, missingKey, invalidKey, apiNotEnabled, quota, forbidden
    case offline, timedOut, network, invalidResponse, server, httpStatus(Int)

    // Never show a raw response, URL, query, key, or transport error description.
    var message: String {
        switch self {
        case .missingTitle: return "Enter a song title before searching."
        case .missingKey: return "Add a local YouTube API key in API setup below. Manual video links still work."
        case .invalidKey: return "The API key was rejected. Check the key and its API restrictions in Google Cloud."
        case .apiNotEnabled: return "Enable YouTube Data API v3 for this key’s Google Cloud project."
        case .quota: return "YouTube search quota is exhausted or rate limited. Try later, or use a manual video link."
        case .forbidden: return "YouTube denied this search. Check the API key’s restrictions and project settings."
        case .offline: return "YouTube is unreachable. Check your connection and search again."
        case .timedOut: return "YouTube search timed out. Search again when your connection is ready."
        case .network: return "YouTube search could not connect. Try again, or use a manual video link."
        case .invalidResponse: return "YouTube returned an unreadable search response. Try again later."
        case .server: return "YouTube search is temporarily unavailable. Try again later."
        case .httpStatus(let status): return "YouTube search failed (HTTP \(status)). Try again later."
        }
    }
}

/// These helpers accept only user-reviewed title/artist strings, never a score,
/// file URL, PDF text, page image, or library object. No requests are logged.
enum VideoSuggestionAPI {
    static let environmentKey = "FRETFLOW_YOUTUBE_API_KEY"
    static let defaultsKey = "FretFlow.youtubeAPIKey"

    static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func query(title: String, artist: String) throws -> String {
        let title = normalized(title)
        guard !title.isEmpty else { throw VideoSuggestionFailure.missingTitle }
        return [normalized(artist), title].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Entered keys live in the view only. Environment wins over app defaults;
    /// this feature never writes keys or changes existing preferences.
    static func apiKey(entered: String, environment: String?, defaultsValue: String?) -> String? {
        [entered, environment, defaultsValue].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    static func request(title: String, artist: String, apiKey: String?) throws -> URLRequest {
        let query = try Self.query(title: title, artist: artist)
        guard let key = Self.apiKey(entered: apiKey ?? "", environment: nil, defaultsValue: nil) else {
            throw VideoSuggestionFailure.missingKey
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/youtube/v3/search"
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "videoSyndicated", value: "true"),
            URLQueryItem(name: "order", value: "relevance"),
            URLQueryItem(name: "maxResults", value: "6"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components.url else { throw VideoSuggestionFailure.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func validVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let kind: String?; let videoId: String? }
            struct Snippet: Decodable { let title: String?; let channelTitle: String? }
            let id: ID?
            let snippet: Snippet?
        }
        let items: [Item]
    }

    static func results(from data: Data) throws -> [VideoSuggestion] {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw VideoSuggestionFailure.invalidResponse
        }
        var seen = Set<String>()
        return response.items.compactMap { item in
            guard item.id?.kind == "youtube#video", let id = item.id?.videoId, validVideoID(id),
                  let rawTitle = item.snippet?.title, let rawChannel = item.snippet?.channelTitle else { return nil }
            let title = displayText(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            let channel = displayText(rawChannel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !channel.isEmpty, seen.insert(id).inserted else { return nil }
            return VideoSuggestion(videoID: id, title: title, channel: channel)
        }
    }

    /// Decode common API title escapes as plain text, without loading HTML or
    /// remote resources. Ampersand is last to avoid decoding nested escapes.
    static func displayText(_ value: String) -> String {
        var text = value
        for (entity, replacement) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                      ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }

    static func failure(status: Int, data: Data) -> VideoSuggestionFailure {
        // Only inspect structured reasons. Raw server messages can contain the
        // request/key, so they must never reach UI, diagnostics, or logs.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let entries = error?["errors"] as? [[String: Any]] ?? []
        let details = error?["details"] as? [[String: Any]] ?? []
        let reasons = Set((entries + details).compactMap { $0["reason"] as? String })
        if status == 429 || !reasons.isDisjoint(with: ["quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"]) {
            return .quota
        }
        if !reasons.isDisjoint(with: ["keyInvalid", "keyExpired", "API_KEY_INVALID", "API_KEY_EXPIRED"]) { return .invalidKey }
        if !reasons.isDisjoint(with: ["accessNotConfigured", "serviceDisabled", "SERVICE_DISABLED"]) { return .apiNotEnabled }
        if status == 401 { return .invalidKey }
        if status == 403 { return .forbidden }
        if (500...599).contains(status) { return .server }
        return .httpStatus(status)
    }
}

struct VideoSuggestionClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    init() {
        transport = { request in try await VideoSuggestionClient.session.data(for: request) }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func search(title: String, artist: String, apiKey: String?) async throws -> [VideoSuggestion] {
        try Task.checkCancellation()
        let request = try VideoSuggestionAPI.request(title: title, artist: artist, apiKey: apiKey)
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw VideoSuggestionFailure.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                throw VideoSuggestionAPI.failure(status: response.statusCode, data: data)
            }
            return try VideoSuggestionAPI.results(from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed: throw VideoSuggestionFailure.offline
            case .timedOut: throw VideoSuggestionFailure.timedOut
            default: throw VideoSuggestionFailure.network
            }
        } catch let error as VideoSuggestionFailure {
            throw error
        } catch {
            throw VideoSuggestionFailure.network
        }
    }
}

/// The generation check also rejects transports that finish after cancellation.
/// Creating/configuring the model does not schedule network work.
@MainActor
final class VideoSuggestionSearchModel {
    enum SearchState: Equatable {
        case idle, searching, results([VideoSuggestion]), failed(VideoSuggestionFailure)
    }

    #if canImport(Combine)
    let objectWillChange = ObservableObjectPublisher()
    #endif
    private(set) var state: SearchState = .idle {
        willSet {
            #if canImport(Combine)
            objectWillChange.send()
            #endif
        }
    }
    private let client: VideoSuggestionClient
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(client: VideoSuggestionClient = VideoSuggestionClient()) { self.client = client }
    deinit { task?.cancel() }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        state = .idle
    }

    func search(title: String, artist: String, apiKey: String?) {
        cancel()
        // Validate before scheduling any work, including absent-key cases.
        do { _ = try VideoSuggestionAPI.request(title: title, artist: artist, apiKey: apiKey) }
        catch let error as VideoSuggestionFailure { state = .failed(error); return }
        catch { state = .failed(.invalidResponse); return }
        state = .searching
        let ticket = generation
        let client = self.client
        task = Task { [weak self] in
            do {
                let results = try await client.search(title: title, artist: artist, apiKey: apiKey)
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.state = .results(results)
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                if error is CancellationError { self.state = .idle }
                else { self.state = .failed(error as? VideoSuggestionFailure ?? .network) }
                self.task = nil
            }
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension VideoSuggestionSearchModel: ObservableObject {}
private typealias SuggestionState<Value> = SwiftUI.State<Value>

/// Place next to the existing manual URL field. The parent confirms persistence
/// by calling session.linkVideo(id) from onSelect; use .id(selectedID) at the call
/// site so different songs with identical metadata also retire the old view.
@MainActor
struct VideoSuggestionsView: View {
    let title: String
    let artist: String
    let onSelect: (String) -> Void
    @StateObject private var search = VideoSuggestionSearchModel()
    @SuggestionState private var searchTitle: String
    @SuggestionState private var searchArtist: String
    @SuggestionState private var enteredKey = ""
    @SuggestionState private var showSetup = false

    init(title: String, artist: String, onSelect: @escaping (String) -> Void) {
        self.title = title
        self.artist = artist
        self.onSelect = onSelect
        _searchTitle = SuggestionState(initialValue: title)
        _searchArtist = SuggestionState(initialValue: artist)
    }

    private var apiKey: String? {
        VideoSuggestionAPI.apiKey(entered: enteredKey,
                                 environment: ProcessInfo.processInfo.environment[VideoSuggestionAPI.environmentKey],
                                 defaultsValue: UserDefaults.standard.string(forKey: VideoSuggestionAPI.defaultsKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("YouTube recording suggestions", systemImage: "magnifyingglass").font(.caption.bold())
            TextField("Song title", text: $searchTitle)
                .accessibilityLabel("Song title for YouTube search")
            TextField("Artist (optional)", text: $searchArtist)
                .accessibilityLabel("Artist for YouTube search")
            Text("Search sends the title and artist above to YouTube. PDF contents are never sent. Each search uses your API quota.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Search YouTube") {
                    if apiKey == nil { showSetup = true }
                    search.search(title: searchTitle, artist: searchArtist, apiKey: apiKey)
                }
                .disabled(VideoSuggestionAPI.normalized(searchTitle).isEmpty || search.state == .searching)
                if search.state == .searching {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { search.cancel() }
                }
            }
            switch search.state {
            case .idle: EmptyView()
            case .searching: Text("Searching YouTube…").font(.caption).foregroundStyle(.secondary)
            case .failed(let error):
                Text(error.message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .results(let results):
                if results.isEmpty {
                    Text("No playable suggestions found. Edit the title or artist and search again, or enter a video URL manually.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Choose the recording you want to link. Availability can still vary by region or change later.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: result.title).font(.caption).lineLimit(3)
                                .textSelection(.enabled)
                            Text(verbatim: result.channel).font(.caption2).foregroundStyle(.secondary)
                            Button("Use this video") {
                                // A result never links itself automatically.
                                search.cancel()
                                onSelect(result.videoID)
                            }
                            .accessibilityLabel("Use video \(result.title) by \(result.channel)")
                        }.padding(.vertical, 4)
                    }
                }
            }
            DisclosureGroup("API setup (local)", isExpanded: $showSetup) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("API key (this view only)", text: $enteredKey)
                    Text("Enable YouTube Data API v3 in your Google Cloud project and restrict the key to that API. A key entered here stays in memory for this view. Alternatively set FRETFLOW_YOUTUBE_API_KEY in the app’s launch environment, or FretFlow.youtubeAPIKey in local app defaults. Defaults store keys unencrypted. Restart after changing the launch environment.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("YouTube API setup guide", destination: URL(string: "https://developers.google.com/youtube/data/getting-started")!)
                        .font(.caption)
                }.padding(.top, 4)
            }.font(.caption)
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .onChange(of: [title, artist]) { _, _ in
            search.cancel()
            searchTitle = title
            searchArtist = artist
        }
        .onChange(of: [searchTitle, searchArtist, enteredKey]) { _, _ in search.cancel() }
        .onDisappear { search.cancel() }
    }
}
#endif
