import PDFKit
import SwiftUI

/// A PDF reference reader. Page numbers always refer to the original document.
@MainActor
struct PDFPracticeView: View {
    let url: URL
    let songID: String
    let pageStart: Int?
    let pageEnd: Int?
    @StateObject private var reader = PDFPracticeController()

    init(url: URL, songID: String, pageStart: Int? = nil, pageEnd: Int? = nil) {
        self.url = url
        self.songID = songID
        self.pageStart = pageStart
        self.pageEnd = pageEnd
    }

    private var identity: Identity { Identity(url: url, songID: songID, start: pageStart, end: pageEnd) }
    private struct Identity: Hashable {
        let url: URL
        let songID: String
        let start: Int?
        let end: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { reader.go(to: reader.page - 1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous page").accessibilityLabel("Previous page")
                    .disabled(reader.page <= (reader.range?.start ?? 1))
                Text("Page")
                TextField("Page", text: $reader.pageEntry)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Original PDF page number")
                    .onSubmit { reader.goToEnteredPage() }
                Text("of \(reader.totalPages)").monospacedDigit()
                Button { reader.go(to: reader.page + 1) } label: { Image(systemName: "chevron.right") }
                    .help("Next page").accessibilityLabel("Next page")
                    .disabled(reader.page >= (reader.range?.end ?? 1))
                Spacer(minLength: 8)
                Button { reader.adjustZoom(by: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out").accessibilityLabel("Zoom out")
                Text("\(Int((reader.zoom * 100).rounded()))%")
                    .monospacedDigit().frame(minWidth: 42)
                Button { reader.adjustZoom(by: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in").accessibilityLabel("Zoom in")
                Button("Fit") { reader.fitPage() }.help("Fit page to the reader")
            }
            .font(.caption).controlSize(.small).padding(10)
            .disabled(reader.range == nil)
            Divider()
            if let failure = reader.failure {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.ellipsis").font(.largeTitle)
                    Text(failure).multilineTextAlignment(.center)
                    Button("Retry PDF") { open() }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PDFPracticeSurface(reader: reader)
            }
            if let range = reader.range, range.start != 1 || range.end != reader.totalPages {
                Divider()
                Text("Section: pages \(range.start)–\(range.end) · original page numbers")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let message = reader.navigationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .task(id: identity) { open() }
        .onDisappear { reader.persistPosition() }
    }

    private func open() { reader.open(url: url, songID: songID, pageStart: pageStart, pageEnd: pageEnd) }
}

@MainActor
private struct PDFPracticeSurface: NSViewRepresentable {
    let reader: PDFPracticeController
    func makeNSView(context: Context) -> PDFView { reader.view }
    func updateNSView(_ view: PDFView, context: Context) {}
}

/// A section owns an in-memory document containing only its allowed pages.
/// PDF links, scrolling and built-in navigation cannot reveal adjacent pages.
enum PDFPracticeDocument {
    struct Loaded {
        let document: PDFDocument
        let range: PDFPageRange
        let totalPages: Int
    }

    static func load(url: URL, pageStart: Int?, pageEnd: Int?) throws -> Loaded {
        guard let original = PDFDocument(url: url) else { throw ReadError.unreadable }
        guard !original.isLocked else { throw ReadError.locked }
        guard let range = PDFPageRange(pageStart: pageStart, pageEnd: pageEnd, pageCount: original.pageCount) else {
            throw ReadError.invalidRange
        }
        if range.start == 1, range.end == original.pageCount {
            return Loaded(document: original, range: range, totalPages: original.pageCount)
        }
        let section = PDFDocument()
        for number in range.start...range.end {
            guard let page = original.page(at: number - 1)?.copy() as? PDFPage else { throw ReadError.unreadable }
            // Source-document destinations can still reference pages outside the
            // subset. Remove those navigation annotations from the copy only.
            for annotation in page.annotations where annotation.action is PDFActionGoTo || annotation.action is PDFActionRemoteGoTo {
                page.removeAnnotation(annotation)
            }
            section.insert(page, at: section.pageCount)
        }
        return Loaded(document: section, range: range, totalPages: original.pageCount)
    }

    private enum ReadError: LocalizedError {
        case unreadable, locked, invalidRange
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This PDF could not be opened. Check that its source file is still available."
            case .locked: return "This PDF is locked. Use an unlocked copy to read it here."
            case .invalidRange: return "This entry's page range is outside the PDF. Check its start and end pages."
            }
        }
    }
}

@MainActor
final class PDFPracticeController: NSObject, ObservableObject {
    @Published private(set) var page = 1
    @Published private(set) var totalPages = 0
    @Published private(set) var range: PDFPageRange?
    @Published private(set) var zoom = 1.0
    @Published private(set) var failure: String?
    @Published private(set) var navigationMessage: String?
    @Published var pageEntry = "1"
    let view = PDFView()
    private let positions: PDFReadingStore
    private var songID = ""
    private var loading = false

    init(positions: PDFReadingStore = PDFReadingStore(
        persistenceEnabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))) {
        self.positions = positions
        super.init()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func open(url: URL, songID: String, pageStart: Int?, pageEnd: Int?) {
        persistPosition()
        loading = true
        defer { loading = false }
        self.songID = songID
        range = nil
        totalPages = 0
        page = 1
        pageEntry = "1"
        navigationMessage = nil
        failure = nil
        view.document = nil
        do {
            let loaded = try PDFPracticeDocument.load(url: url, pageStart: pageStart, pageEnd: pageEnd)
            range = loaded.range
            totalPages = loaded.totalPages
            let saved = positions.position(for: songID)
            view.autoScales = saved?.fit ?? true
            view.document = loaded.document
            if let saved, !saved.fit { view.scaleFactor = CGFloat(saved.zoom) }
            page = loaded.range.clamped(saved?.page ?? loaded.range.start)
            pageEntry = String(page)
            if let target = loaded.document.page(at: page - loaded.range.start) { view.go(to: target) }
            refreshZoom()
        } catch { failure = error.localizedDescription }
    }

    func goToEnteredPage() {
        guard let requested = Int(pageEntry.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showPageHint()
            return
        }
        go(to: requested)
    }

    func go(to requested: Int) {
        guard let range, range.contains(requested), let target = view.document?.page(at: requested - range.start) else {
            showPageHint()
            return
        }
        navigationMessage = nil
        view.go(to: target)
        // Also update when PDFKit does not notify because this page was already visible.
        updatePage()
    }

    func adjustZoom(by multiplier: Double) {
        guard range != nil else { return }
        view.autoScales = false
        view.scaleFactor = CGFloat(max(0.1, min(8, Double(view.scaleFactor) * multiplier)))
        refreshZoom()
        persistPosition()
    }

    func fitPage() {
        guard range != nil else { return }
        view.autoScales = true
        let fit = view.scaleFactorForSizeToFit
        if fit.isFinite, fit > 0 { view.scaleFactor = fit }
        view.autoScales = true
        refreshZoom()
        persistPosition()
    }

    func persistPosition() {
        guard !loading, range != nil, !songID.isEmpty else { return }
        positions.save(PDFReadingPosition(page: page, zoom: max(0.1, min(8, zoom)), fit: view.autoScales), for: songID)
    }

    private func showPageHint() {
        pageEntry = String(page)
        if let range { navigationMessage = "Enter a page from \(range.start) to \(range.end)." }
    }

    @objc private func pageChanged(_ notification: Notification) {
        guard !loading else { return }
        updatePage()
    }

    private func updatePage() {
        guard let range, let document = view.document, let current = view.currentPage else { return }
        let index = document.index(for: current)
        guard index >= 0, index < range.count else { return }
        page = index + range.start
        pageEntry = String(page)
        persistPosition()
    }

    @objc private func scaleChanged(_ notification: Notification) {
        guard !loading else { return }
        refreshZoom()
        persistPosition()
    }

    private func refreshZoom() {
        let scale = Double(view.scaleFactor)
        zoom = scale.isFinite && scale > 0 ? max(0.1, min(8, scale)) : 1
    }
}
