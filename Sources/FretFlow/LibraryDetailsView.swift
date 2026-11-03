import SwiftUI
import PDFKit

private typealias DetailsState<Value> = SwiftUI.State<Value>

struct LibraryDetailsView: View {
    @ObservedObject var library: LibraryStore
    let song: LibrarySong
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @DetailsState private var title: String
    @DetailsState private var artist: String
    @DetailsState private var collection: String
    @DetailsState private var sectionTitle = ""
    @DetailsState private var startPage = 1
    @DetailsState private var endPage = 1
    @DetailsState private var pageCount = 0

    init(library: LibraryStore, song: LibrarySong, onSelect: @escaping (String) -> Void) {
        self.library = library
        self.song = song
        self.onSelect = onSelect
        _title = DetailsState(initialValue: song.title)
        _artist = DetailsState(initialValue: song.artist)
        _collection = DetailsState(initialValue: song.collection ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library details").font(.title2.bold())
            TextField("Title", text: $title)
            TextField("Artist", text: $artist)
            TextField("Collection", text: $collection)
            if song.kind == "pdf", pageCount > 0 {
                Divider()
                Text("Add a song from this book").font(.headline)
                Text("The song shares this PDF and gets its own video link and practice state. Page numbers are physical PDF pages.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Song title", text: $sectionTitle)
                HStack {
                    Stepper("First page: \(startPage)", value: $startPage, in: (song.pageStart ?? 1)...(song.pageEnd ?? pageCount))
                    Stepper("Last page: \(endPage)", value: $endPage, in: (song.pageStart ?? 1)...(song.pageEnd ?? pageCount))
                }
                Button("Add song section") {
                    if let id = library.addPDFSection(for: song, title: sectionTitle, startPage: startPage, endPage: endPage) {
                        onSelect(id)
                        dismiss()
                    }
                }.disabled(sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endPage < startPage)
            }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save details") {
                    library.error = nil
                    if library.updateDetails(for: song, title: title, artist: artist, collection: collection) { dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 520)
        .onAppear {
            if song.kind == "pdf" {
                pageCount = PDFDocument(url: library.url(for: song))?.pageCount ?? 0
                startPage = song.pageStart ?? 1
                endPage = song.pageEnd ?? max(1, pageCount)
            }
        }
    }
}
