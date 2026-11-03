import SwiftUI
import WebKit
import PDFKit

struct ScoreTrack: Identifiable {
    let index: Int
    let name: String
    let tuning: [Int]
    var id: Int { index }
}
struct ScoreMeasure: Identifiable {
    let index: Int
    let start: Double
    let end: Double
    let label: String
    var id: Double { start }
}

@MainActor
final class ScoreController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var tracks: [ScoreTrack] = []
    @Published var measures: [ScoreMeasure] = []
    @Published var selectedTrack = 0
    @Published var status = "Loading score reader…"
    @Published var currentMeasure = ""
    @Published var isLoaded = false
    @Published var error: String?
    @Published var follow = true
    @Published var zoom = 1.0
    @Published var scoreTitle = ""
    @Published var clicks: [ScoreClick] = []
    @Published var clickTrackError: String?
    @Published var alignmentScale: Double = 1
    @Published private(set) var alignmentAdjustment: Double = 0
    @Published private(set) var alignmentOffset: Double = 0
    @Published private(set) var inferredAlignmentOffset: Double = 0
    @Published private(set) var referenceAttacks: [Double] = []
    let webView: WKWebView
    var onSeek: ((Double) -> Void)?
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onLoaded: (() -> Void)?
    var onClicksChanged: (() -> Void)?
    private var ready = false
    private var pending: (URL, String)?
    private var currentURL: URL?
    private var alignmentRevision = 0
    private var loadedID = ""
    var songID: String { loadedID }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.configuration.userContentController.add(self, name: "fretflow")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Web/index.html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func load(url: URL, id: String, offsetAdjustment: Double = 0) {
        pending = (url, id)
        currentURL = url
        loadedID = id
        alignmentRevision &+= 1
        alignmentAdjustment = offsetAdjustment.isFinite ? max(-30, min(120, offsetAdjustment)) : 0
        alignmentOffset = 0
        inferredAlignmentOffset = 0
        referenceAttacks = []
        isLoaded = false
        error = nil
        tracks = []
        measures = []
        clicks = []
        clickTrackError = nil
        alignmentScale = 1
        currentMeasure = ""
        selectedTrack = 0
        status = "Opening score…"
        if ready { sendPending() }
    }

    private func sendPending() {
        guard let (url, id) = pending else { return }
        pending = nil
        do {
            let bytes = try Data(contentsOf: url)
            call("loadScore", arguments: [bytes.base64EncodedString(), id, alignmentAdjustment, alignmentRevision])
        } catch { self.error = "Could not read this score: \(error.localizedDescription)" }
    }

    func suspend() {
        loadedID = ""
        pending = nil
        currentURL = nil
        alignmentRevision &+= 1
        isLoaded = false
        clicks = []
        clickTrackError = nil
        referenceAttacks = []
    }

    func call(_ function: String, arguments: [Any] = []) {
        guard ready else { return }
        let args = arguments.map(javascriptJSON).joined(separator: ",")
        webView.evaluateJavaScript("window.FretFlow.\(function)(\(args));") { [weak self] _, error in
            if let error = error {
                Task { @MainActor in self?.error = "Score reader: \(error.localizedDescription)" }
            }
        }
    }

    func setClock(position: Double, duration: Double, isPlaying: Bool, rate: Double) {
        guard isLoaded else { return }
        call("setClock", arguments: [["position": position, "duration": duration, "isPlaying": isPlaying, "rate": rate]])
    }

    func selectTrack(_ index: Int) {
        guard isLoaded, tracks.contains(where: { $0.index == index }) else { return }
        // Cancel the previous part's accents while the new grid crosses the bridge.
        clicks = []
        clickTrackError = nil
        onClicksChanged?()
        call("selectTrack", arguments: [index])
    }

    func setAlignmentAdjustment(_ value: Double) {
        guard value.isFinite, (-30...120).contains(value) else { return }
        guard isLoaded else {
            if let currentURL { load(url: currentURL, id: loadedID, offsetAdjustment: value) }
            return
        }
        alignmentRevision &+= 1
        alignmentAdjustment = value
        clicks = []
        measures = []
        onClicksChanged?()
        call("setOffsetAdjustment", arguments: [value, alignmentRevision])
    }

    private func readTimeline(_ data: [String: Any]) {
        measures = (data["measures"] as? [[String: Any]] ?? []).compactMap { item in
            guard let index = item["index"] as? Int, let start = item["start"] as? Double,
                  let end = item["end"] as? Double, start.isFinite, end.isFinite, end > start else { return nil }
            return ScoreMeasure(index: index, start: start, end: end, label: item["label"] as? String ?? "Measure \(index + 1)")
        }
        readClicks(data)
        let alignment = data["alignment"] as? [String: Any] ?? [:]
        let scale = alignment["scale"] as? Double ?? 1
        alignmentScale = scale.isFinite && scale > 0 ? scale : 1
        let offset = alignment["offset"] as? Double ?? 0
        alignmentOffset = offset.isFinite ? offset : 0
        let inferred = alignment["inferredOffset"] as? Double ?? 0
        inferredAlignmentOffset = inferred.isFinite ? inferred : 0
        referenceAttacks = (data["referenceAttacks"] as? [Double] ?? []).filter { $0.isFinite && $0 >= 0 && $0 <= 60 }
    }

    private func readClicks(_ data: [String: Any]) {
        if let rawClicks = data["clicks"], JSONSerialization.isValidJSONObject(rawClicks),
           let bytes = try? JSONSerialization.data(withJSONObject: rawClicks),
           let decoded = try? JSONDecoder().decode([ScoreClick].self, from: bytes) {
            clicks = decoded
        } else { clicks = [] }
        clickTrackError = data["clickTrackError"] as? String
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any], let type = data["type"] as? String else { return }
        if let eventID = data["songID"] as? String, eventID != loadedID { return }
        if ["score", "timeline", "clicks", "seek", "measure"].contains(type),
           (data["alignmentRevision"] as? Int) != alignmentRevision { return }
        switch type {
        case "ready":
            ready = true
            sendPending()
        case "score":
            guard data["songID"] as? String == loadedID else { return }
            tracks = (data["tracks"] as? [[String: Any]] ?? []).compactMap { item in
                guard let index = item["index"] as? Int, let name = item["name"] as? String else { return nil }
                return ScoreTrack(index: index, name: name, tuning: item["tuning"] as? [Int] ?? [])
            }
            scoreTitle = data["title"] as? String ?? ""
            readTimeline(data)
            isLoaded = true
            let requestedTrack = data["selectedTrack"] as? Int ?? 0
            selectedTrack = tracks.contains(where: { $0.index == requestedTrack }) ? requestedTrack : (tracks.first?.index ?? 0)
            status = "\(measures.count) measures · automatic score timing"
            call("setFollow", arguments: [follow])
            call("setZoom", arguments: [zoom])
            onLoaded?()
        case "timeline":
            guard data["songID"] as? String == loadedID,
                  data["selectedTrack"] as? Int == selectedTrack else { return }
            readTimeline(data)
            onClicksChanged?()
        case "clicks":
            guard data["songID"] as? String == loadedID,
                  data["selectedTrack"] as? Int == selectedTrack else { return }
            readClicks(data)
            onClicksChanged?()
        case "seek": if let time = data["position"] as? Double { onSeek?(time) }
        case "play": onPlay?()
        case "pause": onPause?()
        case "measure": currentMeasure = data["label"] as? String ?? ""
        case "error": error = data["message"] as? String ?? "This score could not be displayed."
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, !url.isFileURL {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}

struct ScoreView: NSViewRepresentable {
    let controller: ScoreController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor
struct PDFReader: View {
    let url: URL
    var body: some View {
        PDFPracticeView(url: url, songID: "book:" + url.standardizedFileURL.path)
    }
}
