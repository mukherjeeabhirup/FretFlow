import SwiftUI
import AppKit
import WebKit

private typealias UIState<Value> = SwiftUI.State<Value>

@main
struct FretFlowApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var microphoneDiagnostic: MicrophoneDiagnostic?
    private var playbackCaptureDiagnostic: PlaybackCaptureDiagnostic?
    private var recordingSyncSessionDiagnostic: RecordingSyncSessionDiagnostic?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "FretFlow", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--recording-sync-check"), let index = args.firstIndex(of: "--output"), args.count > index + 1 {
            let titleIndex = args.firstIndex(of: "--song-title")
            let songTitle = titleIndex.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "Electric Sunrise"
            let diagnostic = RecordingSyncSessionDiagnostic(output: URL(fileURLWithPath: args[index + 1]), songTitle: songTitle)
            recordingSyncSessionDiagnostic = diagnostic
            diagnostic.run()
            return
        }
        if args.contains("--microphone-check"), let index = args.firstIndex(of: "--output"), args.count > index + 1 {
            let diagnostic = MicrophoneDiagnostic(output: URL(fileURLWithPath: args[index + 1]))
            microphoneDiagnostic = diagnostic
            diagnostic.run()
            return
        }
        if args.contains("--playback-capture-check"), let index = args.firstIndex(of: "--output"), args.count > index + 1 {
            var reference: [String: Any] = [:]
            if let refIndex = args.firstIndex(of: "--reference-attacks"), args.count > refIndex + 1,
               let bytes = try? Data(contentsOf: URL(fileURLWithPath: args[refIndex + 1])),
               let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { reference = object }
            let diagnostic = PlaybackCaptureDiagnostic(output: URL(fileURLWithPath: args[index + 1]),
                referenceAttacks: reference["referenceAttacks"] as? [Double] ?? [],
                alignmentScale: reference["scale"] as? Double ?? 1,
                inferredOffset: reference["inferredOffset"] as? Double ?? 0)
            playbackCaptureDiagnostic = diagnostic
            diagnostic.run()
            return
        }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FretFlow")
        appMenu.addItem(withTitle: "About FretFlow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FretFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        let view = MainView().frame(minWidth: 1180, minHeight: 730)
            .tint(Color(red: 0.43, green: 0.35, blue: 0.88))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FretFlow"
        window.contentMinSize = NSSize(width: 1180, height: 730)
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class PracticeSession: ObservableObject {
    let library = LibraryStore()
    let score = ScoreController()
    let player = YouTubeController()
    let clickTrack = ClickTrackController()
    let recordingSync = RecordingSyncStore(persistenceEnabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
    let autoSync = RecordingAutoSync(persistenceEnabled: !ProcessInfo.processInfo.arguments.contains("--smoke-test"))
    @Published private(set) var syncAdjustment: Double = 0
    @Published private(set) var syncSource: String?
    private var syncKey: String?
    @Published var selectedID = "plini-01" { didSet { autoSync.cancel(); clickTrack.suspend() } }
    @Published var section = "Practice" {
        didSet { if section != "Practice" { autoSync.cancel(); clickTrack.suspend(); player.pause() } }
    }
    @Published var loopA: Double? { didSet { clickTrack.stop() } }
    @Published var loopB: Double? { didSet { clickTrack.stop() } }
    @Published var looping = false { didSet { clickTrack.stop() } }
    @Published var linkError: String?
    @Published var showBook = false
    private var timer: Timer?
    private var started = false
    var selectedSong: LibrarySong? { library.songs.first { $0.id == selectedID } }
    var hasLinkedVideo: Bool { library.videoLinks[selectedID] != nil }
    var isSmokeTest: Bool { ProcessInfo.processInfo.arguments.contains("--smoke-test") }

    func start() {
        guard !started else { return }
        started = true
        score.onSeek = { [weak self] time in
            guard let self, self.hasLinkedVideo else { return }
            self.player.seek(to: time)
        }
        score.onPlay = { [weak self] in self?.player.play() }
        score.onPause = { [weak self] in self?.player.pause() }
        player.onClockReset = { [weak self] in
            self?.clickTrack.stop()
            self?.autoSync.playbackClockDidReset()
        }
        player.onPauseIntent = { [weak self] in
            if self?.autoSync.isAnalyzing == true { self?.autoSync.cancel() }
        }
        autoSync.onAnalysisStarted = { [weak self] in self?.clickTrack.stop() }
        autoSync.onRestart = { [weak self] in
            guard let self, self.section == "Practice", self.hasLinkedVideo else { return }
            self.clearLoop()
            self.player.playFromStart()
        }
        autoSync.onMatch = { [weak self] key, match in
            guard let self, self.syncKey == key else { return }
            self.setSyncAdjustment(match.adjustment, source: "automatic", confidence: match.confidence)
        }
        score.onClicksChanged = { [weak self] in
            guard let self else { return }
            self.clickTrack.setEvents(self.score.clicks)
            self.configureAutoSync()
        }
        score.onLoaded = { [weak self] in
            guard let self else { return }
            self.clickTrack.setEvents(self.score.clicks)
            self.configureAutoSync()
            if self.isSmokeTest {
                if ProcessInfo.processInfo.arguments.contains("--tuner-snapshot") { self.section = "Tuner" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishSmokeTest() }
            }
        }
        if isSmokeTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in self?.finishSmokeTest(timedOut: true) }
        }
        loadSelection()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func loadSelection() {
        guard let song = selectedSong else { return }
        autoSync.configure(identity: nil, referenceAttacks: [], scale: 1, inferredOffset: 0, hasSavedAlignment: false)
        clickTrack.setEvents([])
        player.clear()
        loopA = nil; loopB = nil; looping = false; linkError = nil
        restoreSync(for: song)
        if song.kind == "gp" { score.load(url: library.url(for: song), id: song.id, offsetAdjustment: syncAdjustment) }
        else { score.suspend() }
        if let video = library.videoLinks[song.id], !isSmokeTest { player.cue(videoID: video) }
    }

    func linkVideo(_ text: String) {
        guard let song = selectedSong else { return }
        guard let id = YouTubeController.videoID(from: text) else {
            linkError = "Paste a YouTube video link, such as youtube.com/watch?v=… or youtu.be/…"
            return
        }
        linkError = nil
        let changed = library.videoLinks[song.id] != id
        library.saveVideo(id, for: song)
        if changed {
            autoSync.cancel()
            clearLoop()
            restoreSync(for: song)
            if song.kind == "gp" { score.setAlignmentAdjustment(syncAdjustment) }
        }
        player.cue(videoID: id)
    }

    private func restoreSync(for song: LibrarySong) {
        syncKey = song.kind == "gp" ? library.videoLinks[song.id].flatMap {
            recordingSync.key(songID: song.id, videoID: $0, scoreURL: library.url(for: song))
        } : nil
        let saved = recordingSync.setting(for: syncKey)
        syncAdjustment = saved?.adjustment ?? 0
        syncSource = saved?.source
    }

    private func clearLoop() { looping = false; loopA = nil; loopB = nil }

    private func configureAutoSync() {
        autoSync.configure(identity: syncKey, referenceAttacks: score.referenceAttacks,
                           scale: score.alignmentScale, inferredOffset: score.inferredAlignmentOffset,
                           hasSavedAlignment: syncSource != nil)
    }

    func setSyncAdjustment(_ value: Double, source: String = "manual", confidence: Double? = nil) {
        guard let syncKey, value.isFinite, (-30...120).contains(value), score.isLoaded else { return }
        let rounded = (value * 1_000).rounded() / 1_000
        guard recordingSync.save(adjustment: rounded, source: source, confidence: confidence, for: syncKey) else { return }
        autoSync.cancel()
        syncAdjustment = rounded
        syncSource = source
        clearLoop()
        score.setAlignmentAdjustment(rounded)
    }

    func resetSyncAdjustment() {
        guard let syncKey else { return }
        recordingSync.remove(for: syncKey)
        syncAdjustment = 0
        syncSource = nil
        clearLoop()
        score.setAlignmentAdjustment(0)
    }

    func setLoopForCurrentMeasure() {
        guard let bar = score.measures.last(where: { $0.start <= player.position }), bar.end > bar.start else { return }
        loopA = bar.start; loopB = bar.end; looping = true
        player.seek(to: bar.start)
    }

    func tick() {
        guard section == "Practice", hasLinkedVideo else { clickTrack.suspend(); return }
        let time = player.interpolatedPosition
        if !isSmokeTest {
            autoSync.observe(position: time, rate: player.rate,
                             fresh: player.hasPrecisePlaybackClock, revision: player.clockRevision)
        }
        if looping, player.hasFreshPlaybackClock, let a = loopA, let b = loopB, b > a, time >= b {
            player.seek(to: a)
            clickTrack.stop()
            if selectedSong?.kind == "gp" { score.setClock(position: a, duration: player.duration, isPlaying: false, rate: player.rate) }
        } else {
            // Keep the playhead and click on the same confirmed playback state,
            // including buffering and the gap while a seek is acknowledged.
            let playing = player.hasFreshPlaybackClock
            if selectedSong?.kind == "gp" { score.setClock(position: time, duration: player.duration, isPlaying: playing, rate: player.rate) }
            let validScore = selectedSong?.kind == "gp" && score.isLoaded && score.songID == selectedID && score.error == nil
            clickTrack.update(position: time, isPlaying: validScore && playing && !autoSync.isAnalyzing,
                              rate: player.rate, loopEnd: looping ? loopB : nil,
                              discontinuity: player.clockRevision)
        }
    }

    private func finishSmokeTest(timedOut: Bool = false) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--output"), args.count > index + 1 else { NSApp.terminate(nil); return }
        let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info: [String: Any] = ["loaded": score.isLoaded, "timedOut": timedOut,
            "songs": library.songs.count, "tracks": score.tracks.count, "measures": score.measures.count,
            "title": score.scoreTitle, "error": score.error ?? "", "clickEvents": score.clicks.count,
            "clickTrackError": score.clickTrackError ?? ""]
        try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("smoke.json"))
        if timedOut { NSApp.terminate(nil); return }
        score.webView.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("score.png"))
            }
            if let view = NSApp.mainWindow?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("window.png"))
                }
            }
            NSApp.terminate(nil)
        }
    }
}

struct MainView: View {
    @StateObject private var session = PracticeSession()
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(session: session, library: session.library)
                .frame(width: 230)
            Divider()
            if session.section == "Tuner" {
                TunerView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PracticeView(session: session, score: session.score, player: session.player)
            }
        }
        .onAppear { session.start() }
        .onChange(of: session.selectedID) { _, _ in session.loadSelection() }
        .sheet(isPresented: $session.showBook) {
            VStack(spacing: 0) {
                HStack {
                    Text("Original PDF tab book").font(.headline)
                    Spacer()
                    Button("Open in Preview") { if let url = session.library.bookURL { NSWorkspace.shared.open(url) } }
                    Button("Done") { session.showBook = false }.keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                if let url = session.library.bookURL { PDFReader(url: url) }
            }.frame(width: 940, height: 780)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var session: PracticeSession
    @ObservedObject var library: LibraryStore
    @UIState private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "guitars.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FretFlow").font(.title2.bold())
                    Text("YOUR PRACTICE SPACE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                }
            }.padding(.top, 12)
            ForEach([("Practice", "music.note.list"), ("Tuner", "waveform")], id: \.0) { item in
                Button { session.section = item.0 } label: {
                    Label(item.0, systemImage: item.1).font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(session.section == item.0 ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
            Divider()
            HStack {
                Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                Spacer()
                Text("\(library.songs.count)").foregroundStyle(.tertiary).font(.caption)
                Button { library.importTabs() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add Guitar Pro or PDF tabs")
            }
            TextField("Find a song", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.songs.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { song in
                        Button {
                            session.selectedID = song.id
                            session.section = "Practice"
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: song.kind == "pdf" ? "doc.richtext" : "music.note").frame(width: 14).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(song.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(song.artist).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if library.videoLinks[song.id] != nil { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(session.selectedID == song.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Button { library.importTabs() } label: { Label("Add tabs", systemImage: "plus.circle") }.frame(maxWidth: .infinity)
            if library.bookURL != nil {
                Button { session.showBook = true } label: { Label("Original PDF book", systemImage: "book") }.buttonStyle(.plain).font(.caption)
            }
            Text("Tabs & tuner stay on this Mac.\nYouTube needs an internet connection.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(18).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PracticeView: View {
    @ObservedObject var session: PracticeSession
    @ObservedObject var score: ScoreController
    @ObservedObject var player: YouTubeController
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.selectedSong?.title ?? "Choose a song").font(.system(size: 25, weight: .semibold))
                    Text(session.selectedSong?.artist ?? "").foregroundStyle(.secondary)
                }
                Spacer()
                if session.selectedSong?.kind == "gp" {
                    Text(score.currentMeasure.isEmpty ? "READY TO PRACTICE" : score.currentMeasure)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if session.selectedSong?.kind == "gp" {
                        scoreToolbar
                        Divider()
                        ZStack {
                            ScoreView(controller: score)
                            if !score.isLoaded && score.error == nil { ProgressView(score.status).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                            if let error = score.error {
                                VStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                                    Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                                    Button("Retry score") { if let song = session.selectedSong { score.load(url: session.library.url(for: song), id: song.id) } }
                                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                            }
                        }.background(Color.white)
                        HStack {
                            Text(score.status)
                            Spacer()
                            Text("Click a measure to seek")
                        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
                    } else if let song = session.selectedSong {
                        Text("PDF reference • automatic highlighting requires a Guitar Pro score")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                        PDFReader(url: session.library.url(for: song))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                PlayerPanel(session: session, player: player, score: score).frame(width: 370)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var scoreToolbar: some View {
        HStack(spacing: 12) {
            Picker("Part", selection: $score.selectedTrack) {
                ForEach(score.tracks) { track in Text(track.name).tag(track.index) }
            }.labelsHidden().frame(maxWidth: 220)
                .onChange(of: score.selectedTrack) { _, index in score.selectTrack(index) }
            Spacer(minLength: 6)
            Toggle("Follow", isOn: $score.follow).toggleStyle(.checkbox)
                .onChange(of: score.follow) { _, enabled in score.call("setFollow", arguments: [enabled]) }
            Picker("Zoom", selection: $score.zoom) {
                Text("75%").tag(0.75); Text("90%").tag(0.9); Text("100%").tag(1.0); Text("115%").tag(1.15); Text("130%").tag(1.3)
            }.labelsHidden().frame(width: 85)
                .onChange(of: score.zoom) { _, value in score.call("setZoom", arguments: [value]) }
        }.padding(12)
    }
}

struct PlayerPanel: View {
    @ObservedObject var session: PracticeSession
    @ObservedObject var player: YouTubeController
    @ObservedObject var score: ScoreController
    @UIState private var linkText = ""
    @UIState private var seeking = false
    @UIState private var seekPosition = 0.0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("YouTube", systemImage: "play.rectangle.fill").font(.headline)
                    Spacer()
                    Image(systemName: "link").foregroundStyle(.secondary)
                }
                YouTubeView(controller: player).frame(height: 205).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text("VIDEO FOR THIS SONG").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    TextField("Paste a YouTube link", text: $linkText).textFieldStyle(.roundedBorder).onSubmit { session.linkVideo(linkText) }
                    HStack {
                        Button("Link video") { session.linkVideo(linkText) }.buttonStyle(.borderedProminent)
                        Button("Find on YouTube") {
                            let query = "\(session.selectedSong?.artist ?? "") \(session.selectedSong?.title ?? "") official audio"
                            var parts = URLComponents(string: "https://www.youtube.com/results")!
                            parts.queryItems = [URLQueryItem(name: "search_query", value: query)]
                            if let url = parts.url { NSWorkspace.shared.open(url) }
                        }
                    }.controlSize(.small)
                    if let error = session.linkError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Text(player.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                RecordingSyncProgress(autoSync: session.autoSync)
                if !player.title.isEmpty { Text(player.title).font(.system(size: 12, weight: .medium)).lineLimit(3) }
                Divider()
                playbackControls
                Divider()
                ClickTrackControls(clickTrack: session.clickTrack, score: score, player: player,
                                   isGuitarPro: session.selectedSong?.kind == "gp")
                Divider()
                RecordingSyncControls(session: session, score: score, player: player, autoSync: session.autoSync)
                Divider()
                loopControls
            }.padding(20)
        }
        .onChange(of: session.selectedID) { _, id in
            linkText = session.library.videoLinks[id].map { "https://youtu.be/\($0)" } ?? ""
            seeking = false
            seekPosition = 0
        }
        .onAppear { linkText = session.library.videoLinks[session.selectedID].map { "https://youtu.be/\($0)" } ?? "" }
    }

    private var playbackControls: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { seeking ? seekPosition : min(player.position, max(1, player.duration)) }, set: { seekPosition = $0 }), in: 0...max(1, player.duration)) { editing in
                if editing { seekPosition = player.position }
                seeking = editing
                if !editing { player.seek(to: seekPosition) }
            }.disabled(!player.isReady || !session.hasLinkedVideo)
            HStack {
                Text(formatTime(seeking ? seekPosition : player.position))
                Spacer()
                Text(formatTime(player.duration))
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button { player.seek(to: max(0, player.position - 5)) } label: { Image(systemName: "gobackward.5").font(.title3) }
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 30)
                }.buttonStyle(.borderedProminent)
                Button { player.seek(to: player.position + 5) } label: { Image(systemName: "goforward.5").font(.title3) }
            }.disabled(!player.isReady || !session.hasLinkedVideo)
            HStack {
                Label("Speed", systemImage: "speedometer").font(.caption)
                Spacer()
                Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                    ForEach(player.availableRates.isEmpty ? [1.0] : player.availableRates, id: \.self) { value in
                        Text(String(format: "%g×", value)).tag(value)
                    }
                }.labelsHidden().frame(width: 95).disabled(!player.isReady)
            }
        }
    }

    private var loopControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Practice loop", systemImage: "repeat").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Loop", isOn: $session.looping).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(session.loopA == nil || session.loopB == nil || (session.loopB ?? 0) <= (session.loopA ?? 0))
            }
            HStack {
                Button("A  \(session.loopA.map(formatTime) ?? "Set start")") {
                    session.loopA = player.position
                    if let b = session.loopB, b <= player.position { session.loopB = nil; session.looping = false }
                }
                Button("B  \(session.loopB.map(formatTime) ?? "Set end")") {
                    if player.position > (session.loopA ?? 0) {
                        if session.loopA == nil { session.loopA = 0 }
                        session.loopB = player.position
                        session.looping = true
                    }
                }
            }.controlSize(.small).disabled(!player.isReady || !session.hasLinkedVideo)
            HStack {
                Button("Loop this measure") { session.setLoopForCurrentMeasure() }
                    .disabled(score.measures.isEmpty || !player.isReady || session.selectedSong?.kind != "gp")
                Spacer()
                Button("Clear") { session.loopA = nil; session.loopB = nil; session.looping = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.caption)
            Text("Set A and B around any section. Loops may briefly buffer at the restart.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
